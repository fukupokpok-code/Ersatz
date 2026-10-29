#if os(macOS)
import AppKit
import ErsatzCore
import SwiftUI

struct InfoPanel: View {
    @Environment(LibraryModel.self) private var model
    let item: MediaItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(item.filename)
                    .font(.headline)
                    .textSelection(.enabled)
                section("File") {
                    row("Kind", item.kind.label)
                    row("Format", item.formatName)
                    row("Size", ByteCountText.string(bytes: item.fileSize))
                    row("Path", item.path)
                }
                section("Capture") {
                    row("Taken", DisplayDate.dateTime(item.dateTaken))
                    if item.dateCorrected {
                        row("Calendar", "Corrected from Buddhist Era")
                    }
                    row("Camera", item.cameraModel)
                    row("Created", DisplayDate.dateTime(item.createdAt))
                    row("Modified", DisplayDate.dateTime(item.modifiedAt))
                }
                section("Media") {
                    row("Resolution", item.resolutionLabel)
                    row("Pixels", item.pixelCount.map { $0.formatted() })
                    row("Duration", item.durationLabel)
                    row("Video codec", item.videoCodec)
                    row("Audio codec", item.audioCodec)
                }
                Button("Show in Finder") { model.reveal(item) }
                    .buttonStyle(.bordered)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value?.isEmpty == false ? value! : "—")
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
