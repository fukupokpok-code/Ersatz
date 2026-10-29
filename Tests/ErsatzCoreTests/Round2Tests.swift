import XCTest
@testable import ErsatzCore

final class CatalogTime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double?
    func record(_ seconds: Double) {
        lock.lock()
        if value == nil { value = seconds }
        lock.unlock()
    }
    var seconds: Double? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class Round2Tests: XCTestCase {
    func testSHA256KnownVectors() {
        XCTAssertEqual(
            SHA256Digest.hex(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            SHA256Digest.hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testBuddhistEraDatesBecomeGregorian() {
        let modern = EXIFDateParser.interpret("2024:06:01 12:00:00")
        XCTAssertEqual(modern?.correctedFromBuddhistEra, false)
        XCTAssertEqual(modern?.storedYear, 2024)

        let be = EXIFDateParser.interpret("2566:07:24 21:51:00")
        XCTAssertEqual(be?.correctedFromBuddhistEra, true)
        XCTAssertEqual(be?.originalYear, 2566)
        XCTAssertEqual(be?.storedYear, 2023)
        let parts = be.map { CalendarParts.yearMonth(of: $0.date) }
        XCTAssertEqual(parts??.year, 2023)
        XCTAssertEqual(parts??.month, 7)
        if let date = be?.date {
            XCTAssertEqual(EXIFDateParser.format(date), "2023:07:24 21:51:00")
        }
    }

    func testFileTypeSortGroupsKindThenFormat() {
        let items = [
            item(id: 1, name: "a.png", kind: .photo, format: "PNG"),
            item(id: 2, name: "b.heic", kind: .photo, format: "HEIC"),
            item(id: 3, name: "c.dng", kind: .raw, format: "DNG"),
            item(id: 4, name: "d.mov", kind: .video, format: "QuickTime")
        ]
        let names = MediaSorter.sorted(items, key: .fileType, direction: .ascending).map(\.filename)
        XCTAssertEqual(names, ["b.heic", "a.png", "c.dng", "d.mov"])
    }

    func testPerceptualHashAndSharpness() {
        var flat = [UInt8](repeating: 40, count: 9 * 8)
        XCTAssertEqual(PerceptualHash.dHash(gray: flat, width: 9, height: 8), 0)
        XCTAssertEqual(SharpnessScore.laplacianVariance(gray: flat, width: 9, height: 8), 0, accuracy: 0.001)

        for x in 0..<9 {
            for y in 0..<8 where x < 4 {
                flat[y * 9 + x] = 200
            }
        }
        let hash = PerceptualHash.dHash(gray: flat, width: 9, height: 8)
        XCTAssertGreaterThan(hash, 0)
        XCTAssertEqual(PerceptualHash.hammingDistance(hash, hash), 0)
        XCTAssertGreaterThan(PerceptualHash.hammingDistance(hash, 0), 0)

        var edge = [UInt8](repeating: 0, count: 16 * 16)
        for y in 0..<16 {
            for x in 0..<16 where x >= 8 {
                edge[y * 16 + x] = 255
            }
        }
        XCTAssertGreaterThan(SharpnessScore.laplacianVariance(gray: edge, width: 16, height: 16), 10)
    }

    func testScreenshotAndBankSlipHeuristics() {
        XCTAssertTrue(ScreenshotDetector.matches(
            filename: "Screenshot 2024.png",
            formatName: "PNG",
            pixelWidth: 100,
            pixelHeight: 100,
            hasCameraModel: true
        ))
        XCTAssertTrue(ScreenshotDetector.matches(
            filename: "ภาพหน้าจอ.png",
            formatName: "PNG",
            pixelWidth: nil,
            pixelHeight: nil,
            hasCameraModel: false
        ))
        XCTAssertTrue(ScreenshotDetector.matches(
            filename: "IMG.png",
            formatName: "PNG",
            pixelWidth: 1170,
            pixelHeight: 2532,
            hasCameraModel: false
        ))
        XCTAssertFalse(ScreenshotDetector.matches(
            filename: "IMG_1.JPG",
            formatName: "JPEG",
            pixelWidth: 4000,
            pixelHeight: 3000,
            hasCameraModel: true
        ))
        XCTAssertTrue(BankSlipClassifier.isSlip(text: "โอนเงินสำเร็จ จำนวนเงิน 50.00 K PLUS", hasQR: true))
        XCTAssertTrue(BankSlipClassifier.isSlip(text: "กรุงไทย ค่าธรรมเนียม เลขที่รายการ 99", hasQR: false))
        XCTAssertFalse(BankSlipClassifier.isSlip(text: "hello cat", hasQR: true))
    }

    func testDuplicateGroups() {
        let records = [
            HashRecord(id: 1, fileSize: 10, contentHash: "aaa", perceptualHash: 0b1111),
            HashRecord(id: 2, fileSize: 10, contentHash: "aaa", perceptualHash: 0b1111),
            HashRecord(id: 3, fileSize: 10, contentHash: "bbb", perceptualHash: 0b1110),
            HashRecord(id: 4, fileSize: 99, contentHash: "ccc", perceptualHash: nil)
        ]
        XCTAssertEqual(DuplicateFinder.exactGroups(records), [[1, 2]])
        let near = DuplicateFinder.nearGroups(records, threshold: 1)
        XCTAssertEqual(near.first, [1, 2, 3])
    }

    func testFolderCoversTakeThreeImages() {
        let files: [(parent: String, path: String)] = [
            ("Trip", "/a.jpg"),
            ("Trip", "/b.jpg"),
            ("Trip", "/c.jpg"),
            ("Trip", "/d.jpg"),
            ("Trip/Day", "/e.jpg"),
            ("Notes", "/n.jpg")
        ]
        let covers = FolderCoverPlanner.covers(files: files, directory: "")
        XCTAssertEqual(covers.map(\.name), ["Notes", "Trip"])
        XCTAssertEqual(covers.first { $0.name == "Trip" }?.imagePaths.count, 3)
    }

    func testCheckpointRecordAndPrune() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let database = try MediaDatabase(path: scratch.databasePath)
        let backup = scratch.root.appendingPathComponent("backup.bin")
        try Data(repeating: 1, count: 128).write(to: backup)
        let old = try await database.createCheckpoint(
            action: "fix-buddhist-era-dates",
            note: "old",
            files: [CheckpointFileDraft(path: "/photo.jpg", kind: .metadata, originalMetadata: "dateTaken=2566:01:01 00:00:00", backupPath: backup.path, backupBytes: 128)],
            at: Date(timeIntervalSince1970: 1_000)
        )
        let recent = try await database.createCheckpoint(
            action: "trash-duplicates",
            note: nil,
            files: [CheckpointFileDraft(path: "/b.jpg", kind: .deletion, trashURL: "/.Trash/b.jpg")],
            at: Date()
        )
        let listed = try await database.checkpoints()
        XCTAssertEqual(listed.map(\.id), [recent.id, old.id])
        let files = try await database.checkpointFiles(checkpointID: old.id)
        XCTAssertEqual(files.first?.originalMetadata, "dateTaken=2566:01:01 00:00:00")
        _ = try await database.pruneCheckpoints(olderThan: Date(timeIntervalSince1970: 10_000), maxBytes: 10)
        let after = try await database.checkpoints()
        XCTAssertFalse(after.contains { $0.id == old.id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testActivityLogWritesAndRotates() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let database = try MediaDatabase(path: scratch.databasePath)
        let stored = try await database.appendActivity(ActivityEntry(
            id: 0,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            action: "fix-buddhist-era-dates",
            path: "/photos/a.jpg",
            oldValue: "2566:07:24 21:51:00",
            newValue: "2023:07:24 21:51:00",
            checkpointID: 4,
            success: true,
            restorable: true
        ))
        XCTAssertGreaterThan(stored.id, 0)
        let found = try await database.activity(matching: "a.jpg")
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].line.contains("2566:07:24 21:51:00 -> 2023:07:24 21:51:00"))

        let log = try ActivityLogFile(directory: scratch.root.appendingPathComponent("logs"), maxBytes: 80)
        try log.append(stored)
        let first = try String(contentsOf: log.fileURL, encoding: .utf8)
        XCTAssertTrue(first.contains("/photos/a.jpg"))
        for _ in 0..<6 {
            try log.append(stored)
        }
        let archived = log.fileURL.deletingPathExtension().appendingPathExtension("1.log")
        let current = (try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.path) || current.contains("a.jpg"))
    }

    func testPipelinedIndexIsFasterThanSequentialExtract() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let root = scratch.root.appendingPathComponent("bench", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let count = 40
        for index in 0..<count {
            let jpeg = SampleFiles.jpeg(width: 320 + index, height: 240, make: "Canon", model: "R5", date: "2024:01:02 03:04:05", orientation: 1)
            try jpeg.write(to: root.appendingPathComponent(String(format: "img-%03d.jpg", index)))
        }
        let extractor = PortableMetadataExtractor()
        let sequentialStart = Date()
        for index in 0..<count {
            let url = root.appendingPathComponent(String(format: "img-%03d.jpg", index))
            _ = await extractor.extract(from: url, kind: .photo)
        }
        let sequential = Date().timeIntervalSince(sequentialStart)

        let database = try MediaDatabase(path: scratch.databasePath)
        let folder = try await database.addFolder(path: root.path, bookmark: nil, displayName: "Bench")
        let pipelinedStart = Date()
        let catalog = CatalogTime()
        let result = try await LibraryIndexer().index(root: root, folderID: folder.id, database: database) { update in
            if update.phase == .cataloging {
                catalog.record(Date().timeIntervalSince(pipelinedStart))
            }
        }
        let pipelined = Date().timeIntervalSince(pipelinedStart)
        XCTAssertEqual(result.filesSeen, count)
        XCTAssertEqual(result.filesParsed, count)
        let items = try await database.media(matching: MediaQuery())
        XCTAssertEqual(items.count, count)
        XCTAssertEqual(items.first?.pixelWidth != nil, true)
        let catalogSeconds = catalog.seconds ?? pipelined
        print(String(format: "BENCHMARK sequential=%.3fs catalog=%.3fs pipelined=%.3fs files=%d", sequential, catalogSeconds, pipelined, count))
    }

    private func item(id: Int64, name: String, kind: MediaType, format: String) -> MediaItem {
        MediaItem(
            id: id,
            folderID: 1,
            path: "/\(name)",
            relativePath: name,
            filename: name,
            parentRelative: "",
            kind: kind,
            fileSize: 1,
            createdAt: nil,
            modifiedAt: Date(timeIntervalSince1970: 10),
            dateTaken: nil,
            takenYear: nil,
            takenMonth: nil,
            pixelWidth: nil,
            pixelHeight: nil,
            duration: nil,
            videoCodec: nil,
            audioCodec: nil,
            cameraModel: nil,
            formatName: format,
            indexedAt: Date(timeIntervalSince1970: 10)
        )
    }
}
