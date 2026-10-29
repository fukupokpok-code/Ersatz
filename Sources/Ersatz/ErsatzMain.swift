#if os(macOS)
import SwiftUI

@main
struct ErsatzApp: App {
    @State private var model = LibraryModel()

    var body: some Scene {
        WindowGroup {
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
                .keyboardShortcut("o")
                Button("Remove Folder") {
                    model.askToRemoveFolder()
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(!model.canRemoveFolder)
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
                Button("History") { model.showHistory = true }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Fix Buddhist-Era Dates…") { model.prepareBuddhistFix() }
            }
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
