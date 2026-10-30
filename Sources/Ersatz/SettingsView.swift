#if os(macOS)
import ErsatzCore
import SwiftUI

struct SettingsView: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("ffmpeg") {
                TextField("Custom path", text: $model.ffmpegPath, prompt: Text("/opt/homebrew/bin/ffmpeg"))
                Text("Leave this blank to search /opt/homebrew/bin, then /usr/local/bin, then PATH. Ersatz never bundles or links ffmpeg.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Install with \(FFmpegInstallGuide.brewCommand), then reindex so MKV, WebM, AVI, FLV, and WMV pick up resolution, codec, and duration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Section("Playback cache") {
                Stepper(value: $model.playbackCacheGigabytes, in: 1.0...100.0, step: 1.0) {
                    Text("\(Int(model.playbackCacheGigabytes.rounded())) GB")
                }
                Text("Remuxed and transcoded videos live in ~/Library/Caches/Ersatz/Playback. The oldest files are removed when the folder passes this size. Originals are never modified.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 520)
        .onChange(of: model.ffmpegPath) { _, _ in
            model.persistPlaybackSettings()
        }
        .onChange(of: model.playbackCacheGigabytes) { _, _ in
            model.persistPlaybackSettings()
            model.trimPlaybackCache()
        }
    }
}
#endif
