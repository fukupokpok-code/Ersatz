#if os(macOS)
import AppKit
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
            let handled = MainActor.assumeIsolated { box.handler(code) }
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

private final class KeyBox: @unchecked Sendable {
    var handler: @MainActor (UInt16) -> Bool = { _ in false }
}
#endif
