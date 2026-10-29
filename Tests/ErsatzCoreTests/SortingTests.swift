import XCTest
@testable import ErsatzCore

final class SortingTests: XCTestCase {
    func testNameOrderIsNumericAndCaseInsensitive() {
        XCTAssertEqual(FilenameOrder.compare("img1.jpg", "IMG2.jpg"), .orderedAscending)
        XCTAssertEqual(FilenameOrder.compare("IMG2.jpg", "IMG10.jpg"), .orderedAscending)
        XCTAssertEqual(FilenameOrder.compare("Café.JPG", "cafe.jpg"), .orderedDescending)
    }

    func testEverySortKeyAndNilPlacement() {
        let early = date(2020, 1, 2)
        let later = date(2021, 5, 3)
        let items = [
            item(id: 1, name: "IMG10.jpg", taken: later, modified: early, size: 50, width: 10, height: 10, video: nil, audio: "AAC"),
            item(id: 2, name: "IMG2.jpg", taken: early, modified: later, size: 500, width: 100, height: 100, video: "HEVC", audio: nil),
            item(id: 3, name: "note.wav", taken: nil, modified: early, size: 5, width: nil, height: nil, video: nil, audio: nil)
        ]

        XCTAssertEqual(names(items, .name, .ascending), ["IMG2.jpg", "IMG10.jpg", "note.wav"])
        XCTAssertEqual(names(items, .name, .descending), ["note.wav", "IMG10.jpg", "IMG2.jpg"])
        XCTAssertEqual(names(items, .dateTaken, .ascending), ["IMG2.jpg", "IMG10.jpg", "note.wav"])
        XCTAssertEqual(names(items, .dateTaken, .descending), ["IMG10.jpg", "IMG2.jpg", "note.wav"])
        XCTAssertEqual(names(items, .dateModified, .ascending), ["IMG10.jpg", "note.wav", "IMG2.jpg"])
        XCTAssertEqual(names(items, .dateModified, .descending), ["IMG2.jpg", "IMG10.jpg", "note.wav"])
        XCTAssertEqual(names(items, .fileSize, .ascending), ["note.wav", "IMG10.jpg", "IMG2.jpg"])
        XCTAssertEqual(names(items, .fileSize, .descending), ["IMG2.jpg", "IMG10.jpg", "note.wav"])
        XCTAssertEqual(names(items, .resolution, .ascending), ["IMG10.jpg", "IMG2.jpg", "note.wav"])
        XCTAssertEqual(names(items, .resolution, .descending), ["IMG2.jpg", "IMG10.jpg", "note.wav"])
        XCTAssertEqual(names(items, .codec, .ascending), ["IMG10.jpg", "IMG2.jpg", "note.wav"])
        XCTAssertEqual(names(items, .codec, .descending), ["IMG2.jpg", "IMG10.jpg", "note.wav"])
    }

    func testEqualNamesBreakTiesByID() {
        let items = [
            item(id: 8, name: "a.jpg", taken: nil, modified: date(2020, 1, 1), size: 1, width: nil, height: nil, video: nil, audio: nil),
            item(id: 2, name: "A.JPG", taken: nil, modified: date(2020, 1, 1), size: 1, width: nil, height: nil, video: nil, audio: nil)
        ]
        XCTAssertEqual(MediaSorter.sorted(items, key: .name, direction: .descending).map(\.id), [2, 8])
    }

    func testByteCount() {
        let locale = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(ByteCountText.string(bytes: 0, locale: locale), "0 B")
        XCTAssertEqual(ByteCountText.string(bytes: 1024, locale: locale), "1.0 KB")
        XCTAssertEqual(ByteCountText.string(bytes: 1536, locale: locale), "1.5 KB")
        XCTAssertEqual(ByteCountText.string(bytes: 1_048_576, locale: locale), "1.0 MB")
    }

    func testFolderTreeBuildsAncestors() {
        let tree = FolderTreeBuilder.makeTree([
            DirectoryCount(parentRelative: "2024/June", count: 2),
            DirectoryCount(parentRelative: "2024", count: 1),
            DirectoryCount(parentRelative: "Misc", count: 4),
            DirectoryCount(parentRelative: "", count: 9)
        ])
        XCTAssertEqual(tree.map(\.name), ["2024", "Misc"])
        XCTAssertEqual(tree[0].fileCount, 3)
        XCTAssertEqual(tree[0].children.map(\.name), ["June"])
        XCTAssertEqual(tree[0].children[0].fileCount, 2)
        XCTAssertEqual(tree[1].fileCount, 4)
    }

    func testDurationAndResolutionLabels() {
        let clip = item(id: 1, name: "a.mp4", taken: nil, modified: date(2020, 1, 1), size: 1, width: 1920, height: 1080, video: "H.264", audio: "AAC")
        XCTAssertEqual(clip.resolutionLabel, "1920×1080")
        XCTAssertEqual(clip.pixelCount, 1920 * 1080)
        XCTAssertEqual(clip.displayCodec, "H.264")
        var withDuration = clip
        withDuration.duration = 3661
        XCTAssertEqual(withDuration.durationLabel, "1:01:01")
    }

    func testMediaTypeDetection() {
        XCTAssertEqual(MediaTypeDetector.kind(for: "/a/IMG.JPEG"), .photo)
        XCTAssertEqual(MediaTypeDetector.kind(for: "/a/plate.CR3"), .raw)
        XCTAssertEqual(MediaTypeDetector.kind(for: "/a/clip.MOV"), .video)
        XCTAssertEqual(MediaTypeDetector.kind(for: "/a/song.FLAC"), .audio)
        XCTAssertNil(MediaTypeDetector.kind(for: "/a/notes.txt"))
    }

    func testEXIFDateRejectsGarbage() {
        XCTAssertNil(EXIFDateParser.parse("not a date"))
        XCTAssertNotNil(EXIFDateParser.parse("2024:06:01 12:00:00"))
        XCTAssertNotNil(EXIFDateParser.parse("2024:06:01 12:00:00.12"))
    }

    private func names(_ items: [MediaItem], _ key: SortKey, _ direction: SortDirection) -> [String] {
        MediaSorter.sorted(items, key: key, direction: direction).map(\.filename)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var parts = DateComponents()
        parts.calendar = CalendarParts.gregorian
        parts.timeZone = .current
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = 12
        return parts.date ?? Date()
    }

    private func item(
        id: Int64,
        name: String,
        taken: Date?,
        modified: Date,
        size: Int64,
        width: Int?,
        height: Int?,
        video: String?,
        audio: String?
    ) -> MediaItem {
        MediaItem(
            id: id,
            folderID: 1,
            path: "/library/\(name)",
            relativePath: name,
            filename: name,
            parentRelative: "",
            kind: .photo,
            fileSize: size,
            createdAt: nil,
            modifiedAt: modified,
            dateTaken: taken,
            takenYear: taken.flatMap { CalendarParts.yearMonth(of: $0)?.year },
            takenMonth: taken.flatMap { CalendarParts.yearMonth(of: $0)?.month },
            pixelWidth: width,
            pixelHeight: height,
            duration: nil,
            videoCodec: video,
            audioCodec: audio,
            cameraModel: nil,
            formatName: nil,
            indexedAt: modified
        )
    }
}
