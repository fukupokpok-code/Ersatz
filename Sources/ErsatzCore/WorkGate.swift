import Foundation

/// Limits concurrent work in two lanes. Foreground work (grid thumbnails) always wins:
/// background work (analysis) never starts while foreground work is waiting for a slot
/// and never takes a foreground slot. While thumbnails are running (but none waits),
/// analysis keeps going on half its slots, so a grid that is always loading a few
/// tiles no longer starves analysis for hours. Waiting foreground work starts newest
/// first, so the tiles the user just scrolled to load before ones already off screen.
public actor WorkGate {
    public enum Lane: Sendable { case foreground, background }

    public let foregroundLimit: Int
    public let backgroundLimit: Int
    private var activeForeground = 0
    private var activeBackground = 0
    private var foregroundWaiters: [Waiter] = []
    private var backgroundWaiters: [Waiter] = []
    private var nextWaiterID: UInt64 = 0

    private struct Waiter {
        var id: UInt64
        var continuation: CheckedContinuation<Void, Error>
        var cancellable: Bool
    }

    public init(foregroundLimit: Int, backgroundLimit: Int) {
        self.foregroundLimit = max(1, foregroundLimit)
        self.backgroundLimit = max(1, backgroundLimit)
    }

    public var snapshot: (foreground: Int, background: Int, waitingForeground: Int, waitingBackground: Int) {
        (activeForeground, activeBackground, foregroundWaiters.count, backgroundWaiters.count)
    }

    /// Waits for a slot. Not cancellable: the caller always gets the slot and must `leave`.
    public func enter(_ lane: Lane) async {
        try? await acquire(lane, cancellable: false)
    }

    /// Waits for a slot, or throws `CancellationError` as soon as the calling task is
    /// cancelled, without taking one. Analysis uses this so Stop doesn't wait behind
    /// thumbnails for a slot it would give straight back.
    public func enterCancellable(_ lane: Lane) async throws {
        try await acquire(lane, cancellable: true)
    }

    private func acquire(_ lane: Lane, cancellable: Bool) async throws {
        if cancellable { try Task.checkCancellation() }
        switch lane {
        case .foreground:
            if activeForeground < foregroundLimit {
                activeForeground += 1
                return
            }
        case .background:
            if backgroundMayStart {
                activeBackground += 1
                return
            }
        }
        nextWaiterID += 1
        let id = nextWaiterID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancellable && Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let waiter = Waiter(id: id, continuation: continuation, cancellable: cancellable)
                switch lane {
                case .foreground: foregroundWaiters.append(waiter)
                case .background: backgroundWaiters.append(waiter)
                }
            }
        } onCancel: {
            guard cancellable else { return }
            Task { await self.cancelWaiter(id, lane: lane) }
        }
    }

    private func cancelWaiter(_ id: UInt64, lane: Lane) {
        switch lane {
        case .foreground:
            guard let index = foregroundWaiters.firstIndex(where: { $0.id == id }) else { return }
            foregroundWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        case .background:
            guard let index = backgroundWaiters.firstIndex(where: { $0.id == id }) else { return }
            backgroundWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
        // A cancelled foreground waiter may have been what held background work back.
        wakeBackground()
    }

    public func leave(_ lane: Lane) {
        switch lane {
        case .foreground:
            if let next = foregroundWaiters.popLast() {
                next.continuation.resume()   // the slot passes straight on
            } else {
                activeForeground -= 1
            }
        case .background:
            activeBackground -= 1
        }
        wakeBackground()
    }

    public func run<T: Sendable>(_ lane: Lane, _ body: @Sendable () async throws -> T) async rethrows -> T {
        await enter(lane)
        defer { leave(lane) }
        return try await body()
    }

    /// `run`, but a cancelled caller stops waiting for its slot and throws.
    public func runCancellable<T: Sendable>(_ lane: Lane, _ body: @Sendable () async throws -> T) async throws -> T {
        try await enterCancellable(lane)
        defer { leave(lane) }
        return try await body()
    }

    private var backgroundMayStart: Bool {
        guard foregroundWaiters.isEmpty else { return false }
        let limit = activeForeground == 0 ? backgroundLimit : max(1, backgroundLimit / 2)
        return activeBackground < limit
    }

    private func wakeBackground() {
        while backgroundMayStart, !backgroundWaiters.isEmpty {
            activeBackground += 1
            backgroundWaiters.removeFirst().continuation.resume()
        }
    }
}
