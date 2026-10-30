#if os(macOS)
import ErsatzCore
import SwiftUI

@main
struct ErsatzApp: App {
    @NSApplicationDelegateAdaptor(ErsatzAppDelegate.self) private var appDelegate

    private var model: LibraryModel { appDelegate.model }

    var body: some Scene {
        // One main window. A WindowGroup let macOS restore extra windows, and every
        // window then showed the same alerts and sheets, sometimes on an unseen screen.
        Window("Ersatz", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 880, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Folder…") {
                    model.pickFolders()
                }
                .disabled(model.showFolderPicker)
                .keyboardShortcut("o")
                Button("Remove Folder") {
                    model.askToRemoveFolder()
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(!model.canRemoveFolder)
            }
            CommandMenu("Library") {
                Button("Analyze Library") { model.analyzeLibrary() }
                    .disabled(!model.canAnalyzeLibrary)
                Button("Stop Analyzing") { model.cancelAnalysis() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(model.analysisStatus == nil)
                Divider()
                Button("Move to Trash…") {
                    if let item = model.currentItem { model.confirmTrash([item]) }
                }
                .disabled(model.currentItem == nil)
            }
            CommandMenu("Go") {
                Button("Back") { model.navigate(.back) }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!model.canGoBack)
                Button("Forward") { model.navigate(.forward) }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!model.canGoForward)
            }
            CommandGroup(after: .sidebar) {
                Button(model.showInfo ? "Hide Info" : "Show Info") {
                    model.showInfo.toggle()
                }
                .keyboardShortcut("i")
                Button("As Grid") { model.viewMode = .grid }
                    .keyboardShortcut("1")
                Button("As List") { model.viewMode = .list }
                    .keyboardShortcut("2")
                Divider()
                Button("Reindex") { model.reindexSelection() }
                    .keyboardShortcut("r")
                Divider()
                Button("Bigger Thumbnails") { model.adjustThumbnail(by: 16) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Smaller Thumbnails") { model.adjustThumbnail(by: -16) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("History") { model.openHistory() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Fix Buddhist-Era Dates…") { model.prepareBuddhistFix() }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
#else
import Foundation

@main
enum ErsatzMain {
    static func main() {
        let message = "Ersatz is a macOS application. On this platform, run `swift test` for ErsatzCore.\n"
        try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
        exit(EXIT_FAILURE)
    }
}
#endif
