#if os(macOS)
import AppKit
import ErsatzCore
import Foundation

extension LibraryModel {
    func adjustThumbnail(by delta: Double) {
        thumbnailSide = min(512, max(48, thumbnailSide + delta))
        persistChrome()
    }

    func prepareBuddhistFix() {
        filter = .buddhistDates
        Task {
            await reloadItems()
            if !items.isEmpty {
                showBuddhistConfirm = true
            } else {
                present(message: "No Buddhist-era dates were corrected in the catalog.")
            }
        }
    }

    func writeCorrectedDates() async {
        let targets = items.filter(\.dateCorrected)
        guard !targets.isEmpty else { return }
        let drafts = targets.map { item in
            CheckpointFileDraft(
                path: item.path,
                kind: .metadata,
                originalMetadata: item.dateTaken.map { "dateTaken=\(EXIFDateParser.format($0))" }
            )
        }
        guard let checkpoint = try? await database?.createCheckpoint(action: "fix-buddhist-era-dates", note: "Metadata only", files: drafts) else {
            present(message: "Couldn't create a checkpoint.")
            return
        }
        for item in targets {
            guard let date = item.dateTaken else { continue }
            let old = EXIFDateParser.format(date)
            let result = MetadataWriter.writeDate(url: URL(fileURLWithPath: item.path), date: date)
            let entry = ActivityEntry(
                id: 0,
                createdAt: Date(),
                action: "fix-buddhist-era-dates",
                path: item.path,
                oldValue: old,
                newValue: result.written,
                checkpointID: checkpoint.id,
                success: result.success,
                restorable: true
            )
            if let stored = try? await database?.appendActivity(entry) {
                try? ActivityLog.shared?.append(stored)
            }
        }
        await reloadItems()
    }

    func trashDuplicates() async {
        let targets = trashCandidates
        trashCandidates = []
        guard !targets.isEmpty else { return }
        let drafts = targets.map { CheckpointFileDraft(path: $0.path, kind: .deletion) }
        guard let checkpoint = try? await database?.createCheckpoint(action: "trash-duplicates", note: nil, files: drafts) else {
            present(message: "Couldn't create a checkpoint.")
            return
        }
        let urls = targets.map { URL(fileURLWithPath: $0.path) }
        let trashed: [URL: URL] = await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { mapping, _ in
                continuation.resume(returning: mapping)
            }
        }
        for item in targets {
            let source = URL(fileURLWithPath: item.path)
            let trash = trashed[source]
            let entry = ActivityEntry(
                id: 0,
                createdAt: Date(),
                action: "trash-duplicates",
                path: item.path,
                oldValue: item.path,
                newValue: trash?.path,
                checkpointID: checkpoint.id,
                success: trash != nil,
                restorable: trash != nil
            )
            if let stored = try? await database?.appendActivity(entry) {
                try? ActivityLog.shared?.append(stored)
            }
        }
        await reloadItems()
    }

    func restore(checkpoint: Checkpoint) async {
        guard let files = try? await database?.checkpointFiles(checkpointID: checkpoint.id) else { return }
        for file in files {
            await restore(file: file, checkpoint: checkpoint)
        }
    }

    func restore(file: CheckpointFile, checkpoint: Checkpoint) async {
        var success = false
        var newValue = ""
        switch file.kind {
        case .metadata:
            if let original = file.originalMetadata, let date = date(fromCheckpoint: original) {
                let result = MetadataWriter.writeDate(url: URL(fileURLWithPath: file.path), date: date)
                success = result.success
                newValue = result.written
            }
        case .content:
            if let backup = file.backupPath {
                let source = URL(fileURLWithPath: backup)
                let destination = URL(fileURLWithPath: file.path)
                do {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.copyItem(at: source, to: destination)
                    success = true
                    newValue = destination.path
                } catch {
                    success = false
                    newValue = error.localizedDescription
                }
            }
        case .deletion:
            if let trash = file.trashURL {
                let source = URL(fileURLWithPath: trash)
                let destination = URL(fileURLWithPath: file.path)
                do {
                    try FileManager.default.moveItem(at: source, to: destination)
                    success = true
                    newValue = destination.path
                } catch {
                    success = false
                    newValue = error.localizedDescription
                }
            }
        }
        let entry = ActivityEntry(
            id: 0,
            createdAt: Date(),
            action: "restore",
            path: file.path,
            oldValue: file.originalMetadata ?? file.trashURL ?? file.backupPath,
            newValue: newValue,
            checkpointID: checkpoint.id,
            success: success,
            restorable: false
        )
        if let stored = try? await database?.appendActivity(entry) {
            try? ActivityLog.shared?.append(stored)
        }
    }

    func pruneCheckpoints() async {
        let days = max(1, checkpointDays)
        let maxBytes = Int64(checkpointMaxGigabytes * 1_073_741_824)
        let cutoff = Date().addingTimeInterval(-days * 24 * 60 * 60)
        _ = try? await database?.pruneCheckpoints(olderThan: cutoff, maxBytes: maxBytes)
        UserDefaults.standard.set(checkpointDays, forKey: "checkpointDays")
        UserDefaults.standard.set(checkpointMaxGigabytes, forKey: "checkpointMaxGigabytes")
    }

    func runAnalysis() async {
        guard let database else { return }
        let analyzer = LibraryAnalyzer()
        try? await analyzer.analyze(database: database, scoring: MacImageScoring()) { done, total in
            Task { @MainActor in
                self.progress = IndexProgress(phase: .analyzing, filesSeen: total, filesParsed: done)
            }
        }
        if let records = try? await database.hashRecords() {
            duplicateCount = DuplicateFinder.exactGroups(records).reduce(0) { $0 + $1.count }
                + DuplicateFinder.nearGroups(records, threshold: 8).reduce(0) { $0 + $1.count }
        }
    }

    private func date(fromCheckpoint metadata: String) -> Date? {
        guard let range = metadata.range(of: "dateTaken=") else { return nil }
        return EXIFDateParser.parse(String(metadata[range.upperBound...]))
    }
}

enum ActivityLog {
    static let shared: ActivityLogFile? = {
        let directory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Logs/Ersatz", isDirectory: true)
        return try? ActivityLogFile(directory: directory)
    }()
}
#endif
