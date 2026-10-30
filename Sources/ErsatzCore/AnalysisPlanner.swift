import Foundation

/// One analysis pass the app wants: which parts, over which library, and why.
public struct AnalysisDemand: Sendable, Equatable {
    public enum Origin: Sendable, Equatable {
        /// A smart filter on screen (Blurry, Duplicates, Screenshots, QR Codes, Bank Slips).
        case filter
        /// Library > Analyze Library.
        case library
    }

    public var parts: AnalysisParts
    public var scope: LibraryScope?
    public var origin: Origin

    public init(parts: AnalysisParts, scope: LibraryScope?, origin: Origin) {
        self.parts = parts.closed
        self.scope = scope
        self.origin = origin
    }

    public static func filter(_ parts: AnalysisParts, scope: LibraryScope?) -> AnalysisDemand {
        AnalysisDemand(parts: parts, scope: scope, origin: .filter)
    }

    public static let library = AnalysisDemand(parts: .all, scope: nil, origin: .library)

    /// What the analysis bar says while this pass runs. Analyze Library always says so,
    /// whatever filter is on screen; a smart filter's pass names what it looks for.
    public var title: String {
        if origin == .library || parts.isSuperset(of: .all) { return "Analyzing library" }
        if parts.contains(.bankSlip) { return "Reading bank slips" }
        if parts.isSuperset(of: .duplicates) { return "Finding duplicates" }
        if parts.contains(.sharpness) { return "Checking for blur" }
        if parts.contains(.qr) { return "Looking for QR codes" }
        if parts.contains(.screenshot) { return "Finding screenshots" }
        return "Analyzing"
    }

    /// True when running `self` also produces everything `other` needs.
    public func covers(_ other: AnalysisDemand) -> Bool {
        guard parts.isSuperset(of: other.parts) else { return false }
        guard let scope else { return true }
        return scope == other.scope
    }
}

/// Decides when analysis runs. The rules (Round 9):
/// - Only a smart filter on screen or Analyze Library asks for analysis. Browsing a
///   library, launching, or an index pass finishing never starts one by itself.
/// - Leaving the filter cancels its pass; nothing is queued to resume later.
/// - Stop cancels the pass and nothing restarts it until the user picks a smart filter
///   or Analyze Library again.
/// - While indexing runs, a wanted pass waits and starts when indexing ends, if it is
///   still wanted.
/// - Round 10: every start gets a new `run` number and `finished` must name it, so the
///   late completion of an earlier pass with the same parts and scope can't clear the
///   bookkeeping of the pass that replaced it (that left a QR pass running, with its bar,
///   after switching to Videos).
/// The app performs the returned `Action`; the planner only keeps the bookkeeping, so
/// these rules are unit tested without the UI.
public struct AnalysisPlanner: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case none
        case start(AnalysisDemand)
        case cancel
        case cancelAndStart(AnalysisDemand)
    }

    /// What the user currently asks for. Nil: nothing should run.
    public private(set) var wanted: AnalysisDemand?
    /// The pass the app is running.
    public private(set) var running: AnalysisDemand?
    /// The user pressed Stop; automatic re-requests (after indexing) are ignored until a
    /// new explicit request.
    public private(set) var stopped = false
    public private(set) var indexing = false
    /// Bumped every time a pass starts; identifies the pass in `finished`.
    public private(set) var run = 0
    public var isIndexing: Bool { indexing }

    public init() {}

    /// The analysis bar's label, or nil when no pass runs and the bar must be hidden.
    public var statusTitle: String? { running?.title }

    /// The sidebar selection changed. `parts` is what the new place needs (empty for a
    /// library, a date or a type).
    public mutating func select(parts: AnalysisParts, scope: LibraryScope?) -> Action {
        stopped = false
        if parts.isEmpty {
            if wanted?.origin == .filter { wanted = nil }
            return reconcile()
        }
        let demand = AnalysisDemand.filter(parts, scope: scope)
        // Analyze Library already produces this filter's results; let it run.
        if let wanted, wanted.origin == .library, wanted.covers(demand) { return reconcile() }
        wanted = demand
        return reconcile()
    }

    /// Library > Analyze Library.
    public mutating func analyzeLibrary() -> Action {
        stopped = false
        wanted = .library
        return reconcile()
    }

    /// The Stop button or Cmd-. Stop Analyzing.
    public mutating func stop() -> Action {
        wanted = nil
        stopped = true
        guard running != nil else { return .none }
        running = nil
        return .cancel
    }

    /// Indexing started or ended. When it ends, a smart filter still on screen catches up
    /// on new files, unless the user stopped it.
    public mutating func indexing(_ active: Bool, filterParts: AnalysisParts = [], scope: LibraryScope? = nil) -> Action {
        indexing = active
        if !active, wanted == nil, !stopped, !filterParts.isEmpty {
            wanted = .filter(filterParts, scope: scope)
        }
        return reconcile()
    }

    /// The running pass ended (finished, failed or cancelled). Stale passes, ones the
    /// planner already replaced, are ignored: by demand, and by `run` when given, which
    /// also catches a replacement that asks for exactly the same thing.
    public mutating func finished(_ demand: AnalysisDemand, run: Int? = nil) -> Action {
        guard running == demand else { return .none }
        if let run, run != self.run { return .none }
        running = nil
        if wanted == demand { wanted = nil }
        return reconcile()
    }

    /// The app is quitting or the database closed.
    public mutating func reset() -> Action {
        let hadRunning = running != nil
        let lastRun = run
        self = AnalysisPlanner()
        run = lastRun
        return hadRunning ? .cancel : .none
    }

    private mutating func reconcile() -> Action {
        if let current = running {
            if let wanted, current == wanted { return .none }
            if let wanted, !indexing {
                running = wanted
                run += 1
                return .cancelAndStart(wanted)
            }
            // Keep a pass that is still wanted running while indexing; drop one that isn't.
            if wanted == nil || current != wanted {
                running = nil
                return .cancel
            }
            return .none
        }
        guard let wanted, !indexing else { return .none }
        running = wanted
        run += 1
        return .start(wanted)
    }
}
