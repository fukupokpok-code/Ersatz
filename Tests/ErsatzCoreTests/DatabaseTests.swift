import XCTest
@testable import ErsatzCore

final class DatabaseTests: XCTestCase {
    func testSchemaFolderBookmarkAndCascade() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let database = try MediaDatabase(path: scratch.databasePath)
        let bookmark = Data("bookmark".utf8)
        let folder = try await database.addFolder(path: "/photos", bookmark: bookmark, displayName: "Photos")
        let loaded = try await database.folders()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, folder.id)
        XCTAssertEqual(loaded[0].bookmark, bookmark)
        XCTAssertEqual(loaded[0].displayName, "Photos")

        do {
            _ = try await database.addFolder(path: "/photos", bookmark: nil, displayName: "Again")
            XCTFail("expected a duplicate folder")
        } catch let error as DatabaseError {
            guard case .duplicate = error else {
                return XCTFail("unexpected error \(error)")
            }
        }

        try await database.upsert([
            sample(folder: folder.id, path: "/photos/a.jpg", parent: "", name: "a.jpg"),
            sample(folder: folder.id, path: "/photos/trip/b.jpg", parent: "trip", name: "b.jpg", year: 2024, month: 3)
        ])
        let all = try await database.media(matching: MediaQuery())
        XCTAssertEqual(all.count, 2)

        try await database.removeFolder(id: folder.id)
        let after = try await database.media(matching: MediaQuery())
        let remainingFolders = try await database.folders()
        XCTAssertEqual(after.count, 0)
        XCTAssertEqual(remainingFolders.count, 0)
    }

    func testQueriesByTypeDateAndDirectory() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let database = try MediaDatabase(path: scratch.databasePath)
        let folder = try await database.addFolder(path: "/library", bookmark: nil, displayName: "Library")
        let odd = try await database.addFolder(path: "/odd", bookmark: nil, displayName: "Odd")
        try await database.upsert([
            sample(folder: folder.id, path: "/library/a.jpg", parent: "", name: "a.jpg", kind: .photo, year: 2024, month: 1),
            sample(folder: folder.id, path: "/library/trip/b.cr2", parent: "trip", name: "b.cr2", kind: .raw, year: 2024, month: 6),
            sample(folder: folder.id, path: "/library/trip/day/c.mp4", parent: "trip/day", name: "c.mp4", kind: .video, year: 2022, month: 12),
            sample(folder: folder.id, path: "/library/a_b%/d.wav", parent: "a_b%", name: "d.wav", kind: .audio),
            sample(folder: odd.id, path: "/odd/e.png", parent: "", name: "e.png", kind: .photo, year: 2024, month: 1)
        ])

        let trip = try await database.media(matching: MediaQuery(folderID: folder.id, directoryPrefix: "trip"))
        XCTAssertEqual(Set(trip.map(\.filename)), ["b.cr2", "c.mp4"])

        let escaped = try await database.media(matching: MediaQuery(folderID: folder.id, directoryPrefix: "a_b%"))
        XCTAssertEqual(escaped.map(\.filename), ["d.wav"])

        let notTrip2 = try await database.media(matching: MediaQuery(folderID: folder.id, directoryPrefix: "tri"))
        XCTAssertTrue(notTrip2.isEmpty)

        let june = try await database.media(matching: MediaQuery(year: 2024, month: 6))
        XCTAssertEqual(june.map(\.filename), ["b.cr2"])

        let videos = try await database.media(matching: MediaQuery(kind: .video))
        XCTAssertEqual(videos.map(\.filename), ["c.mp4"])

        let unknown = try await database.media(matching: MediaQuery(unknownDateOnly: true))
        XCTAssertEqual(unknown.map(\.filename), ["d.wav"])

        let summary = try await database.summary()
        XCTAssertEqual(summary.totalCount, 5)
        XCTAssertEqual(summary.unknownDateCount, 1)
        XCTAssertEqual(summary.kindCounts[.raw], 1)
        XCTAssertEqual(summary.folderCounts[folder.id], 4)
        let tree = FolderTreeBuilder.makeTree(summary.directoryCounts[folder.id] ?? [])
        XCTAssertEqual(tree.map(\.name), ["a_b%", "trip"])
        XCTAssertEqual(tree.first { $0.name == "trip" }?.fileCount, 2)
        XCTAssertEqual(tree.first { $0.name == "trip" }?.children.map(\.name), ["day"])

        let removed = try await database.deleteUnseen(folderID: folder.id, seen: ["/library/a.jpg"])
        XCTAssertEqual(removed, 3)
        let left = try await database.media(matching: MediaQuery(folderID: folder.id))
        XCTAssertEqual(left.map(\.filename), ["a.jpg"])
    }

    func testUpsertRefreshesMetadata() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let database = try MediaDatabase(path: scratch.databasePath)
        let folder = try await database.addFolder(path: "/p", bookmark: nil, displayName: "P")
        try await database.upsert([
            sample(folder: folder.id, path: "/p/a.jpg", parent: "", name: "a.jpg", width: 10, height: 10)
        ])
        try await database.upsert([
            sample(folder: folder.id, path: "/p/a.jpg", parent: "", name: "a.jpg", width: 20, height: 30, codec: "HEVC")
        ])
        let items = try await database.media(matching: MediaQuery())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].pixelWidth, 20)
        XCTAssertEqual(items[0].pixelHeight, 30)
        XCTAssertEqual(items[0].videoCodec, "HEVC")
    }

    func testReopenKeepsRows() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let first = try MediaDatabase(path: scratch.databasePath)
        _ = try await first.addFolder(path: "/keep", bookmark: Data([1, 2, 3]), displayName: "Keep")
        let second = try MediaDatabase(path: scratch.databasePath)
        let folders = try await second.folders()
        XCTAssertEqual(folders.map(\.displayName), ["Keep"])
        XCTAssertEqual(folders.first?.bookmark, Data([1, 2, 3]))
    }

    private func sample(
        folder: Int64,
        path: String,
        parent: String,
        name: String,
        kind: MediaType = .photo,
        year: Int? = nil,
        month: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        codec: String? = nil
    ) -> NewMedia {
        var taken: Date?
        if let year, let month {
            var parts = DateComponents()
            parts.calendar = CalendarParts.gregorian
            parts.timeZone = .current
            parts.year = year
            parts.month = month
            parts.day = 15
            parts.hour = 12
            taken = parts.date
        }
        return NewMedia(
            folderID: folder,
            path: path,
            relativePath: parent.isEmpty ? name : "\(parent)/\(name)",
            filename: name,
            parentRelative: parent,
            kind: kind,
            fileSize: 100,
            createdAt: nil,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            dateTaken: taken,
            pixelWidth: width,
            pixelHeight: height,
            videoCodec: codec
        )
    }
}
