#if os(macOS)
import AppKit
import AVFoundation
import AVKit
import ErsatzCore
import SwiftUI

struct ViewerView: View {
    @Environment(LibraryModel.self) private var model
    let item: MediaItem
    @State private var image: NSImage?
    @State private var actualPixels = false
    @State private var loadFailed = false
    @State private var attempt = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Group {
                switch item.kind {
                case .video:
                    if case .ready(let url) = model.viewerPlayback {
                        VideoPlayerHost(url: url) {
                            model.fallBackToFFmpeg(item)
                        }
                    } else {
                        VideoStatus(playback: model.viewerPlayback, progress: model.playbackProgress) {
                            model.prepareViewerVideo(item)
                        } onCancel: {
                            model.cancelViewerPlayback()
                        }
                    }
                case .audio:
                    AudioPane(item: item)
                case .photo, .raw:
                    if let image {
                        PhotoCanvasView(image: image, actualPixels: actualPixels, menuItems: [
                            PhotoCanvasMenuItem(title: "Show in Finder") { model.reveal(item) },
                            PhotoCanvasMenuItem(title: "Move to Trash…") { model.confirmTrash([item]) }
                        ])
                    } else if loadFailed {
                        VStack(spacing: 12) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.system(size: 40))
                            Text("Ersatz could not open this image.")
                                .font(.headline)
                            Text(item.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .frame(maxWidth: 520)
                            HStack {
                                Button("Try Again") { attempt += 1 }
                                Button("Show in Finder") { model.reveal(item) }
                                Button("Back") { model.closeViewer() }
                            }
                        }
                        .foregroundStyle(.white)
                    } else {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                    }
                }
            }
            .contextMenu {
                Button("Show in Finder") { model.reveal(item) }
                Divider()
                Button("Move to Trash…", role: .destructive) { model.confirmTrash([item]) }
            }
            .padding(.top, 48)
            .padding(.bottom, 92)
            VStack {
                header
                Spacer()
                filmstrip
            }
            if model.showInfo {
                HStack {
                    Spacer()
                    InfoPanel(item: item)
                        .frame(width: 300)
                        .background(.black.opacity(0.88))
                }
            }
        }
        .task(id: "\(item.id)-\(actualPixels)-\(attempt)") {
            await loadStill()
        }
        .onChange(of: item.id) { _, _ in
            actualPixels = false
            model.prepareViewerVideo(item)
        }
        .onAppear { model.prepareViewerVideo(item) }
        .onDisappear { model.stopViewerPlayback() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button("Back", systemImage: "chevron.left") { model.closeViewer() }
                .keyboardShortcut(.escape, modifiers: [])
            Button(action: { model.moveSelection(by: -1) }) {
                Image(systemName: "chevron.left.circle")
            }
            .accessibilityLabel("Previous")
            Button(action: { model.moveSelection(by: 1) }) {
                Image(systemName: "chevron.right.circle")
            }
            .accessibilityLabel("Next")
            VStack(alignment: .leading, spacing: 1) {
                Text(item.filename)
                    .font(.headline)
                    .lineLimit(1)
                Text(model.viewerScopeLabel.map { "\($0)   \(subtitle)" } ?? subtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer()
            if item.kind == .photo || item.kind == .raw {
                Button(actualPixels ? "Fit" : "Actual Size") {
                    actualPixels.toggle()
                }
            }
            Button {
                model.confirmTrash([item])
            } label: {
                Image(systemName: "trash")
            }
            .help("Move to Trash…")
            .accessibilityLabel("Move to Trash")
            Button {
                model.showInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .foregroundStyle(.white)
        .buttonStyle(.borderless)
        .background(.black.opacity(0.35))
    }

    private var subtitle: String {
        var parts: [String] = []
        if let resolution = item.resolutionLabel { parts.append(resolution) }
        if let duration = item.durationLabel { parts.append(duration) }
        if let codec = item.displayCodec { parts.append(codec) }
        if let camera = item.cameraModel { parts.append(camera) }
        return parts.joined(separator: "   ")
    }

    private var filmstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(nearby) { neighbor in
                    FilmThumb(item: neighbor, selected: neighbor.id == item.id)
                        .onTapGesture { model.selectedID = neighbor.id }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.black.opacity(0.55))
    }

    /// Ten either side of the current item, within the duplicate set when the viewer
    /// was opened from Duplicates.
    private var nearby: [MediaItem] {
        let ids = ViewerSequence.window(model.viewerSequenceIDs, around: item.id, radius: 10)
        guard !ids.isEmpty else { return [item] }
        let byID = Dictionary(model.items.lazy.filter { ids.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    private func loadStill() async {
        guard item.kind == .photo || item.kind == .raw else {
            image = nil
            return
        }
        image = nil
        loadFailed = false
        let pixels = actualPixels ? 8192 : 3200
        let loaded = await model.viewerImage(for: item, maxPixel: pixels)
        guard !Task.isCancelled else { return }
        image = loaded
        loadFailed = loaded == nil
    }

}

private struct VideoStatus: View {
    let playback: ViewerPlayback
    let progress: PlaybackProgress?
    let retry: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            switch playback {
            case .idle, .checking, .ready:
                ProgressView("Opening…")
                    .controlSize(.large)
            case .working:
                working
            case .needsFFmpeg:
                installGuide
            case .failed(let message):
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.safelight)
            }
        }
        .foregroundStyle(.white)
        .tint(.white)
        .padding(24)
    }

    @ViewBuilder
    private var working: some View {
        let stage = progress?.stage ?? .probing
        VStack(spacing: 12) {
            switch stage {
            case .probing:
                ProgressView("Reading codecs…")
            case .remuxing:
                if let fraction = progress?.fraction {
                    ProgressView(value: fraction, total: 1.0) {
                        Text("Remuxing…")
                    }
                    .frame(width: 280)
                } else {
                    ProgressView("Remuxing…")
                }
            case .transcoding:
                if let fraction = progress?.fraction {
                    ProgressView(value: fraction, total: 1.0) {
                        Text("Transcoding…")
                    }
                    .frame(width: 280)
                } else {
                    ProgressView("Transcoding…")
                }
            }
            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
        }
    }

    private var installGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ffmpeg is not installed")
                .font(.headline)
            Text(FFmpegInstallGuide.summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(FFmpegInstallGuide.brewCommand)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            SettingsLink {
                Text("Open Settings")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.safelight)
        }
        .frame(maxWidth: 460)
    }
}

private struct VideoPlayerHost: View {
    let url: URL
    let onFailed: () -> Void
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoSurface(player: player)
            } else {
                ProgressView("Opening…")
                    .controlSize(.large)
                    .tint(.white)
            }
        }
        .task(id: url) {
            let asset = AVURLAsset(url: url)
            let item = AVPlayerItem(asset: asset)
            let next = AVPlayer(playerItem: item)
            player = next
            next.play()
            for _ in 0..<24 {
                if Task.isCancelled {
                    next.pause()
                    return
                }
                switch item.status {
                case .failed:
                    next.pause()
                    player = nil
                    onFailed()
                    return
                case .readyToPlay:
                    return
                case .unknown:
                    try? await Task.sleep(for: .milliseconds(125))
                @unknown default:
                    return
                }
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

private struct FilmThumb: View {
    @Environment(LibraryModel.self) private var model
    let item: MediaItem
    let selected: Bool
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.white.opacity(0.08)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: item.kind.symbolName)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(width: 64, height: 48)
        .clipped()
        .overlay {
            Rectangle().strokeBorder(selected ? Theme.safelight : Color.clear, lineWidth: 2)
        }
        .task(id: item.id) {
            image = await model.thumbnail(for: item, side: 64)
        }
    }
}

private struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}

private struct AudioPane: View {
    let item: MediaItem
    @State private var playback: AudioPlayback?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(.white.opacity(0.9))
            Text(item.filename)
                .font(.title3)
                .foregroundStyle(.white)
            Text(item.displayCodec ?? item.kind.label)
                .font(.caption.monospaced())
                .foregroundStyle(.white.opacity(0.65))
            if let playback {
                Slider(
                    value: Binding(
                        get: { min(playback.current, max(playback.duration, 0.1)) },
                        set: { playback.seek($0) }
                    ),
                    in: 0...max(playback.duration, 0.1)
                )
                HStack {
                    Button(playback.isPlaying ? "Pause" : "Play") {
                        playback.toggle()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.safelight)
                    Spacer()
                    Text("\(Self.clock(playback.current)) / \(Self.clock(playback.duration))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .padding(32)
        .frame(maxWidth: 480)
        .onAppear {
            let playback = AudioPlayback(url: URL(fileURLWithPath: item.path))
            self.playback = playback
            playback.start()
        }
        .onDisappear { playback?.stop() }
    }

    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

@MainActor
@Observable
final class AudioPlayback {
    var isPlaying = false
    var current = 0.0
    var duration = 0.0
    private let player: AVPlayer
    private var token: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
    }

    func start() {
        token = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated {
                self?.current = seconds.isFinite ? seconds : 0
            }
        }
        let asset = player.currentItem?.asset
        Task { @MainActor in
            if let asset, let loaded = try? await asset.load(.duration), loaded.isNumeric {
                duration = loaded.seconds
            }
        }
        player.play()
        isPlaying = true
    }

    func toggle() {
        if player.rate == 0 {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    func seek(_ seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time)
        current = seconds
    }

    func stop() {
        player.pause()
        if let token {
            player.removeTimeObserver(token)
            self.token = nil
        }
        isPlaying = false
    }
}

struct PhotoCanvasMenuItem {
    let title: String
    let action: () -> Void
}

struct PhotoCanvasView: NSViewRepresentable {
    let image: NSImage?
    var actualPixels: Bool
    var menuItems: [PhotoCanvasMenuItem] = []

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PhotoCanvas {
        let view = PhotoCanvas()
        view.image = image
        view.menuItems = menuItems
        return view
    }

    func updateNSView(_ view: PhotoCanvas, context: Context) {
        let imageChanged = view.image !== image
        view.image = image
        view.menuItems = menuItems
        if imageChanged || context.coordinator.actualPixels != actualPixels {
            context.coordinator.actualPixels = actualPixels
            if actualPixels {
                view.zoomToPixels()
            } else {
                view.fit()
            }
        }
    }

    final class Coordinator {
        var actualPixels = false
    }
}

final class PhotoCanvas: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }
    private var magnification: CGFloat = 1
    private var offset: CGSize = .zero
    private var dragOrigin: CGPoint?
    private var offsetOrigin: CGSize = .zero

    var menuItems: [PhotoCanvasMenuItem] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Right-click on the photo. SwiftUI's context menu does not reach an AppKit view.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard !menuItems.isEmpty else { return nil }
        let menu = NSMenu()
        for (index, entry) in menuItems.enumerated() {
            let item = NSMenuItem(title: entry.title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        return menu
    }

    @objc private func runMenuItem(_ sender: NSMenuItem) {
        guard menuItems.indices.contains(sender.tag) else { return }
        menuItems[sender.tag].action()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func fit() {
        magnification = 1
        offset = .zero
        needsDisplay = true
    }

    func zoomToPixels() {
        guard let image, image.size.width > 0 else { return }
        let fit = fittedSize(image.size)
        let pixels = image.pixelWidth
        let screen = window?.backingScaleFactor ?? 2
        if fit.width > 0, pixels > 0 {
            magnification = (CGFloat(pixels) / screen) / fit.width
        }
        offset = .zero
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.intersection(bounds).fill()
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let fit = fittedSize(image.size)
        let drawSize = CGSize(width: fit.width * magnification, height: fit.height * magnification)
        let rect = CGRect(
            x: (bounds.width - drawSize.width) / 2 + offset.width,
            y: (bounds.height - drawSize.height) / 2 + offset.height,
            width: drawSize.width,
            height: drawSize.height
        )
        image.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            if abs(magnification - 1) < 0.08 {
                zoomToPixels()
            } else {
                fit()
            }
            return
        }
        dragOrigin = convert(event.locationInWindow, from: nil)
        offsetOrigin = offset
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        offset = CGSize(
            width: offsetOrigin.width + point.x - dragOrigin.x,
            height: offsetOrigin.height + point.y - dragOrigin.y
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || !event.hasPreciseScrollingDeltas {
            let zoom = exp(event.deltaY * 0.08)
            magnification = min(16, max(0.2, magnification * zoom))
        } else {
            offset.width += event.scrollingDeltaX
            offset.height += event.scrollingDeltaY
        }
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        magnification = min(16, max(0.2, magnification * (1 + event.magnification)))
        needsDisplay = true
    }

    private func fittedSize(_ imageSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return imageSize
        }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}

private extension NSImage {
    var pixelWidth: Int {
        representations.first?.pixelsWide ?? Int(size.width)
    }
}
#endif
