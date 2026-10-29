#if os(macOS)
import CoreGraphics
import CoreImage
import ErsatzCore
import Foundation
import ImageIO
import Vision

struct MacImageScoring: ImageScoring {
    func signals(for url: URL, kind: MediaType) async -> ImageSignals {
        guard kind == .photo || kind == .raw, let source = cgImage(url) else { return ImageSignals() }
        var signals = ImageSignals()
        if let gray = resizedGray(source, width: 64, height: 64) {
            signals.sharpness = SharpnessScore.laplacianVariance(gray: gray, width: 64, height: 64)
        }
        if let tiny = resizedGray(source, width: 9, height: 8) {
            signals.perceptualHash = PerceptualHash.dHash(gray: tiny, width: 9, height: 8)
        }
        signals.hasQR = (try? detectQR(source)) ?? false
        signals.recognizedText = (try? recognizeText(source)) ?? ""
        return signals
    }

    private func cgImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: NSDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
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

    private func detectQR(_ image: CGImage) throws -> Bool {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        return !(request.results ?? []).isEmpty
    }

    private func recognizeText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["th-TH", "en-US"]
        request.recognitionLevel = .accurate
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
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
