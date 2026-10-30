#if os(macOS)
import AppKit
import ErsatzCore
import Foundation

@MainActor
final class KeyMonitor {
    private var token: Any?
    private let box = KeyBox()

    func install(handler: @escaping @MainActor (UInt16) -> Bool) {
        remove()
        box.handler = handler
        let box = box
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags
            if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
                return event
            }
            let responder = event.window?.firstResponder
            if responder is NSTextView || responder is NSSlider {
                return event
            }
            let code = event.keyCode
            let handled = MainActor.assumeIsolated { () -> Bool in
                // Leave keys alone while a sheet, alert, open panel or other modal is up,
                // so Return and Esc reach that dialog instead of the browser.
                if ModalGuard.isBlocked(event) { return false }
                return box.handler(code)
            }
            return handled ? nil : event
        }
    }

    func remove() {
        if let token {
            NSEvent.removeMonitor(token)
            self.token = nil
        }
    }
}

@MainActor
enum ModalGuard {
    /// True while a sheet, alert, open panel or other modal window should get the event.
    static func isBlocked(_ event: NSEvent) -> Bool {
        if NSApp.modalWindow != nil { return true }
        if let window = event.window {
            return window is NSPanel || window.sheetParent != nil || window.attachedSheet != nil
        }
        if let key = NSApp.keyWindow {
            return key.attachedSheet != nil || key is NSPanel
        }
        return false
    }
}

/// Mouse side buttons (3 = back, 4 = forward) and three-finger trackpad swipes.
@MainActor
final class MouseButtonMonitor {
    private var token: Any?
    private let box = NavigationBox()

    func install(handler: @escaping @MainActor (NavigationDirection) -> Bool) {
        remove()
        box.handler = handler
        let box = box
        token = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .swipe]) { event in
            let direction: NavigationDirection?
            switch event.type {
            case .otherMouseDown:
                direction = NavigationDirection(mouseButton: event.buttonNumber)
            case .swipe:
                // Horizontal swipes only; a vertical swipe has deltaX 0.
                direction = NavigationDirection(swipeDeltaX: Double(event.deltaX))
            default:
                direction = nil
            }
            guard let direction else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                if ModalGuard.isBlocked(event) { return false }
                return box.handler(direction)
            }
            return handled ? nil : event
        }
    }

    func remove() {
        if let token {
            NSEvent.removeMonitor(token)
            self.token = nil
        }
    }
}

private final class NavigationBox: @unchecked Sendable {
    var handler: @MainActor (NavigationDirection) -> Bool = { _ in false }
}

private final class KeyBox: @unchecked Sendable {
    var handler: @MainActor (UInt16) -> Bool = { _ in false }
}
#endif
