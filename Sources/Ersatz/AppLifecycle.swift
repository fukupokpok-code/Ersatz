#if os(macOS)
import AppKit
import ErsatzCore
import Foundation
import os
import SwiftUI

/// Unified logging. Read with:
/// `log stream --predicate 'subsystem == "com.mongkol.ersatz"' --level info`
enum AppLog {
    static let subsystem = "com.mongkol.ersatz"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let viewer = Logger(subsystem: subsystem, category: "viewer")
    static let library = Logger(subsystem: subsystem, category: "library")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let playback = Logger(subsystem: subsystem, category: "playback")
    static let analysis = Logger(subsystem: subsystem, category: "analysis")
}

@MainActor
final class ErsatzAppDelegate: NSObject, NSApplicationDelegate {
    let model = LibraryModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.app.info("launch: pid \(ProcessInfo.processInfo.processIdentifier, privacy: .public)")
        // Create ~/Library/Logs/Ersatz/activity.log now, not on the first edit.
        if let url = ActivityLog.shared?.fileURL {
            AppLog.app.info("activity log at \(url.path, privacy: .public)")
        } else {
            AppLog.app.error("activity log could not be created")
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                WindowKeeper.rescueAllWindows()
            }
        }
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                WindowKeeper.rescueAllWindows()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppLog.app.info("quit requested")
        model.prepareForQuit()
        let stopped = FFmpegProcessRegistry.shared.terminateAll()
        AppLog.app.info("quit: stopped \(stopped, privacy: .public) ffmpeg processes")
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.app.info("terminating")
    }
}

/// Keeps the main window on a visible screen and gives AppKit code a window to attach to.
@MainActor
enum WindowKeeper {
    static func rescueAllWindows() {
        for window in NSApp.windows where window.isVisible && !(window is NSPanel) && window.sheetParent == nil {
            rescue(window)
        }
    }

    static func rescue(_ window: NSWindow) {
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard WindowPlacement.isOffScreen(window: window.frame, screens: screens) else { return }
        let target = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
        guard let target else { return }
        let placed = WindowPlacement.centered(window.frame, on: target)
        AppLog.ui.notice("window was off screen at \(NSStringFromRect(window.frame), privacy: .public); moved to \(NSStringFromRect(placed), privacy: .public)")
        window.setFrame(placed, display: true)
    }

    /// Puts the main window on a visible screen and in front, so the sheet or alert
    /// about to attach to it can be seen.
    static func bringForward(_ window: NSWindow?) {
        let target = window ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.sheetParent == nil }
        guard let target else { return }
        if target.isMiniaturized { target.deminiaturize(nil) }
        rescue(target)
        target.makeKeyAndOrderFront(nil)
    }
}

/// Reports the hosting NSWindow of a SwiftUI view.
struct WindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onWindow = onWindow
    }

    final class ReaderView: NSView {
        var onWindow: (@MainActor (NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            onWindow?(window)
        }
    }
}
#endif
