#if os(macOS)
import CoreGraphics
import CoreImage
import ErsatzCore
import Foundation
import ImageIO
import os
import Vision

struct MacImageScoring: ImageScoring {
    /// Long side of the image QR detection and text recognition read. The 512-pixel
    /// thumbnail used before shrank a phone screenshot's text to about 4 pixels tall,
    /// too small to read, so no slip was ever recognized.
    static let readingPixelSize = 2048

    func signals(for url: URL, kind: MediaType, parts: AnalysisParts) async -> ImageSignals {
        await signals(for: url, kind: kind, parts: parts, context: ScoringContext())
    }

    func signals(for url: URL, kind: MediaType, parts: AnalysisParts, context: ScoringContext) async -> ImageSignals {
        guard kind == .photo || kind == .raw, !parts.isEmpty,
              let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return ImageSignals() }
        var signals = ImageSignals()
        // Stop checks sit between the slow steps (decode, QR, text). The analyzer drops
        // whatever a cancelled item returns, so returning early is safe.
        if Task.isCancelled { return signals }
        if parts.contains(.sharpness) || parts.contains(.perceptual), let small = thumbnail(imageSource, maxPixel: 512) {
            if parts.contains(.sharpness) {
                let size = BlurDetector.workingDimensions(width: small.width, height: small.height)
                if let gray = resizedGray(small, width: size.width, height: size.height) {
                    signals.sharpness = BlurDetector.sharpness(gray: gray, width: size.width, height: size.height)
                }
            }
            if parts.contains(.perceptual), let tiny = resizedGray(small, width: 9, height: 8) {
                signals.perceptualHash = PerceptualHash.dHash(gray: tiny, width: 9, height: 8)
            }
        }
        if Task.isCancelled { return signals }
        if parts.contains(.qr) || parts.contains(.bankSlip),
           let large = thumbnail(imageSource, maxPixel: Self.readingPixelSize) {
            if Task.isCancelled { return signals }
            do {
                signals.hasQR = try await detectQR(large)
            } catch {
                if Task.isCancelled { return signals }
                AppLog.analysis.error("QR detection failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            // Text recognition is by far the slowest step. Only the Bank Slips filter
            // needs it, and only where a slip is plausible.
            if parts.contains(.bankSlip),
               BankSlipClassifier.shouldReadText(hasQR: signals.hasQR, hasCameraModel: context.hasCameraModel) {
                if Task.isCancelled { return signals }
                do {
                    signals.recognizedText = try await recognizeText(large)
                } catch {
                    if Task.isCancelled { return signals }
                    AppLog.analysis.error("text recognition failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        return signals
    }

    private func thumbnail(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options: NSDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    private func resizedGray(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        let count = width * height
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { buffer.deallocate() }
        guard let context = CGContext(
            data: buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Array(UnsafeBufferPointer(start: buffer, count: count))
    }

    /// Runs one Vision request; cancelling the task cancels the request mid-way, so Stop
    /// doesn't wait for a full-size text recognition to finish on every worker.
    private func perform(_ request: VNRequest, on image: CGImage) async throws {
        let box = VisionRequestBox(request)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try VNImageRequestHandler(cgImage: image).perform([box.request])
            try Task.checkCancellation()
        } onCancel: {
            box.request.cancel()
        }
    }

    private func detectQR(_ image: CGImage) async throws -> Bool {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try await perform(request, on: image)
        return !(request.results ?? []).isEmpty
    }

    private func recognizeText(_ image: CGImage) async throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        // Asking for a language this macOS cannot read makes the whole request fail,
        // so only supported ones are requested.
        let supported = Set((try? request.supportedRecognitionLanguages()) ?? [])
        let wanted = ["th-TH", "en-US"].filter { supported.contains($0) }
        request.recognitionLanguages = wanted.isEmpty ? ["en-US"] : wanted
        try await perform(request, on: image)
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

/// Lets the cancellation handler reach the request. VNRequest.cancel() is safe to call
/// from another thread; that is what it is for.
private final class VisionRequestBox: @unchecked Sendable {
    let request: VNRequest
    init(_ request: VNRequest) { self.request = request }
}

enum MetadataWriter {
    struct Result {
        var success: Bool
        var written: String
    }

    static func writeDate(url: URL, date: Date) -> Result {
        let text = EXIFDateParser.format(date)
        if writeImageMetadata(url: url, exifDate: text) {
            return Result(success: true, written: text)
        }
        let sidecar = url.appendingPathExtension("xmp")
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description xmlns:exif="http://ns.adobe.com/exif/1.0/">
              <exif:DateTimeOriginal>\(text)</exif:DateTimeOriginal>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
        do {
            try xml.write(to: sidecar, atomically: true, encoding: .utf8)
            return Result(success: true, written: "sidecar \(sidecar.lastPathComponent)")
        } catch {
            return Result(success: false, written: error.localizedDescription)
        }
    }

    private static func writeImageMetadata(url: URL, exifDate: String) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) else { return false }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).ersatz-tmp")
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, type, 1, nil) else { return false }
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        var exif = (properties[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        exif[kCGImagePropertyExifDateTimeOriginal] = exifDate
        exif[kCGImagePropertyExifDateTimeDigitized] = exifDate
        properties[kCGImagePropertyExifDictionary] = exif
        var tiff = (properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
        tiff[kCGImagePropertyTIFFDateTime] = exifDate
        properties[kCGImagePropertyTIFFDictionary] = tiff
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
    }
}
#endif
