import XCTest
@testable import ErsatzCore

final class IndexingTests: XCTestCase {
    func testIndexParsesSamplesAndSkipsUnchangedFiles() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let root = scratch.root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("trip"), withIntermediateDirectories: true)
        try SampleFiles.jpeg(
            width: 4608,
            height: 3072,
            make: "Canon",
            model: "EOS R5",
            date: "2024:06:01 12:00:00",
            orientation: 1
        ).write(to: root.appendingPathComponent("frame.jpg"))
        try SampleFiles.png(width: 32, height: 16).write(to: root.appendingPathComponent("trip/sheet.png"))
        try SampleFiles.wav(sampleRate: 8000, channels: 1, bits: 16, frames: 8000)
            .write(to: root.appendingPathComponent("trip/tone.wav"))
        try SampleFiles.mp4(width: 320, height: 240, duration: 2500, timescale: 1000)
            .write(to: root.appendingPathComponent("clip.mp4"))
        try SampleFiles.tiff(
            littleEndian: true,
            width: 6000,
            height: 4000,
            make: "NIKON CORPORATION",
            model: "NIKON Z 8",
            date: "2023:11:02 09:30:00",
            orientation: 1
        ).write(to: root.appendingPathComponent("plate.dng"))
        try Data("hello".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try Data([0xFF, 0xD8]).write(to: root.appendingPathComponent(".hidden.jpg"))
        try Data([0xFF, 0xD8]).write(to: root.appendingPathComponent("._frame.jpg"))
        let link = root.appendingPathComponent("link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("frame.jpg"))

        let database = try MediaDatabase(path: scratch.databasePath)
        let folder = try await database.addFolder(path: root.path, bookmark: Data("scope".utf8), displayName: "Library")
        let updates = ProgressBox()
        let first = try await LibraryIndexer().index(root: root, folderID: folder.id, database: database) { updates.append($0) }
        XCTAssertEqual(first.filesSeen, 5)
        XCTAssertEqual(first.filesParsed, 5)
        XCTAssertEqual(first.filesSkipped, 0)
        XCTAssertEqual(first.filesRemoved, 0)
        XCTAssertEqual(updates.values.last?.phase, .finished)

        let items = MediaSorter.sorted(
            try await database.media(matching: MediaQuery()),
            key: .name,
            direction: .ascending
        )
        XCTAssertEqual(items.map(\.filename), ["clip.mp4", "frame.jpg", "plate.dng", "sheet.png", "tone.wav"])
        let photo = try XCTUnwrap(items.first { $0.filename == "frame.jpg" })
        XCTAssertEqual(photo.kind, .photo)
        XCTAssertEqual(photo.pixelWidth, 4608)
        XCTAssertEqual(photo.pixelHeight, 3072)
        XCTAssertEqual(photo.cameraModel, "Canon EOS R5")
        XCTAssertEqual(photo.takenYear, 2024)
        XCTAssertEqual(photo.takenMonth, 6)
        XCTAssertEqual(photo.formatName, "JPEG")
        XCTAssertEqual(photo.parentRelative, "")

        let raw = try XCTUnwrap(items.first { $0.filename == "plate.dng" })
        XCTAssertEqual(raw.kind, .raw)
        XCTAssertEqual(raw.formatName, "DNG")
        XCTAssertEqual(raw.cameraModel, "NIKON Z 8")
        XCTAssertEqual(raw.pixelWidth, 6000)

        let clip = try XCTUnwrap(items.first { $0.filename == "clip.mp4" })
        XCTAssertEqual(clip.videoCodec, "H.264")
        XCTAssertEqual(clip.audioCodec, "AAC")
        XCTAssertEqual(clip.pixelWidth, 320)
        XCTAssertEqual(clip.duration ?? 0, 2.5, accuracy: 0.001)

        let tone = try XCTUnwrap(items.first { $0.filename == "tone.wav" })
        XCTAssertEqual(tone.kind, .audio)
        XCTAssertEqual(tone.audioCodec, "PCM")
        XCTAssertEqual(tone.parentRelative, "trip")
        XCTAssertEqual(tone.duration ?? 0, 1, accuracy: 0.001)

        let second = try await LibraryIndexer().index(root: root, folderID: folder.id, database: database)
        XCTAssertEqual(second.filesParsed, 0)
        XCTAssertEqual(second.filesSkipped, 5)
        XCTAssertEqual(second.filesRemoved, 0)

        try SampleFiles.jpeg(width: 100, height: 80, make: "Canon", model: "EOS R5", date: "2024:07:04 08:00:00", orientation: 1)
            .write(to: root.appendingPathComponent("frame.jpg"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("trip/tone.wav"))
        try SampleFiles.gif(width: 3, height: 4).write(to: root.appendingPathComponent("trip/extra.gif"))

        let third = try await LibraryIndexer().index(root: root, folderID: folder.id, database: database)
        XCTAssertEqual(third.filesRemoved, 1)
        XCTAssertEqual(third.filesParsed, 2)
        XCTAssertEqual(third.filesSkipped, 3)
        let after = try await database.media(matching: MediaQuery())
        XCTAssertEqual(Set(after.map(\.filename)), ["clip.mp4", "frame.jpg", "plate.dng", "sheet.png", "extra.gif"])
        let updated = try XCTUnwrap(after.first { $0.filename == "frame.jpg" })
        XCTAssertEqual(updated.pixelWidth, 100)
        XCTAssertEqual(updated.takenMonth, 7)

        let forced = try await LibraryIndexer().index(root: root, folderID: folder.id, database: database, force: true)
        XCTAssertEqual(forced.filesParsed, 5)
        XCTAssertEqual(forced.filesSkipped, 0)
    }

    func testScannerSkipsHiddenAndNonMedia() throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let root = scratch.root.appendingPathComponent("scan", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8]).write(to: root.appendingPathComponent("a.jpg"))
        try Data("x".utf8).write(to: root.appendingPathComponent("a.txt"))
        let files = try FileScanner().enumerate(root: root)
        XCTAssertEqual(files.map(\.filename), ["a.jpg"])
        XCTAssertEqual(files.first?.kind, .photo)
    }

    func testThumbnailCacheRoundTrip() throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let cache = try ThumbnailCache(directory: scratch.root.appendingPathComponent("thumbs"))
        let payload = Data("jpeg-bytes".utf8)
        try cache.store(payload, itemID: 7, token: "100-256")
        XCTAssertEqual(cache.load(itemID: 7, token: "100-256"), payload)
        try cache.store(Data("other".utf8), itemID: 7, token: "200-256")
        try cache.remove(itemID: 7)
        XCTAssertNil(cache.load(itemID: 7, token: "100-256"))
        XCTAssertNil(cache.load(itemID: 7, token: "200-256"))
    }

    func testAppPathsCreateDirectories() throws {
        let database = try AppPaths.databaseURL()
        let thumbs = try AppPaths.thumbnailCacheURL()
        XCTAssertTrue(database.lastPathComponent == "library.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbs.path))
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [IndexProgress] = []
    func append(_ progress: IndexProgress) {
        lock.lock()
        storage.append(progress)
        lock.unlock()
    }
    var values: [IndexProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class Scratch {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ersatz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    var databasePath: String { root.appendingPathComponent("library.sqlite").path }
    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
