#if os(macOS)
import AppKit
import ErsatzCore
import SwiftUI

struct HistoryView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var checkpoints: [Checkpoint] = []
    @State private var files: [CheckpointFile] = []
    @State private var selectedID: Int64?
    @State private var entries: [ActivityEntry] = []
    @State private var search = ""

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("History")
                    .font(.title2)
                Spacer()
                Button("Reveal Log in Finder") { revealLog() }
                Button("Close") { dismiss() }
            }
            HStack {
                Stepper("Keep \(Int(model.checkpointDays)) days", value: $model.checkpointDays, in: 1...365)
                Stepper(String(format: "Max %.1f GB", model.checkpointMaxGigabytes), value: $model.checkpointMaxGigabytes, in: 0.5...50, step: 0.5)
                Button("Prune Now") { Task { await model.pruneCheckpoints(); await reload() } }
            }
            .font(.callout)
            HStack(alignment: .top, spacing: 16) {
                List(checkpoints, selection: $selectedID) { checkpoint in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(checkpoint.action)
                        Text("\(checkpoint.fileCount) files · \(checkpoint.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(checkpoint.id)
                }
                .frame(minWidth: 240)
                VStack(alignment: .leading) {
                    if let selected = checkpoints.first(where: { $0.id == selectedID }) {
                        Button("Restore Checkpoint") {
                            Task { await model.restore(checkpoint: selected); await reload() }
                        }
                        List(files) { file in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(URL(fileURLWithPath: file.path).lastPathComponent)
                                    Text(file.kind.rawValue)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Restore") {
                                    Task { await model.restore(file: file, checkpoint: selected) }
                                }
                            }
                        }
                    } else {
                        ContentUnavailableView("No checkpoint selected", systemImage: "clock.arrow.circlepath")
                    }
                }
            }
            .frame(minHeight: 220)
            TextField("Search the log", text: $search)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await reload() } }
            List(entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.action) · \(entry.success ? "ok" : "failed") · \(entry.restorable ? "restorable" : "not restorable")")
                        .font(.caption.weight(.semibold))
                    Text(entry.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(entry.oldValue ?? "—") → \(entry.newValue ?? "—")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .task { await reload() }
        .onChange(of: selectedID) { _, _ in
            Task { await loadFiles() }
        }
    }

    private func reload() async {
        checkpoints = (try? await model.database?.checkpoints()) ?? []
        let query = search.trimmingCharacters(in: .whitespaces)
        entries = (try? await model.database?.activity(matching: query.isEmpty ? nil : query)) ?? []
        await loadFiles()
    }

    private func loadFiles() async {
        guard let selected = checkpoints.first(where: { $0.id == selectedID }) else {
            files = []
            return
        }
        files = (try? await model.database?.checkpointFiles(checkpointID: selected.id)) ?? []
    }

    private func revealLog() {
        guard let url = ActivityLog.shared?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
#endif
