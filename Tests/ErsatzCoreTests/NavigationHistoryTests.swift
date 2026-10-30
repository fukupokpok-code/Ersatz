import XCTest
@testable import ErsatzCore

final class NavigationHistoryTests: XCTestCase {
    func testBackAndForward() {
        var history = NavigationHistory("all")
        XCTAssertFalse(history.canGoBack)
        history.visit("a")
        history.visit("b")
        XCTAssertEqual(history.goBack(), "a")
        XCTAssertEqual(history.goBack(), "all")
        XCTAssertNil(history.goBack())
        XCTAssertEqual(history.current, "all")
        XCTAssertEqual(history.goForward(), "a")
        XCTAssertEqual(history.goForward(), "b")
        XCTAssertNil(history.goForward())
        XCTAssertEqual(history.current, "b")
    }

    func testRevisitingCurrentIsIgnoredSoBackDoesNotRecord() {
        var history = NavigationHistory("all")
        history.visit("a")
        let target = history.goBack()
        history.visit(target!)
        XCTAssertTrue(history.canGoForward)
        XCTAssertEqual(history.backStack, [])
    }

    func testNewVisitClearsForward() {
        var history = NavigationHistory("all")
        history.visit("a")
        history.visit("b")
        history.goBack()
        history.visit("c")
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.backStack, ["all", "a"])
    }

    func testLimit() {
        var history = NavigationHistory(0, limit: 3)
        for value in 1...10 { history.visit(value) }
        XCTAssertEqual(history.backStack, [7, 8, 9])
    }

    func testRemovingAPlace() {
        var history = NavigationHistory("all")
        history.visit("x")
        history.visit("a")
        history.visit("x")
        history.visit("b")
        history.removeAll(where: { $0 == "x" }, replacement: "all")
        XCTAssertEqual(history.backStack, ["all", "a"])
        XCTAssertEqual(history.current, "b")
        history.removeAll(where: { $0 == "b" }, replacement: "all")
        XCTAssertEqual(history.current, "all")
        XCTAssertEqual(history.backStack, ["all", "a"])
        XCTAssertEqual(history.goBack(), "a")
    }

    func testDirectionMapping() {
        XCTAssertEqual(NavigationDirection(mouseButton: 3), .back)
        XCTAssertEqual(NavigationDirection(mouseButton: 4), .forward)
        XCTAssertNil(NavigationDirection(mouseButton: 2))
        XCTAssertEqual(NavigationDirection(swipeDeltaX: 1), .back)
        XCTAssertEqual(NavigationDirection(swipeDeltaX: -1), .forward)
        XCTAssertNil(NavigationDirection(swipeDeltaX: 0))
        XCTAssertEqual(NavigationDirection.back.step, -1)
    }
}

final class BrowsePlaceHistoryTests: XCTestCase {
    typealias Place = BrowsePlace<String>

    func testBackClosesViewerAndForwardReopensSameItem() {
        var history = NavigationHistory(Place("all"))
        history.visit(Place("trip"))
        history.visit(Place("trip", viewing: 7))
        // Arrow keys move to item 9 inside the viewer: no new entry.
        history.replaceCurrent(Place("trip", viewing: 9))
        XCTAssertEqual(history.backStack, [Place("all"), Place("trip")])
        // Back = the viewer's Back button: returns to the grid of the same folder.
        XCTAssertEqual(history.goBack(), Place("trip"))
        XCTAssertFalse(history.current.isViewer)
        // Forward reopens the viewer on the item that was showing.
        XCTAssertEqual(history.goForward(), Place("trip", viewing: 9))
        // In the viewer there is nothing further forward.
        XCTAssertFalse(history.canGoForward)
        XCTAssertNil(history.goForward())
    }

    func testFolderBackAfterClosingViewer() {
        var history = NavigationHistory(Place("all"))
        history.visit(Place("trip"))
        history.visit(Place("trip", viewing: 1))
        history.goBack()
        XCTAssertEqual(history.goBack(), Place("all"))
        XCTAssertEqual(history.goForward(), Place("trip"))
        XCTAssertEqual(history.goForward(), Place("trip", viewing: 1))
    }

    func testNewFolderClearsViewerForwardEntry() {
        var history = NavigationHistory(Place("all"))
        history.visit(Place("all", viewing: 3))
        history.goBack()
        history.visit(Place("trip"))
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.backStack, [Place("all")])
        XCTAssertEqual(Place("trip", viewing: 4).browser, Place("trip"))
    }
}
