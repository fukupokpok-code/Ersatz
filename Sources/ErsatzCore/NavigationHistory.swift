import Foundation

/// Finder-style back and forward history of places the user has visited.
public struct NavigationHistory<Location: Hashable & Sendable>: Sendable, Equatable {
    public private(set) var current: Location
    public private(set) var backStack: [Location] = []
    public private(set) var forwardStack: [Location] = []
    public let limit: Int

    public init(_ initial: Location, limit: Int = 100) {
        current = initial
        self.limit = max(1, limit)
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    /// Records a new place. Visiting the current place again does nothing,
    /// so a back or forward move that sets the location is not recorded twice.
    /// A new visit clears the forward stack, as in Finder and browsers.
    public mutating func visit(_ location: Location) {
        guard location != current else { return }
        backStack.append(current)
        if backStack.count > limit {
            backStack.removeFirst(backStack.count - limit)
        }
        forwardStack.removeAll()
        current = location
    }

    /// Changes the current place without adding a history entry,
    /// e.g. when the arrow keys move to another photo inside the viewer.
    public mutating func replaceCurrent(_ location: Location) {
        current = location
    }

    /// Moves one step back and returns the new current place, or nil at the start.
    @discardableResult
    public mutating func goBack() -> Location? {
        guard let previous = backStack.popLast() else { return nil }
        forwardStack.append(current)
        current = previous
        return previous
    }

    /// Moves one step forward and returns the new current place, or nil at the end.
    @discardableResult
    public mutating func goForward() -> Location? {
        guard let next = forwardStack.popLast() else { return nil }
        backStack.append(current)
        current = next
        return next
    }

    /// Drops places that no longer exist, such as a removed folder.
    /// If the current place is dropped, it becomes `replacement`.
    public mutating func removeAll(where shouldRemove: (Location) -> Bool, replacement: Location) {
        backStack.removeAll(where: shouldRemove)
        forwardStack.removeAll(where: shouldRemove)
        if shouldRemove(current) {
            current = replacement
        }
        backStack = Self.collapsed(backStack, before: current)
        forwardStack = Self.collapsed(forwardStack, before: current)
    }

    /// Removes neighbours that became equal after a removal, and an entry equal to `current` at the joining end.
    private static func collapsed(_ stack: [Location], before current: Location) -> [Location] {
        var result: [Location] = []
        for location in stack where result.last != location {
            result.append(location)
        }
        while result.last == current {
            result.removeLast()
        }
        return result
    }
}

/// A place in the app: a sidebar location, optionally with the viewer open on one item.
/// Opening the viewer is its own history entry, so Back closes it and Forward reopens it.
public struct BrowsePlace<Filter: Hashable & Sendable>: Hashable, Sendable {
    public var filter: Filter
    public var viewing: Int64?

    public init(_ filter: Filter, viewing: Int64? = nil) {
        self.filter = filter
        self.viewing = viewing
    }

    public var isViewer: Bool { viewing != nil }
    public var browser: BrowsePlace { BrowsePlace(filter) }
}

/// What a mouse side button, a swipe or Command-[ / Command-] asks for.
public enum NavigationDirection: Sendable, Equatable {
    case back
    case forward

    /// Maps an AppKit `otherMouseDown` button number. Buttons 3 and 4 are the side buttons.
    public init?(mouseButton: Int) {
        switch mouseButton {
        case 3: self = .back
        case 4: self = .forward
        default: return nil
        }
    }

    /// Maps the horizontal delta of an AppKit swipe event (positive means back, as in Safari).
    public init?(swipeDeltaX: Double) {
        if swipeDeltaX > 0 {
            self = .back
        } else if swipeDeltaX < 0 {
            self = .forward
        } else {
            return nil
        }
    }

    public var step: Int { self == .back ? -1 : 1 }
}
