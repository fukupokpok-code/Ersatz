import XCTest
@testable import ErsatzCore

/// Removing folders without FOREIGN KEY errors, schema v3, and lazy per-part analysis.
final class FolderRemovalTests: XCTestCase {
    func testRemovingARootWithAnalysisKeepsOtherFoldersAndHistory() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let database = try MediaDatabase(path: scratch.databasePath)
        let trip = try await database.addFolder(path: "/trip", bookmark: nil, displayName: "Trip")
        let home = try await database.addFolder(path: "/home", bookmark: nil, displayName: "Home")
        try await database.upsert([
            media(trip.id, "/trip/a.jpg"), media(trip.id, "/trip/day/b.jpg"), media(home.id, "/home/c.jpg")
        ])
        let all = try await database.media(matching: MediaQuery())
        try await database.saveAnalysis(all.map { analysis($0.id, hash: "same") })
        let checkpoint = try await database.createCheckpoint(
            action: "trash-duplicates", note: nil,
            files: [CheckpointFileDraft(path: "/trip/a.jpg", kind: .deletion, trashURL: "/Users/x/.Trash/a.jpg")]
        )
        _ = try await database.appendActivity(ActivityEntry(
            id: 0, createdAt: Date(), action: "trash-duplicates", path: "/trip/a.jpg",
            oldValue: "/trip/a.jpg", newValue: "/Users/x/.Trash/a.jpg",
            checkpointID: checkpoint.id, success: true, restorable: true
        ))

        try await database.removeFolder(id: trip.id)

        let left = try await database.media(matching: MediaQuery())
        XCTAssertEqual(left.map(\.path), ["/home/c.jpg"])
        let folders = try await database.folders()
        XCTAssertEqual(folders.map(\.id), [home.id])
        let hashes = try await database.hashRecords()
        XCTAssertEqual(hashes.map(\.id), [left[0].id])
        // History is keyed by path, so the checkpoint and its activity survive and can restore.
        let checkpoints = try await database.checkpoints()
        XCTAssertEqual(checkpoints.map(\.id), [checkpoint.id])
        let files = try await database.checkpointFiles(checkpointID: checkpoint.id)
        XCTAssertEqual(files.first?.trashURL, "/Users/x/.Trash/a.jpg")
        let activity = try await database.activity()
        XCTAssertEqual(activity.count, 1)
        let violations = try await database.foreignKeyViolationCount()
        XCTAssertEqual(violations, 0)
    }

    func testIndexBatchAfterRemovalReportsFolderRemovedNotForeignKey() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let database = try MediaDatabase(path: scratch.databasePath)
        let folder = try await database.addFolder(path: "/trip", bookmark: nil, displayName: "Trip")
        try await database.upsert([media(folder.id, "/trip/a.jpg")])
        try await database.removeFolder(id: folder.id)
        do {
            try await database.upsert([media(folder.id, "/trip/b.jpg")])
            XCTFail("expected folderRemoved")
        } catch let error as DatabaseError {
            XCTAssertEqual(error, .folderRemoved(folder.id))
        }
        let left = try await database.media(matching: MediaQuery())
        XCTAssertTrue(left.isEmpty)
    }

    func testAnalysisForRemovedMediaIsSkipped() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let database = try MediaDatabase(path: scratch.databasePath)
        let folder = try await database.addFolder(path: "/trip", bookmark: nil, displayName: "Trip")
        try await database.upsert([media(folder.id, "/trip/a.jpg")])
        let id = try await database.media(matching: MediaQuery())[0].id
        try await database.removeFolder(id: folder.id)
        try await database.saveAnalysis([analysis(id, hash: "x")])
        let hashes = try await database.hashRecords()
        XCTAssertTrue(hashes.isEmpty)
        let violations = try await database.foreignKeyViolationCount()
        XCTAssertEqual(violations, 0)
    }

    func testDeletedSubfolderIsDroppedOnReindexWithItsAnalysis() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let library = scratch.root.appendingPathComponent("Library", isDirectory: true)
        let sub = library.appendingPathComponent("Old", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: library.appendingPathComponent("keep.jpg"))
        try Data("gone".utf8).write(to: sub.appendingPathComponent("gone.jpg"))
        let database = try MediaDatabase(path: scratch.databasePath)
        let folder = try await database.addFolder(path: library.path, bookmark: nil, displayName: "Library")
        _ = try await LibraryIndexer().index(root: library, folderID: folder.id, database: database)
        try await LibraryAnalyzer(workerCount: 2).analyze(database: database, parts: .all)
        let before = try await database.hashRecords()
        XCTAssertEqual(before.count, 2)

        try FileManager.default.removeItem(at: sub)   // the subfolder went to the Trash
        _ = try await LibraryIndexer().index(root: library, folderID: folder.id, database: database)

        let items = try await database.media(matching: MediaQuery())
        XCTAssertEqual(items.map(\.filename), ["keep.jpg"])
        let after = try await database.hashRecords()
        XCTAssertEqual(after.map(\.id), items.map(\.id))
        let violations = try await database.foreignKeyViolationCount()
        XCTAssertEqual(violations, 0)
    }

    func testVersion2LibraryMigratesKeepingCachedAnalysis() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        do {
            let database = try MediaDatabase(path: scratch.databasePath)
            let folder = try await database.addFolder(path: "/trip", bookmark: nil, displayName: "Trip")
            try await database.upsert([media(folder.id, "/trip/a.jpg"), media(folder.id, "/trip/b.jpg")])
            let first = try await database.media(matching: MediaQuery()).first { $0.filename == "a.jpg" }!
            try await database.saveAnalysis([analysis(first.id, hash: "cached")])
        }
        do {
            // Turn it back into a v2 library, as written by round 6 and earlier.
            let raw = try SQLiteConnection(path: scratch.databasePath)
            try raw.execute("ALTER TABLE analysis DROP COLUMN analyzed_parts")
            try raw.execute("PRAGMA user_version = 2")
        }
        let database = try MediaDatabase(path: scratch.databasePath)
        let folders = try await database.folders()
        XCTAssertEqual(folders.count, 1)
        let items = try await database.media(matching: MediaQuery())
        XCTAssertEqual(items.count, 2)
        let a = items.first { $0.filename == "a.jpg" }!
        // v3 marked every part done; v4 (round 8) then marks blur, QR and slips stale.
        let parts = try await database.analyzedParts(mediaID: a.id)
        XCTAssertEqual(parts, [.screenshot, .hashes, .perceptual])
        let hashes = try await database.hashRecords()
        XCTAssertEqual(hashes.first?.contentHash, "cached")
        // For duplicates only b.jpg, never analyzed, is still pending.
        let pending = try await database.pendingAnalysis(parts: .duplicates)
        XCTAssertEqual(pending.map(\.filename), ["b.jpg"])
    }

    private func media(_ folder: Int64, _ path: String) -> NewMedia {
        let name = (path as NSString).lastPathComponent
        let relative = path.split(separator: "/").dropFirst().joined(separator: "/")
        let parent = (relative as NSString).deletingLastPathComponent
        return NewMedia(
            folderID: folder, path: path, relativePath: relative, filename: name,
            parentRelative: parent, kind: .photo, fileSize: 100, createdAt: nil,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), dateTaken: nil,
            pixelWidth: nil, pixelHeight: nil, videoCodec: nil
        )
    }

    private func analysis(_ id: Int64, hash: String) -> AnalysisUpdate {
        AnalysisUpdate(
            mediaID: id, partialHash: hash, contentHash: hash, perceptualHash: 1, sharpness: 10,
            isScreenshot: false, hasQR: false, isBankSlip: false,
            analyzedMTime: 1_700_000_000_000
        )
    }
}

final class LazyAnalysisTests: XCTestCase {
    func testEachFilterAnalyzesOnlyItsPartsAndCachesThem() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let library = scratch.root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: library.appendingPathComponent("one.jpg"))
        try Data("two".utf8).write(to: library.appendingPathComponent("Screenshot 2026-10-30 at 12.00.00.png"))
        let database = try MediaDatabase(path: scratch.databasePath)
        let folder = try await database.addFolder(path: library.path, bookmark: nil, displayName: "Library")
        _ = try await LibraryIndexer().index(root: library, folderID: folder.id, database: database)

        // Indexing alone analyzes nothing.
        let untouched = try await database.pendingAnalysis(parts: .all)
        XCTAssertEqual(untouched.count, 2)

        let scoring = RecordingScoring()
        let analyzer = LibraryAnalyzer(workerCount: 2)
        try await analyzer.analyze(database: database, parts: .screenshot, scoring: scoring)
        var calls = await scoring.calls
        XCTAssertTrue(calls.isEmpty, "screenshots never decode pixels")
        let screenshotsLeft = try await database.pendingAnalysis(parts: .screenshot)
        XCTAssertTrue(screenshotsLeft.isEmpty)
        let summary = try await database.summary()
        XCTAssertEqual(summary.screenshotCount, 1)

        try await analyzer.analyze(database: database, parts: .sharpness, scoring: scoring)
        calls = await scoring.calls
        XCTAssertEqual(calls, [.sharpness, .sharpness], "blur asks for sharpness only, no OCR or QR")

        // Asking again does nothing: results are cached per part.
        try await analyzer.analyze(database: database, parts: [.screenshot, .sharpness], scoring: scoring)
        calls = await scoring.calls
        XCTAssertEqual(calls.count, 2)
        // The screenshot result survived the later blur pass.
        let stillOne = try await database.summary()
        XCTAssertEqual(stillOne.screenshotCount, 1)

        let photo = try await database.media(matching: MediaQuery()).first { $0.filename == "one.jpg" }!
        let parts = try await database.analyzedParts(mediaID: photo.id)
        XCTAssertEqual(parts, [.screenshot, .sharpness])
        let duplicatesLeft = try await database.pendingAnalysis(parts: .duplicates)
        XCTAssertEqual(duplicatesLeft.count, 2)
    }

    func testBankSlipsAlsoComputeQR() {
        XCTAssertEqual(AnalysisParts.bankSlip.closed, [.bankSlip, .qr])
        XCTAssertEqual(AnalysisParts.sharpness.closed, .sharpness)
        XCTAssertTrue(AnalysisParts.all.isSuperset(of: AnalysisParts.duplicates))
    }

    func testCancelledAnalysisKeepsFinishedWorkAndStops() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let database = try MediaDatabase(path: scratch.databasePath)
        let folder = try await database.addFolder(path: "/x", bookmark: nil, displayName: "X")
        try await database.upsert((0..<40).map { index in
            NewMedia(
                folderID: folder.id, path: "/x/\(index).jpg", relativePath: "\(index).jpg", filename: "\(index).jpg",
                parentRelative: "", kind: .photo, fileSize: 100, createdAt: nil,
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), dateTaken: nil,
                pixelWidth: nil, pixelHeight: nil, videoCodec: nil
            )
        })
        let scoring = RecordingScoring(delay: .milliseconds(20))
        let task = Task {
            try await LibraryAnalyzer(workerCount: 2).analyze(database: database, parts: .sharpness, scoring: scoring)
        }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        let left = try await database.pendingAnalysis(parts: .sharpness)
        XCTAssertGreaterThan(left.count, 0)
        XCTAssertLessThan(left.count, 40)
    }
}

final class WorkGateTests: XCTestCase {
    func testBackgroundWaitsWhileForegroundRuns() async {
        // Round 8: background may share the machine with running thumbnails, but never
        // starts while a thumbnail is waiting for a slot.
        let gate = WorkGate(foregroundLimit: 1, backgroundLimit: 2)
        await gate.enter(.foreground)
        let waiting = Task {
            await gate.enter(.foreground)
            await gate.leave(.foreground)
        }
        try? await Task.sleep(for: .milliseconds(30))
        let started = Flag()
        let background = Task {
            await gate.enter(.background)
            await started.set()
            await gate.leave(.background)
        }
        try? await Task.sleep(for: .milliseconds(50))
        let early = await started.value
        XCTAssertFalse(early, "analysis must not start while a thumbnail renders")
        let state = await gate.snapshot
        XCTAssertEqual(state.waitingBackground, 1)
        await gate.leave(.foreground)
        await waiting.value
        await background.value
        let late = await started.value
        XCTAssertTrue(late)
    }

    func testForegroundIsNeverBlockedByBackground() async {
        let gate = WorkGate(foregroundLimit: 1, backgroundLimit: 1)
        await gate.enter(.background)
        // A thumbnail still gets its own slot while analysis is mid-item.
        await gate.enter(.foreground)
        let state = await gate.snapshot
        XCTAssertEqual(state.foreground, 1)
        XCTAssertEqual(state.background, 1)
        await gate.leave(.foreground)
        await gate.leave(.background)
    }

    func testWaitingForegroundStartsNewestFirst() async {
        let gate = WorkGate(foregroundLimit: 1, backgroundLimit: 1)
        await gate.enter(.foreground)
        let order = Order()
        let old = Task { await gate.enter(.foreground); await order.append("old"); await gate.leave(.foreground) }
        try? await Task.sleep(for: .milliseconds(30))
        let new = Task { await gate.enter(.foreground); await order.append("new"); await gate.leave(.foreground) }
        try? await Task.sleep(for: .milliseconds(30))
        await gate.leave(.foreground)
        await old.value
        await new.value
        let result = await order.items
        XCTAssertEqual(result, ["new", "old"])
    }
}

private actor RecordingScoring: ImageScoring {
    private(set) var calls: [AnalysisParts] = []
    private let delay: Duration?

    init(delay: Duration? = nil) {
        self.delay = delay
    }

    func signals(for url: URL, kind: MediaType, parts: AnalysisParts) async -> ImageSignals {
        calls.append(parts)
        if let delay { try? await Task.sleep(for: delay) }
        return ImageSignals(perceptualHash: 7, sharpness: 12)
    }
}

private actor Flag {
    private(set) var value = false
    func set() { value = true }
}

private actor Order {
    private(set) var items: [String] = []
    func append(_ item: String) { items.append(item) }
}
