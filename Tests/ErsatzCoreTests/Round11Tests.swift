import XCTest
@testable import ErsatzCore

/// Round 11: a throwaway data directory for demo and screenshot runs.
final class Round11DevLaunchTests: XCTestCase {
    func testNormalLaunchHasNoOverride() {
        let options = DevLaunchOptions.parse(environment: [:], arguments: ["/Applications/Ersatz.app/Contents/MacOS/Ersatz"])
        XCTAssertEqual(options, DevLaunchOptions())
        XCTAssertNil(options.dataDirectory)
    }

    func testOtherOptionsAreIgnoredWithoutADataDirectory() {
        let options = DevLaunchOptions.parse(environment: [:], arguments: [
            "Ersatz", "-ErsatzAddFolder", "/tmp/demo", "-ErsatzStartFilter", "duplicates", "-ErsatzOpenViewer",
        ])
        XCTAssertEqual(options, DevLaunchOptions(), "dev options only apply to a throwaway catalog")
    }

    func testEnvironmentVariableSetsTheDataDirectory() {
        let options = DevLaunchOptions.parse(environment: ["ERSATZ_DATA_DIR": "/tmp/ErsatzDemoData"], arguments: ["Ersatz"])
        XCTAssertEqual(options.dataDirectory?.path, "/tmp/ErsatzDemoData")
        XCTAssertEqual(DevLaunchOptions.parse(environment: ["ERSATZ_DATA_DIR": ""], arguments: []), DevLaunchOptions())
    }

    func testLaunchArgumentsWinAndParseAllOptions() {
        let options = DevLaunchOptions.parse(environment: ["ERSATZ_DATA_DIR": "/tmp/env"], arguments: [
            "Ersatz",
            "-ErsatzDataDir", "/tmp/arg/../data",
            "-ErsatzAddFolder", "/tmp/ErsatzDemo",
            "-ErsatzAddFolder", "/tmp/More",
            "-ErsatzStartFilter", "Duplicates",
            "-ErsatzOpenViewer", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
        ])
        XCTAssertEqual(options.dataDirectory?.path, "/tmp/data")
        XCTAssertEqual(options.addFolders.map(\.path), ["/tmp/ErsatzDemo", "/tmp/More"])
        XCTAssertEqual(options.startFilter, "duplicates")
        XCTAssertTrue(options.openViewer)
    }

    func testBareViewerFlagAndExplicitNo() {
        let bare = DevLaunchOptions.parse(environment: [:], arguments: ["-ErsatzDataDir", "/tmp/d", "-ErsatzOpenViewer"])
        XCTAssertTrue(bare.openViewer)
        let no = DevLaunchOptions.parse(environment: [:], arguments: ["-ErsatzDataDir", "/tmp/d", "-ErsatzOpenViewer", "NO"])
        XCTAssertFalse(no.openViewer)
        let followed = DevLaunchOptions.parse(environment: [:], arguments: ["-ErsatzDataDir", "/tmp/d", "-ErsatzOpenViewer", "-ErsatzStartFilter", "blurry"])
        XCTAssertTrue(followed.openViewer)
        XCTAssertEqual(followed.startFilter, "blurry")
    }

    func testWindowSizeAndSnapshotOptions() {
        let options = DevLaunchOptions.parse(environment: [:], arguments: [
            "-ErsatzDataDir", "/tmp/d",
            "-ErsatzWindowSize", "1440x900",
            "-ErsatzSnapshot", "/tmp/shots/grid.png",
            "-ErsatzSnapshotDelay", "4.5",
        ])
        XCTAssertEqual(options.windowSize, DevLaunchOptions.WindowSize(width: 1440, height: 900))
        XCTAssertEqual(options.snapshotURL?.path, "/tmp/shots/grid.png")
        XCTAssertEqual(options.snapshotDelay, 4.5)

        let bad = DevLaunchOptions.parse(environment: [:], arguments: [
            "-ErsatzDataDir", "/tmp/d", "-ErsatzWindowSize", "10x10", "-ErsatzSnapshotDelay", "-3",
        ])
        XCTAssertNil(bad.windowSize)
        XCTAssertNil(bad.snapshotURL)
        XCTAssertEqual(bad.snapshotDelay, DevLaunchOptions.defaultSnapshotDelay)
        XCTAssertNil(DevLaunchOptions.WindowSize(parsing: "wide"))

        let ignored = DevLaunchOptions.parse(environment: [:], arguments: ["-ErsatzSnapshot", "/tmp/x.png"])
        XCTAssertNil(ignored.snapshotURL, "no snapshot without a throwaway data directory")
    }

    func testDataDirectoryPutsEverythingUnderOneFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ersatz-r11-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try AppPaths.databaseURL(root: root).path, root.appendingPathComponent("library.sqlite").path)
        XCTAssertEqual(try AppPaths.thumbnailCacheURL(root: root).path, root.appendingPathComponent("Caches/Thumbnails").path)
        XCTAssertEqual(try AppPaths.playbackCacheURL(root: root).path, root.appendingPathComponent("Caches/Playback").path)
        XCTAssertEqual(AppPaths.logsDirectory(root: root).path, root.appendingPathComponent("Logs").path)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Caches/Thumbnails").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testDefaultPathsStayInLibrary() {
        XCTAssertEqual(AppPaths.logsDirectory(root: nil, home: "/Users/someone").path, "/Users/someone/Library/Logs/Ersatz")
        XCTAssertNil(AppPaths.dataRoot, "the test runner is launched without a data directory")
    }
}
