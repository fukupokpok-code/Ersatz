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
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Group {
                switch item.kind {
                case .video:
                    if let player {
                        VideoSurface(player: player)
                    }
                case .audio:
                    AudioPane(item: item)
                case .photo, .raw:
                    if let image {
                        PhotoCanvasView(image: image, actualPixels: actualPixels)
                    } else {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                    }
                }
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
        .task(id: "\(item.id)-\(actualPixels)") {
            await loadStill()
        }
        .onChange(of: item.id) { _, _ in
            actualPixels = false
            configurePlayback()
        }
        .onAppear { configurePlayback() }
        .onDisappear {
            player?.pause()
            player = nil
        }
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
                Text(subtitle)
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

    private var nearby: [MediaItem] {
        guard let index = model.items.firstIndex(where: { $0.id == item.id }) else { return [item] }
        let lower = max(0, index - 10)
        let upper = min(model.items.count, index + 11)
        return Array(model.items[lower..<upper])
    }

    private func loadStill() async {
        guard item.kind == .photo || item.kind == .raw else {
            image = nil
            return
        }
        image = nil
        let pixels = actualPixels ? 8192 : 3200
        let loaded = await model.viewerImage(for: item, maxPixel: pixels)
        if !Task.isCancelled { image = loaded }
    }

    private func configurePlayback() {
        player?.pause()
        player = nil
        guard item.kind == .video else { return }
        let next = AVPlayer(url: URL(fileURLWithPath: item.path))
        player = next
        next.play()
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

struct PhotoCanvasView: NSViewRepresentable {
    let image: NSImage?
    var actualPixels: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PhotoCanvas {
        let view = PhotoCanvas()
        view.image = image
        return view
    }

    func updateNSView(_ view: PhotoCanvas, context: Context) {
        let imageChanged = view.image !== image
        view.image = image
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

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

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
