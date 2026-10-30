#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import XCTest
@testable import ErsatzCore

final class WindowPlacementTests: XCTestCase {
    let main = CGRect(x: 0, y: 0, width: 1512, height: 944)
    let above = CGRect(x: 0, y: 982, width: 2560, height: 1415)

    func testWindowOnMainScreenIsVisible() {
        let frame = CGRect(x: 100, y: 100, width: 1280, height: 820)
        XCTAssertFalse(WindowPlacement.isOffScreen(window: frame, screens: [main]))
    }

    func testWindowOnScreenThatWasUnpluggedIsOffScreen() {
        let frame = CGRect(x: 300, y: 1200, width: 1280, height: 820)
        XCTAssertTrue(WindowPlacement.isOffScreen(window: frame, screens: [main]))
        XCTAssertFalse(WindowPlacement.isOffScreen(window: frame, screens: [main, above]))
    }

    func testTitleBarAboveTopEdgeIsOffScreen() {
        let frame = CGRect(x: 100, y: 500, width: 800, height: 600)
        XCTAssertTrue(WindowPlacement.isOffScreen(window: frame, screens: [main]))
    }

    func testNoScreensMeansLeaveAlone() {
        XCTAssertFalse(WindowPlacement.isOffScreen(window: .zero, screens: []))
    }

    func testCenteredFitsInsideScreen() {
        let big = CGRect(x: 4000, y: 4000, width: 3000, height: 2000)
        let placed = WindowPlacement.centered(big, on: main)
        XCTAssertEqual(placed.width, main.width)
        XCTAssertEqual(placed.height, main.height)
        XCTAssertTrue(main.contains(placed))
        let small = WindowPlacement.centered(CGRect(x: 9000, y: 9000, width: 800, height: 600), on: main)
        XCTAssertEqual(small.midX, main.midX, accuracy: 1)
        XCTAssertEqual(small.midY, main.midY, accuracy: 1)
        XCTAssertFalse(WindowPlacement.isOffScreen(window: small, screens: [main]))
    }
}
