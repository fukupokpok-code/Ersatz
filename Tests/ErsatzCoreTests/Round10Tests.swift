import XCTest
@testable import ErsatzCore

/// Round 10: a plain place (Videos, Photos, a year, a library) never keeps a smart filter's
/// pass or its "Looking for QR codes" bar.
final class Round10PlannerTests: XCTestCase {
    private let clips = LibraryScope(folderID: 3)

    func testEmptyPartsPlaceCancelsTheQRPassAndClearsTheLabel() {
        var planner = AnalysisPlanner()
        XCTAssertEqual(planner.select(parts: .qr, scope: clips), .start(.filter(.qr, scope: clips)))
        XCTAssertEqual(planner.statusTitle, "Looking for QR codes")
        // Type > Videos: analysisParts is empty.
        XCTAssertEqual(planner.select(parts: [], scope: clips), .cancel)
        XCTAssertNil(planner.running)
        XCTAssertNil(planner.wanted)
        XCTAssertNil(planner.statusTitle)
    }

    /// The Round 9 bug: a QR pass ended, and while its completion was still refreshing the
    /// sidebar, the user left and came back to QR Codes, starting an identical pass. The
    /// late completion then cleared the new pass's bookkeeping, so picking Videos found
    /// "nothing running" and left the pass and its bar alive.
    func testLateFinishOfAnEarlierIdenticalPassIsIgnored() {
        var planner = AnalysisPlanner()
        let qr = AnalysisDemand.filter(.qr, scope: clips)
        XCTAssertEqual(planner.select(parts: .qr, scope: clips), .start(qr))
        let first = planner.run
        XCTAssertEqual(planner.select(parts: [], scope: clips), .cancel)
        XCTAssertEqual(planner.select(parts: .qr, scope: clips), .start(qr))
        let second = planner.run
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(planner.finished(qr, run: first), .none)
        XCTAssertEqual(planner.running, qr, "the stale completion must not forget the live pass")
        XCTAssertEqual(planner.statusTitle, "Looking for QR codes")
        XCTAssertEqual(planner.select(parts: [], scope: clips), .cancel)
        XCTAssertNil(planner.statusTitle)
    }

    func testTheLivePassStillFinishesNormally() {
        var planner = AnalysisPlanner()
        let qr = AnalysisDemand.filter(.qr, scope: clips)
        _ = planner.select(parts: .qr, scope: clips)
        XCTAssertEqual(planner.finished(qr, run: planner.run), .none)
        XCTAssertNil(planner.running)
        XCTAssertNil(planner.statusTitle)
        // Videos afterwards has nothing to cancel.
        XCTAssertEqual(planner.select(parts: [], scope: clips), .none)
    }

    func testEveryPlainPlaceAfterEverySmartFilterCancels() {
        let smart: [AnalysisParts] = [.screenshot, .qr, [.qr, .bankSlip], .sharpness, .duplicates]
        for parts in smart {
            for scope in [nil, clips] {
                var planner = AnalysisPlanner()
                XCTAssertEqual(planner.select(parts: parts, scope: scope), .start(.filter(parts, scope: scope)))
                XCTAssertEqual(planner.select(parts: [], scope: scope), .cancel, "parts \(parts.rawValue)")
                XCTAssertNil(planner.statusTitle)
                // Indexing ending while on the plain place starts nothing.
                XCTAssertEqual(planner.indexing(true), .none)
                XCTAssertEqual(planner.indexing(false, filterParts: [], scope: scope), .none)
                XCTAssertNil(planner.running)
            }
        }
    }

    func testCancelledWhileIndexingToo() {
        var planner = AnalysisPlanner()
        _ = planner.select(parts: .qr, scope: clips)
        XCTAssertEqual(planner.indexing(true), .none)
        XCTAssertEqual(planner.select(parts: [], scope: clips), .cancel)
        XCTAssertEqual(planner.indexing(false, filterParts: [], scope: clips), .none)
        XCTAssertNil(planner.statusTitle)
    }

    func testAnalyzeLibraryKeepsRunningOnVideosAndSaysSo() {
        var planner = AnalysisPlanner()
        XCTAssertEqual(planner.analyzeLibrary(), .start(.library))
        XCTAssertEqual(planner.select(parts: [], scope: clips), .none)
        XCTAssertEqual(planner.running, .library)
        XCTAssertEqual(planner.statusTitle, "Analyzing library")
        // Even a library-origin demand with fewer parts never borrows a filter's label.
        XCTAssertEqual(AnalysisDemand(parts: .qr, scope: nil, origin: .library).title, "Analyzing library")
        XCTAssertEqual(planner.stop(), .cancel)
        XCTAssertNil(planner.statusTitle)
    }

    func testFilterTitles() {
        XCTAssertEqual(AnalysisDemand.filter(.qr, scope: nil).title, "Looking for QR codes")
        XCTAssertEqual(AnalysisDemand.filter([.qr, .bankSlip], scope: nil).title, "Reading bank slips")
        XCTAssertEqual(AnalysisDemand.filter(.bankSlip, scope: nil).title, "Reading bank slips")
        XCTAssertEqual(AnalysisDemand.filter(.sharpness, scope: nil).title, "Checking for blur")
        XCTAssertEqual(AnalysisDemand.filter(.duplicates, scope: nil).title, "Finding duplicates")
        XCTAssertEqual(AnalysisDemand.filter(.screenshot, scope: nil).title, "Finding screenshots")
    }

    func testRunNumbersKeepGrowingAcrossReset() {
        var planner = AnalysisPlanner()
        _ = planner.select(parts: .qr, scope: clips)
        let before = planner.run
        XCTAssertEqual(planner.reset(), .cancel)
        _ = planner.select(parts: .qr, scope: clips)
        XCTAssertGreaterThan(planner.run, before)
        XCTAssertEqual(planner.finished(.filter(.qr, scope: clips), run: before), .none)
        XCTAssertNotNil(planner.running)
    }
}
