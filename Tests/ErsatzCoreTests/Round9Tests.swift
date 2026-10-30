import XCTest
@testable import ErsatzCore

/// Round 9: Date Taken, Type and Smart show only the picked library.
final class Round9ScopeTests: XCTestCase {
    func testScopedQueriesShowOnlyThatLibrary() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let database = try MediaDatabase(path: scratch.databasePath)
        let clips = try await database.addFolder(path: "/clips", bookmark: nil, displayName: "clips")
        let photos = try await database.addFolder(path: "/photos", bookmark: nil, displayName: "photos")
        try await database.upsert([
            item(clips.id, "/clips/a.jpg", year: 2024),
            item(clips.id, "/clips/trip/b.mov", kind: .video, year: 2023),
            item(photos.id, "/photos/c.jpg", year: 2024),
            item(photos.id, "/photos/d.jpg", year: nil)
        ])
        let scope = LibraryScope(folderID: clips.id)
        let photosOnly = try await database.media(matching: MediaQuery(kind: .photo).scoped(to: scope))
        XCTAssertEqual(photosOnly.map(\.filename), ["a.jpg"])
        let year = try await database.media(matching: MediaQuery(year: 2024).scoped(to: scope))
        XCTAssertEqual(year.map(\.filename), ["a.jpg"])
        let everything = try await database.media(matching: MediaQuery(year: 2024).scoped(to: nil))
        XCTAssertEqual(Set(everything.map(\.filename)), ["a.jpg", "c.jpg"])
        let trip = try await database.media(matching: MediaQuery().scoped(to: LibraryScope(folderID: clips.id, directory: "trip")))
        XCTAssertEqual(trip.map(\.filename), ["b.mov"])
        // A query that already names a folder keeps it.
        let named = try await database.media(matching: MediaQuery(folderID: photos.id).scoped(to: scope))
        XCTAssertEqual(named.count, 2)
    }

    func testScopedSummaryCountsOnlyThatLibrary() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let database = try MediaDatabase(path: scratch.databasePath)
        let clips = try await database.addFolder(path: "/clips", bookmark: nil, displayName: "clips")
        let photos = try await database.addFolder(path: "/photos", bookmark: nil, displayName: "photos")
        try await database.upsert([
            item(clips.id, "/clips/a.jpg", year: 2024),
            item(clips.id, "/clips/b.mov", kind: .video, year: nil),
            item(photos.id, "/photos/c.jpg", year: 2024),
            item(photos.id, "/photos/d.jpg", year: 2022),
            item(photos.id, "/photos/e.jpg", year: nil)
        ])
        let all = try await database.media(matching: MediaQuery())
        let qrIDs = all.filter { ["a.jpg", "c.jpg", "d.jpg"].contains($0.filename) }.map(\.id)
        try await database.saveAnalysis(qrIDs.map { qrUpdate($0) })

        let scoped = try await database.summary(scope: LibraryScope(folderID: clips.id))
        XCTAssertEqual(scoped.kindCounts[.photo], 1)
        XCTAssertEqual(scoped.kindCounts[.video], 1)
        XCTAssertEqual(scoped.unknownDateCount, 1)
        XCTAssertEqual(scoped.dateBuckets.map(\.year), [2024])
        XCTAssertEqual(scoped.qrCount, 1)
        // The Library section still lists every library.
        XCTAssertEqual(scoped.totalCount, 5)
        XCTAssertEqual(scoped.folders.count, 2)

        let global = try await database.summary()
        XCTAssertEqual(global.kindCounts[.photo], 4)
        XCTAssertEqual(global.qrCount, 3)
        XCTAssertEqual(global.unknownDateCount, 2)

        let hashes = try await database.hashRecords(scope: LibraryScope(folderID: photos.id))
        XCTAssertEqual(hashes.count, 2)
    }

    func testAnalysisOfOneLibraryLeavesTheOthersAlone() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let database = try MediaDatabase(path: scratch.databasePath)
        let clips = try await database.addFolder(path: "/clips", bookmark: nil, displayName: "clips")
        let photos = try await database.addFolder(path: "/photos", bookmark: nil, displayName: "photos")
        try await database.upsert(
            (0..<6).map { item(clips.id, "/clips/\($0).png", year: nil) }
                + (0..<30).map { item(photos.id, "/photos/\($0).jpg", year: nil) }
        )
        let scope = LibraryScope(folderID: clips.id)
        let pending = try await database.pendingAnalysis(parts: .qr, scope: scope)
        XCTAssertEqual(pending.count, 6)
        try await LibraryAnalyzer(workerCount: 2).analyze(
            database: database, parts: .qr, scoring: EmptyImageScoring(), scope: scope
        )
        let clipsLeft = try await database.pendingAnalysis(parts: .qr, scope: scope)
        XCTAssertTrue(clipsLeft.isEmpty)
        let photosLeft = try await database.pendingAnalysis(parts: .qr, scope: LibraryScope(folderID: photos.id))
        XCTAssertEqual(photosLeft.count, 30)
    }

    private func item(_ folder: Int64, _ path: String, kind: MediaType = .photo, year: Int?) -> NewMedia {
        let name = (path as NSString).lastPathComponent
        let root = "/" + (path.split(separator: "/").first.map(String.init) ?? "")
        let relative = String(path.dropFirst(root.count + 1))
        var date: Date?
        if let year {
            date = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"), year: year, month: 6, day: 15, hour: 12))
        }
        return NewMedia(
            folderID: folder, path: path, relativePath: relative, filename: name,
            parentRelative: (relative as NSString).deletingLastPathComponent, kind: kind, fileSize: 100,
            createdAt: nil, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), dateTaken: date,
            pixelWidth: nil, pixelHeight: nil, videoCodec: nil, cameraModel: nil
        )
    }

    private func qrUpdate(_ id: Int64) -> AnalysisUpdate {
        AnalysisUpdate(
            mediaID: id, partialHash: "h\(id)", contentHash: "h\(id)", perceptualHash: 1, sharpness: 80,
            isScreenshot: false, hasQR: true, isBankSlip: false,
            analyzedMTime: 1_700_000_000_000
        )
    }
}

/// Round 9: Stop really stops, and nothing restarts analysis behind the user's back.
final class Round9CancelTests: XCTestCase {
    func testCancelledGateWaiterThrowsAndHoldsNoSlot() async throws {
        let gate = WorkGate(foregroundLimit: 1, backgroundLimit: 1)
        await gate.enter(.background)
        let waiter = Task { try await gate.enterCancellable(.background) }
        try await Task.sleep(for: .milliseconds(40))
        var state = await gate.snapshot
        XCTAssertEqual(state.waitingBackground, 1)
        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("a cancelled waiter must not get a slot")
        } catch is CancellationError {}
        state = await gate.snapshot
        XCTAssertEqual(state.waitingBackground, 0)
        XCTAssertEqual(state.background, 1)
        await gate.leave(.background)
        state = await gate.snapshot
        XCTAssertEqual(state.background, 0, "the slot was not handed to the cancelled waiter")
        // An already cancelled task never takes a slot.
        let late = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await gate.enterCancellable(.background)
        }
        do {
            try await late.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {}
        state = await gate.snapshot
        XCTAssertEqual(state.background, 0)
    }

    func testCancellingAnalysisStopsFastAndSavesNothingHalfDone() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let database = try MediaDatabase(path: scratch.databasePath)
        let folder = try await database.addFolder(path: "/x", bookmark: nil, displayName: "X")
        try await database.upsert((0..<20).map { slowItem(folder.id, "/x/\($0).png") })
        let scoring = SlowScoring()
        let gate = WorkGate(foregroundLimit: 2, backgroundLimit: 2)
        let work = Task {
            try await LibraryAnalyzer(workerCount: 2, batchSize: 50).analyze(
                database: database, parts: .qr, scoring: scoring, gate: gate
            )
        }
        for _ in 0..<200 where scoring.started.values.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(scoring.started.values.isEmpty)
        let clock = ContinuousClock()
        let began = clock.now
        work.cancel()
        _ = try? await work.value
        XCTAssertLessThan(clock.now - began, .seconds(2), "Stop must not wait for in-flight work")
        let left = try await database.pendingAnalysis(parts: .qr)
        XCTAssertEqual(left.count, 20, "cancelled items are not saved with missing results")
        XCTAssertLessThanOrEqual(scoring.started.values.count, 2, "queued items never start")
        let state = await gate.snapshot
        XCTAssertEqual(state.background, 0)
    }

    private func slowItem(_ folder: Int64, _ path: String) -> NewMedia {
        let name = (path as NSString).lastPathComponent
        let relative = String(path.dropFirst(3))
        return NewMedia(
            folderID: folder, path: path, relativePath: relative, filename: name,
            parentRelative: "", kind: .photo, fileSize: 100,
            createdAt: nil, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), dateTaken: nil,
            pixelWidth: nil, pixelHeight: nil, videoCodec: nil, cameraModel: nil
        )
    }
}

final class Round9PlannerTests: XCTestCase {
    private let clips = LibraryScope(folderID: 1)
    private let photos = LibraryScope(folderID: 2)

    func testBrowsingALibraryNeverStartsAnalysis() {
        var planner = AnalysisPlanner()
        XCTAssertEqual(planner.select(parts: [], scope: clips), .none)
        XCTAssertEqual(planner.select(parts: [], scope: nil), .none)
        XCTAssertNil(planner.running)
    }

    func testLaunchWithAPlainFilterDoesNotResumeAnalysis() {
        var planner = AnalysisPlanner()
        XCTAssertEqual(planner.indexing(true), .none)
        XCTAssertEqual(planner.indexing(false, filterParts: [], scope: nil), .none)
        XCTAssertNil(planner.running)
    }

    func testSmartFilterStartsScopedAndLeavingCancels() {
        var planner = AnalysisPlanner()
        let qr = AnalysisDemand.filter(.qr, scope: clips)
        XCTAssertEqual(planner.select(parts: .qr, scope: clips), .start(qr))
        XCTAssertEqual(planner.running?.scope, clips)
        XCTAssertEqual(planner.select(parts: .qr, scope: clips), .none, "same filter does not restart")
        XCTAssertEqual(planner.select(parts: [], scope: clips), .cancel)
        XCTAssertNil(planner.running)
        XCTAssertNil(planner.wanted, "nothing is queued to resume later")
    }

    func testSwitchingFilterReplacesThePassWithoutQueueingTheOld() {
        var planner = AnalysisPlanner()
        _ = planner.select(parts: .qr, scope: clips)
        let blur = AnalysisDemand.filter(.sharpness, scope: clips)
        XCTAssertEqual(planner.select(parts: .sharpness, scope: clips), .cancelAndStart(blur))
        XCTAssertEqual(planner.finished(blur), .none)
        XCTAssertNil(planner.running)
    }

    func testStopIsNotUndoneByIndexing() {
        var planner = AnalysisPlanner()
        _ = planner.select(parts: .qr, scope: clips)
        XCTAssertEqual(planner.stop(), .cancel)
        XCTAssertEqual(planner.stop(), .none)
        XCTAssertEqual(planner.indexing(true), .none)
        XCTAssertEqual(planner.indexing(false, filterParts: .qr, scope: clips), .none, "the folder watcher must not restart it")
        XCTAssertEqual(planner.select(parts: .qr, scope: clips), .start(.filter(.qr, scope: clips)), "picking it again does")
    }

    func testStaleFinishIsIgnored() {
        var planner = AnalysisPlanner()
        let qr = AnalysisDemand.filter(.qr, scope: clips)
        _ = planner.select(parts: .qr, scope: clips)
        _ = planner.select(parts: .qr, scope: photos)
        XCTAssertEqual(planner.finished(qr), .none)
        XCTAssertEqual(planner.running, .filter(.qr, scope: photos))
    }

    func testIndexingHoldsAStartAndDropsItIfTheUserLeaves() {
        var planner = AnalysisPlanner()
        _ = planner.indexing(true)
        XCTAssertEqual(planner.select(parts: .qr, scope: clips), .none)
        XCTAssertEqual(planner.select(parts: [], scope: clips), .none)
        XCTAssertEqual(planner.indexing(false, filterParts: [], scope: clips), .none)
        _ = planner.indexing(true)
        _ = planner.select(parts: .qr, scope: clips)
        XCTAssertEqual(planner.indexing(false, filterParts: .qr, scope: clips), .start(.filter(.qr, scope: clips)))
    }

    func testAnalyzeLibraryIsNotInterruptedByAFilterItCovers() {
        var planner = AnalysisPlanner()
        XCTAssertEqual(planner.analyzeLibrary(), .start(.library))
        XCTAssertEqual(planner.select(parts: .qr, scope: clips), .none)
        XCTAssertEqual(planner.select(parts: [], scope: clips), .none, "browsing keeps Analyze Library going")
        XCTAssertEqual(planner.running, .library)
        XCTAssertEqual(planner.finished(.library), .none)
        XCTAssertNil(planner.wanted)
    }

    func testFinishedFilterCatchesUpAfterIndexingOnlyWhileShown() {
        var planner = AnalysisPlanner()
        let qr = AnalysisDemand.filter(.qr, scope: clips)
        _ = planner.select(parts: .qr, scope: clips)
        XCTAssertEqual(planner.finished(qr), .none)
        _ = planner.indexing(true)
        XCTAssertEqual(planner.indexing(false, filterParts: .qr, scope: clips), .start(qr))
        _ = planner.finished(qr)
        _ = planner.select(parts: [], scope: clips)
        _ = planner.indexing(true)
        XCTAssertEqual(planner.indexing(false, filterParts: [], scope: clips), .none)
    }
}

/// Waits for cancellation (or 5 s) on every file, like text recognition on a big image.
private final class SlowScoring: ImageScoring, @unchecked Sendable {
    let started = Round9Collector<String>()
    func signals(for url: URL, kind: MediaType, parts: AnalysisParts) async -> ImageSignals {
        started.append(url.lastPathComponent)
        try? await Task.sleep(for: .seconds(5))
        return ImageSignals()
    }
}

private final class Round9Collector<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
