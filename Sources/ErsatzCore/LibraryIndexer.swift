import Foundation

public struct LibraryIndexer: Sendable {
    public var workerCount: Int

    public init(workerCount: Int? = nil) {
        let processors = ProcessInfo.processInfo.activeProcessorCount
        self.workerCount = max(2, workerCount ?? processors)
    }

    public func index(
        root: URL,
        folderID: Int64,
        database: MediaDatabase,
        extractor: any MetadataExtracting = PortableMetadataExtractor(),
        force: Bool = false,
        progress: @escaping @Sendable (IndexProgress) -> Void = { _ in }
    ) async throws -> IndexResult {
        let scanner = FileScanner()
        progress(IndexProgress(phase: .scanning))
        let files = try scanner.enumerate(root: root)
        let snapshots = try await database.snapshots(folderID: folderID)
        var state = IndexProgress(phase: .scanning, filesSeen: files.count)
        progress(state)

        var basics: [NewMedia] = []
        var pending: [ScannedFile] = []
        var seen = Set<String>()
        seen.reserveCapacity(files.count)

        for file in files {
            if Task.isCancelled { throw CancellationError() }
            let path = file.url.path
            seen.insert(path)
            let modifiedMS = Timestamp.milliseconds(file.modifiedAt)
            if !force,
               let snapshot = snapshots[path],
               snapshot.fileSize == file.fileSize,
               snapshot.modifiedAtMS == modifiedMS,
               snapshot.metadataReady {
                state.filesSkipped += 1
                continue
            }
            let changed = snapshots[path] == nil
                || snapshots[path]?.fileSize != file.fileSize
                || snapshots[path]?.modifiedAtMS != modifiedMS
                || force
            if changed {
                basics.append(basicRecord(file, folderID: folderID))
            }
            pending.append(file)
        }

        for chunk in basics.chunked(into: 400) {
            try await database.upsert(chunk)
        }
        state.phase = .cataloging
        progress(state)

        state.phase = .reading
        progress(state)
        try await extractMetadata(
            pending: pending,
            folderID: folderID,
            database: database,
            extractor: extractor,
            state: &state,
            progress: progress
        )

        if Task.isCancelled { throw CancellationError() }
        let removed = try await database.deleteUnseen(folderID: folderID, seen: seen)
        state.filesRemoved = removed
        state.phase = .finished
        state.currentPath = nil
        progress(state)
        return IndexResult(
            filesSeen: state.filesSeen,
            filesParsed: state.filesParsed,
            filesSkipped: state.filesSkipped,
            filesRemoved: removed
        )
    }

    private func extractMetadata(
        pending: [ScannedFile],
        folderID: Int64,
        database: MediaDatabase,
        extractor: any MetadataExtracting,
        state: inout IndexProgress,
        progress: @escaping @Sendable (IndexProgress) -> Void
    ) async throws {
        var iterator = pending.makeIterator()
        let limit = min(workerCount, max(pending.count, 1))
        var batch: [MetadataUpdate] = []
        let clock = ContinuousClock()
        var lastReport = clock.now

        try await withThrowingTaskGroup(of: MetadataUpdate.self) { group in
            func enqueue() {
                guard let file = iterator.next() else { return }
                group.addTask {
                    var metadata = await extractor.extract(from: file.url, kind: file.kind)
                    if file.kind == .raw {
                        metadata.formatName = FormatNames.preferred(forExtension: file.url.pathExtension)
                    } else if metadata.formatName == nil {
                        metadata.formatName = FormatNames.preferred(forExtension: file.url.pathExtension)
                    }
                    return MetadataUpdate(
                        path: file.url.path,
                        metadata: metadata,
                        dateCorrected: metadata.dateCorrectedFromBuddhistEra
                    )
                }
            }
            for _ in 0..<limit { enqueue() }
            for try await update in group {
                if Task.isCancelled { throw CancellationError() }
                batch.append(update)
                state.filesParsed += 1
                state.currentPath = update.path
                if batch.count >= 80 {
                    try await database.updateMetadata(batch)
                    batch.removeAll(keepingCapacity: true)
                }
                let now = clock.now
                if now - lastReport > .milliseconds(200) {
                    progress(state)
                    lastReport = now
                }
                enqueue()
            }
        }
        if !batch.isEmpty {
            try await database.updateMetadata(batch)
        }
        progress(state)
        _ = folderID
    }

    private func basicRecord(_ file: ScannedFile, folderID: Int64) -> NewMedia {
        NewMedia(
            folderID: folderID,
            path: file.url.path,
            relativePath: file.relativePath,
            filename: file.filename,
            parentRelative: file.parentRelative,
            kind: file.kind,
            fileSize: file.fileSize,
            createdAt: file.createdAt,
            modifiedAt: file.modifiedAt,
            formatName: FormatNames.preferred(forExtension: file.url.pathExtension),
            metadataReady: false
        )
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        var result: [[Element]] = []
        var index = 0
        while index < count {
            let end = Swift.min(index + size, count)
            result.append(Array(self[index..<end]))
            index = end
        }
        return result
    }
}
