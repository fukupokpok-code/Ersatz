#if os(macOS)
import AppKit
import CoreImage
import Foundation
import ImageIO
import QuickLookThumbnailing
import ErsatzCore

enum ImageEncoding {
    static func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer,
            "public.jpeg" as CFString,
            1,
            nil
        ) else { return nil }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }
}

enum ThumbnailRenderer {
    static func imageIO(url: URL, maxPixel: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: NSDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return ImageEncoding.jpegData(from: image, quality: 0.74)
    }
}

@MainActor
enum QuickLookThumbnails {
    static func jpeg(url: URL, maxPixel: Int) async -> Data? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: maxPixel, height: maxPixel),
            scale: 1,
            representationTypes: .all
        )
        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            return ImageEncoding.jpegData(from: representation.cgImage, quality: 0.74)
        } catch {
            return nil
        }
    }
}

actor RAWRenderer {
    static let shared = RAWRenderer()
    private let context = CIContext(options: [.cacheIntermediates: false])

    func jpeg(url: URL, maxPixel: Int) -> Data? {
        let source: CIImage?
        if let filter = CIRAWFilter(imageURL: url), let output = filter.outputImage {
            source = output
        } else {
            source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        }
        guard var image = source else { return nil }
        let extent = image.extent
        guard extent.width > 1, extent.height > 1, extent.width.isFinite, extent.height.isFinite else { return nil }
        let longEdge = max(extent.width, extent.height)
        if longEdge > CGFloat(maxPixel) {
            let scale = CGFloat(maxPixel) / longEdge
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let rendered = context.createCGImage(image, from: image.extent.integral) else { return nil }
        return ImageEncoding.jpegData(from: rendered, quality: 0.9)
    }
}

actor ThumbnailWorker {
    private var inflight: [String: Task<Data?, Never>] = [:]
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let limit = 3

    func data(for item: MediaItem, token: String, maxPixel: Int, cache: ThumbnailCache) async -> Data? {
        let key = "\(item.id)-\(token)"
        if let existing = inflight[key] {
            return await existing.value
        }
        let task = Task<Data?, Never> {
            if let cached = cache.load(itemID: item.id, token: token), !cached.isEmpty {
                return cached
            }
            await self.enter()
            let rendered = await Self.render(item: item, maxPixel: maxPixel)
            self.leave()
            if let rendered {
                try? cache.store(rendered, itemID: item.id, token: token)
            }
            return rendered
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        return result
    }

    private func enter() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func leave() {
        if waiters.isEmpty {
            active -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    private static func render(item: MediaItem, maxPixel: Int) async -> Data? {
        let url = URL(fileURLWithPath: item.path)
        if item.kind == .video || item.kind == .audio {
            return await QuickLookThumbnails.jpeg(url: url, maxPixel: maxPixel)
        }
        let rendered = await Task.detached(priority: .utility) {
            ThumbnailRenderer.imageIO(url: url, maxPixel: maxPixel)
        }.value
        if let rendered { return rendered }
        if item.kind == .raw {
            if let raw = await RAWRenderer.shared.jpeg(url: url, maxPixel: min(maxPixel, 1024)) {
                return raw
            }
        }
        return await QuickLookThumbnails.jpeg(url: url, maxPixel: maxPixel)
    }
}

@MainActor
final class ThumbnailService {
    private let cache: ThumbnailCache
    private let worker = ThumbnailWorker()
    private let memory = NSCache<NSString, NSImage>()

    init(directory: URL) throws {
        cache = try ThumbnailCache(directory: directory)
        memory.countLimit = 240
    }

    func image(for item: MediaItem, side: CGFloat) async -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixels = max(64, Int((side * scale).rounded()))
        let bucket = max(64, (pixels / 32) * 32)
        let token = "\(Timestamp.milliseconds(item.modifiedAt))-\(bucket)"
        let key = "\(item.id)-\(token)" as NSString
        if let cached = memory.object(forKey: key) { return cached }
        guard let data = await worker.data(for: item, token: token, maxPixel: bucket, cache: cache) else {
            return nil
        }
        guard let image = NSImage(data: data) else { return nil }
        memory.setObject(image, forKey: key)
        return image
    }

    func viewerImage(for item: MediaItem, maxPixel: Int) async -> NSImage? {
        let url = URL(fileURLWithPath: item.path)
        if item.kind == .raw {
            if let data = await RAWRenderer.shared.jpeg(url: url, maxPixel: maxPixel),
               let image = NSImage(data: data) {
                return image
            }
        }
        if let data = await Task.detached(priority: .userInitiated, operation: {
            ThumbnailRenderer.imageIO(url: url, maxPixel: maxPixel)
        }).value, let image = NSImage(data: data) {
            return image
        }
        return NSImage(contentsOf: url)
    }
}
#endif
