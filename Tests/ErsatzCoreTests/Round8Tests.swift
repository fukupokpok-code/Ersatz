import XCTest
@testable import ErsatzCore

/// Round 8: a blur score that sees motion blur and camera shake.
final class BlurDetectorTests: XCTestCase {
    func testSharpTextureScoresHigh() {
        let image = SyntheticImage.texture()
        XCTAssertGreaterThan(sharpness(image), 60)
    }

    func testMotionBlurInEveryDirectionScoresBelowThreshold() {
        let image = SyntheticImage.texture()
        let cases: [(String, [Int])] = [
            ("horizontal 9", image.along(dx: 1, dy: 0, length: 9)),
            ("horizontal 5", image.along(dx: 1, dy: 0, length: 5)),
            ("diagonal 9", image.along(dx: 1, dy: 1, length: 9)),
            ("vertical 7", image.along(dx: 0, dy: 1, length: 7)),
        ]
        for (name, blurred) in cases {
            let score = sharpness(SyntheticImage(pixels: blurred))
            XCTAssertLessThan(score, Double(BlurDetector.defaultThreshold), name)
        }
    }

    func testCameraShakeAndDefocusScoreBelowThreshold() {
        let image = SyntheticImage.texture()
        let shake = SyntheticImage(pixels: SyntheticImage(pixels: image.along(dx: 1, dy: 0, length: 7)).along(dx: 0, dy: 1, length: 3))
        XCTAssertLessThan(sharpness(shake), Double(BlurDetector.defaultThreshold), "shake 7x3")
        let defocus = SyntheticImage(pixels: SyntheticImage(pixels: image.along(dx: 1, dy: 0, length: 5)).along(dx: 0, dy: 1, length: 5))
        XCTAssertLessThan(sharpness(defocus), Double(BlurDetector.defaultThreshold), "defocus 5x5")
    }

    func testMoreBlurNeverScoresSharper() {
        let image = SyntheticImage.texture()
        let light = sharpness(SyntheticImage(pixels: image.along(dx: 1, dy: 0, length: 3)))
        let heavy = sharpness(SyntheticImage(pixels: image.along(dx: 1, dy: 0, length: 9)))
        XCTAssertGreaterThan(sharpness(image), light)
        XCTAssertGreaterThan(light, heavy)
    }

    func testFlatImageScoresZeroAndStaysInRange() {
        let flat = [UInt8](repeating: 100, count: 64 * 64)
        XCTAssertEqual(BlurDetector.sharpness(gray: flat, width: 64, height: 64), 0)
        let score = sharpness(SyntheticImage.texture())
        XCTAssertTrue((0...100).contains(score))
    }

    func testWorkingDimensionsKeepAspectRatio() {
        let size = BlurDetector.workingDimensions(width: 4032, height: 3024)
        XCTAssertEqual(size.width, BlurDetector.workingSize)
        XCTAssertEqual(size.height, 384)
        let small = BlurDetector.workingDimensions(width: 300, height: 200)
        XCTAssertEqual(small.width, 300)
        XCTAssertEqual(small.height, 200)
    }

    private func sharpness(_ image: SyntheticImage) -> Double {
        BlurDetector.sharpness(gray: image.gray, width: image.side, height: image.side)
    }
}

/// The same generator as the calibration script: random flat rectangles on grey.
struct SyntheticImage {
    let side: Int
    let pixels: [Int]

    init(side: Int = 256, pixels: [Int]) {
        self.side = side
        self.pixels = pixels
    }

    var gray: [UInt8] { pixels.map { UInt8(clamping: $0) } }

    static func texture(side: Int = 256, seed: UInt64 = 42) -> SyntheticImage {
        var state = seed
        func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 33)
        }
        var pixels = [Int](repeating: 128, count: side * side)
        for _ in 0..<80 {
            let x = next() % side, y = next() % side
            let w = 8 + next() % 48, h = 8 + next() % 48
            let value = next() % 256
            for row in y..<min(side, y + h) {
                for column in x..<min(side, x + w) {
                    pixels[row * side + column] = value
                }
            }
        }
        return SyntheticImage(side: side, pixels: pixels)
    }

    /// Averages `length` pixels along (dx, dy), clamped at the edges: motion blur.
    func along(dx: Int, dy: Int, length: Int) -> [Int] {
        let half = length / 2
        var out = [Int](repeating: 0, count: pixels.count)
        for y in 0..<side {
            for x in 0..<side {
                var sum = 0
                for k in -half...half {
                    let xx = min(side - 1, max(0, x + k * dx))
                    let yy = min(side - 1, max(0, y + k * dy))
                    sum += pixels[yy * side + xx]
                }
                out[y * side + x] = sum / length
            }
        }
        return out
    }
}

/// Round 8: schema v4, removing trashed files, progressive saves and the scoring context.
final class Round8DatabaseTests: XCTestCase {
    func testVersion3LibraryMarksBlurQRAndSlipsStale() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        do {
            let database = try MediaDatabase(path: scratch.databasePath)
            let folder = try await database.addFolder(path: "/trip", bookmark: nil, displayName: "Trip")
            try await database.upsert([media(folder.id, "/trip/a.jpg")])
            let item = try await database.media(matching: MediaQuery())[0]
            try await database.saveAnalysis([update(item.id, hash: "kept", sharpness: 10, qr: true)])
        }
        do {
            let raw = try SQLiteConnection(path: scratch.databasePath)
            try raw.execute("PRAGMA user_version = 3")
        }
        let database = try MediaDatabase(path: scratch.databasePath)
        let item = try await database.media(matching: MediaQuery())[0]
        let parts = try await database.analyzedParts(mediaID: item.id)
        XCTAssertEqual(parts, [.screenshot, .hashes, .perceptual])
        // The old blur value was on another scale, so it is gone; hashes and QR stay.
        let blurry = try await database.media(matching: MediaQuery(blurryOnly: true, blurryThreshold: 90))
        XCTAssertTrue(blurry.isEmpty)
        let hashes = try await database.hashRecords()
        XCTAssertEqual(hashes.first?.contentHash, "kept")
        let summary = try await database.summary()
        XCTAssertEqual(summary.qrCount, 1)
        let pending = try await database.pendingAnalysis(parts: .sharpness)
        XCTAssertEqual(pending.map(\.id), [item.id])
        let duplicatesPending = try await database.pendingAnalysis(parts: .duplicates)
        XCTAssertTrue(duplicatesPending.isEmpty)
    }

    func testRemoveMediaDropsRowsAndAnalysisButKeepsHistory() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let database = try MediaDatabase(path: scratch.databasePath)
        let folder = try await database.addFolder(path: "/trip", bookmark: nil, displayName: "Trip")
        try await database.upsert([media(folder.id, "/trip/a.jpg"), media(folder.id, "/trip/b.jpg")])
        let items = try await database.media(matching: MediaQuery())
        try await database.saveAnalysis(items.map { update($0.id, hash: "same") })
        let a = items.first { $0.filename == "a.jpg" }!
        let checkpoint = try await database.createCheckpoint(
            action: "trash-files", note: nil, files: [CheckpointFileDraft(path: a.path, kind: .deletion)]
        )
        try await database.recordTrashURL(checkpointID: checkpoint.id, path: a.path, trashURL: "/Users/x/.Trash/a.jpg")

        let removed = try await database.removeMedia(ids: [a.id, a.id])
        XCTAssertEqual(removed, 1)

        let left = try await database.media(matching: MediaQuery())
        XCTAssertEqual(left.map(\.filename), ["b.jpg"])
        let hashes = try await database.hashRecords()
        XCTAssertEqual(hashes.map(\.id), [left[0].id])
        let files = try await database.checkpointFiles(checkpointID: checkpoint.id)
        XCTAssertEqual(files.first?.trashURL, "/Users/x/.Trash/a.jpg", "History can put it back")
        let violations = try await database.foreignKeyViolationCount()
        XCTAssertEqual(violations, 0)
        let none = try await database.removeMedia(ids: [])
        XCTAssertEqual(none, 0)
    }

    func testAnalyzerReportsEachSavedBatch() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let database = try MediaDatabase(path: scratch.databasePath)
        let folder = try await database.addFolder(path: "/x", bookmark: nil, displayName: "X")
        try await database.upsert((0..<45).map { media(folder.id, "/x/\($0).jpg") })
        let batches = Collector<Int>()
        try await LibraryAnalyzer(workerCount: 3, batchSize: 20).analyze(
            database: database, parts: .sharpness, scoring: EmptyImageScoring(),
            saved: { batches.append($0) }
        )
        XCTAssertEqual(batches.values, [20, 20, 5])
        let left = try await database.pendingAnalysis(parts: .sharpness)
        XCTAssertTrue(left.isEmpty)
    }

    func testScorerGetsCameraAndSizeContext() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let database = try MediaDatabase(path: scratch.databasePath)
        let folder = try await database.addFolder(path: "/x", bookmark: nil, displayName: "X")
        try await database.upsert([
            media(folder.id, "/x/camera.jpg", camera: "iPhone 15 Pro", width: 4032, height: 3024),
            media(folder.id, "/x/slip.png", camera: nil, width: 1284, height: 2778)
        ])
        let scoring = ContextScoring()
        try await LibraryAnalyzer(workerCount: 1).analyze(database: database, parts: .bankSlip, scoring: scoring)
        let seen = await scoring.seen
        XCTAssertEqual(seen["slip.png"], ScoringContext(hasCameraModel: false, pixelWidth: 1284, pixelHeight: 2778))
        XCTAssertEqual(seen["camera.jpg"], ScoringContext(hasCameraModel: true, pixelWidth: 4032, pixelHeight: 3024))
        let parts = await scoring.parts
        XCTAssertEqual(Set(parts), [AnalysisParts([.qr, .bankSlip])])
    }

    func testQRAndSlipsAnalyzeFilesWithoutACameraFirst() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let database = try MediaDatabase(path: scratch.databasePath)
        let folder = try await database.addFolder(path: "/x", bookmark: nil, displayName: "X")
        try await database.upsert([
            media(folder.id, "/x/a.jpg", camera: "Canon"),
            media(folder.id, "/x/b.png", camera: nil),
            media(folder.id, "/x/c.jpg", camera: "Canon"),
            media(folder.id, "/x/d.png", camera: nil)
        ])
        let qr = try await database.pendingAnalysis(parts: .qr)
        XCTAssertEqual(qr.map(\.filename), ["b.png", "d.png", "a.jpg", "c.jpg"])
        let slips = try await database.pendingAnalysis(parts: AnalysisParts.bankSlip.closed)
        XCTAssertEqual(slips.map(\.filename), ["b.png", "d.png", "a.jpg", "c.jpg"])
        let blur = try await database.pendingAnalysis(parts: .sharpness)
        XCTAssertEqual(blur.map(\.filename), ["a.jpg", "b.png", "c.jpg", "d.png"])
    }

    private func media(_ folder: Int64, _ path: String, camera: String? = nil, width: Int? = nil, height: Int? = nil) -> NewMedia {
        let name = (path as NSString).lastPathComponent
        let relative = path.split(separator: "/").dropFirst().joined(separator: "/")
        return NewMedia(
            folderID: folder, path: path, relativePath: relative, filename: name,
            parentRelative: (relative as NSString).deletingLastPathComponent, kind: .photo, fileSize: 100,
            createdAt: nil, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), dateTaken: nil,
            pixelWidth: width, pixelHeight: height, videoCodec: nil, cameraModel: camera
        )
    }

    private func update(_ id: Int64, hash: String, sharpness: Double = 80, qr: Bool = false) -> AnalysisUpdate {
        AnalysisUpdate(
            mediaID: id, partialHash: hash, contentHash: hash, perceptualHash: 1, sharpness: sharpness,
            isScreenshot: false, hasQR: qr, isBankSlip: false,
            analyzedMTime: 1_700_000_000_000
        )
    }
}

final class Round8GateAndSlipTests: XCTestCase {
    func testBackgroundSharesTheMachineWhileThumbnailsRun() async {
        let gate = WorkGate(foregroundLimit: 4, backgroundLimit: 2)
        await gate.enter(.foreground)
        // A thumbnail is rendering but none waits: analysis keeps one of its two slots.
        await gate.enter(.background)
        let second = Task {
            await gate.enter(.background)
            await gate.leave(.background)
        }
        try? await Task.sleep(for: .milliseconds(40))
        var state = await gate.snapshot
        XCTAssertEqual(state.background, 1)
        XCTAssertEqual(state.waitingBackground, 1)
        // Once thumbnails are idle analysis gets both slots.
        await gate.leave(.foreground)
        await second.value
        state = await gate.snapshot
        XCTAssertEqual(state.waitingBackground, 0)
        await gate.leave(.background)
        state = await gate.snapshot
        XCTAssertEqual(state.background, 0)
    }

    func testThaiSlipTextSplitBySpacesStillMatches() {
        let text = "โอน เงิน สำเร็จ\nจำนวน เงิน\n500.00 บาท"
        XCTAssertTrue(BankSlipClassifier.isSlip(text: text, hasQR: true))
        XCTAssertFalse(BankSlipClassifier.isSlip(text: text, hasQR: false))
        let full = text + "\nค่า ธรรม เนียม 0.00"
        XCTAssertTrue(BankSlipClassifier.isSlip(text: full, hasQR: false))
    }

    func testNewSlipPhrasesFromThaiBankApps() {
        XCTAssertTrue(BankSlipClassifier.isSlip(text: "ทำรายการสำเร็จ\nรหัสอ้างอิง 0123\nสแกนตรวจสอบสลิป", hasQR: false))
        XCTAssertTrue(BankSlipClassifier.isSlip(text: "Transaction ID 123\nMake by KBank", hasQR: true))
        XCTAssertFalse(BankSlipClassifier.isSlip(text: "Menu\nScan to order", hasQR: true))
        XCTAssertFalse(BankSlipClassifier.isSlip(text: "", hasQR: true))
    }

    func testTextIsReadOnlyWhereASlipIsPlausible() {
        XCTAssertTrue(BankSlipClassifier.shouldReadText(hasQR: true, hasCameraModel: true))
        XCTAssertTrue(BankSlipClassifier.shouldReadText(hasQR: false, hasCameraModel: false))
        XCTAssertFalse(BankSlipClassifier.shouldReadText(hasQR: false, hasCameraModel: true))
    }
}

/// Round 8: the Duplicates view's sets and the viewer's scoped sequence.
final class DuplicateSetTests: XCTestCase {
    func testExactSetKeepsTheOldestFileAndListsCopiesWithPaths() {
        let items = [
            item(1, "/Photos/Copy/IMG_1.jpg", created: 300),
            item(2, "/Photos/IMG_1.jpg", created: 100),
            item(3, "/Downloads/IMG_1.jpg", created: 200)
        ]
        let sets = DuplicateSetBuilder.sets(exact: [[1, 2, 3]], similar: [], items: items)
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets[0].number, 1)
        XCTAssertEqual(sets[0].kind, .exact)
        XCTAssertEqual(sets[0].original.path, "/Photos/IMG_1.jpg")
        XCTAssertEqual(sets[0].copies.map(\.id), [3, 1])
        XCTAssertEqual(sets[0].memberIDs, [2, 3, 1])
        XCTAssertEqual(sets[0].reclaimableBytes, 2000)
    }

    func testSimilarSetKeepsTheBiggestPicture() {
        let items = [
            item(4, "/a/small.jpg", created: 100, width: 1024, height: 768),
            item(5, "/a/big.jpg", created: 200, width: 4032, height: 3024)
        ]
        let sets = DuplicateSetBuilder.sets(exact: [], similar: [[4, 5]], items: items)
        XCTAssertEqual(sets.first?.kind, .similar)
        XCTAssertEqual(sets.first?.original.id, 5)
        XCTAssertEqual(sets.first?.copies.map(\.id), [4])
    }

    func testSimilarGroupRepeatingAnExactOneIsDroppedAndSetsAreNumbered() {
        let items = (1...6).map { item(Int64($0), "/p/\($0).jpg", created: Double($0)) }
        let sets = DuplicateSetBuilder.sets(
            exact: [[1, 2], [3, 9]],
            similar: [[2, 1], [4, 5, 6]],
            items: items
        )
        // [3, 9] has one known member and [2, 1] repeats the exact set.
        XCTAssertEqual(sets.map(\.number), [1, 2])
        XCTAssertEqual(sets.map(\.kind), [.exact, .similar])
        XCTAssertEqual(sets.map(\.memberIDs), [[1, 2], [4, 5, 6]])
        XCTAssertEqual(Set(sets.map(\.id)).count, 2)
    }

    func testViewerWindowStaysInsideTheSequence() {
        let ids: [Int64] = Array(1...30)
        XCTAssertEqual(ViewerSequence.window(ids, around: 1, radius: 2), [1, 2, 3])
        XCTAssertEqual(ViewerSequence.window(ids, around: 15, radius: 2), [13, 14, 15, 16, 17])
        XCTAssertEqual(ViewerSequence.window([7, 8, 9], around: 8), [7, 8, 9])
        XCTAssertEqual(ViewerSequence.window(ids, around: 99), [])
    }

    func testStepClampsAtTheEndsOfADuplicateSet() {
        let set: [Int64] = [40, 12, 77]
        XCTAssertEqual(ViewerSequence.step(set, from: 40, by: 1), 12)
        XCTAssertEqual(ViewerSequence.step(set, from: 77, by: 1), 77)
        XCTAssertEqual(ViewerSequence.step(set, from: 40, by: -1), 40)
        XCTAssertEqual(ViewerSequence.step(set, from: nil, by: 1), 40)
        XCTAssertNil(ViewerSequence.step([], from: 1, by: 1))
    }

    func testAfterDeleteTheViewerMovesToTheNextItem() {
        let ids: [Int64] = [1, 2, 3, 4]
        XCTAssertEqual(ViewerSequence.successor(ids, removing: [2], current: 2), 3)
        XCTAssertEqual(ViewerSequence.successor(ids, removing: [4], current: 4), 3)
        XCTAssertEqual(ViewerSequence.successor(ids, removing: [2, 3], current: 2), 4)
        XCTAssertNil(ViewerSequence.successor([5], removing: [5], current: 5))
    }

    private func item(_ id: Int64, _ path: String, created: Double, width: Int? = nil, height: Int? = nil) -> MediaItem {
        let url = URL(fileURLWithPath: path)
        return MediaItem(
            id: id, folderID: 1, path: path, relativePath: String(path.dropFirst()),
            filename: url.lastPathComponent, parentRelative: "", kind: .photo, fileSize: 1000,
            createdAt: Date(timeIntervalSince1970: created), modifiedAt: Date(timeIntervalSince1970: created),
            dateTaken: nil, takenYear: nil, takenMonth: nil, pixelWidth: width, pixelHeight: height,
            duration: nil, videoCodec: nil, audioCodec: nil, cameraModel: nil, formatName: nil,
            indexedAt: Date(timeIntervalSince1970: created)
        )
    }
}

private actor ContextScoring: ImageScoring {
    private(set) var seen: [String: ScoringContext] = [:]
    private(set) var parts: [AnalysisParts] = []

    func signals(for url: URL, kind: MediaType, parts: AnalysisParts) async -> ImageSignals {
        ImageSignals()
    }

    func signals(for url: URL, kind: MediaType, parts: AnalysisParts, context: ScoringContext) async -> ImageSignals {
        seen[url.lastPathComponent] = context
        self.parts.append(parts)
        return ImageSignals()
    }
}

private final class Collector<Value: Sendable>: @unchecked Sendable {
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
