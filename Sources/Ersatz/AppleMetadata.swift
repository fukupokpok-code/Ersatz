#if os(macOS)
import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import ErsatzCore

struct MacMetadataExtractor: MetadataExtracting {
    func extract(from url: URL, kind: MediaType) async -> MediaMetadata {
        var metadata = await PortableMetadataExtractor().extract(from: url, kind: kind)
        switch kind {
        case .raw:
            metadata.overlay(AppleMetadataReader.image(url: url))
            metadata.formatName = FormatNames.preferred(forExtension: url.pathExtension)
        case .photo:
            if metadata.pixelWidth == nil || metadata.dateTaken == nil || metadata.cameraModel == nil {
                metadata.fillMissing(from: AppleMetadataReader.image(url: url))
            }
        case .video:
            if metadata.duration == nil || metadata.videoCodec == nil || metadata.pixelWidth == nil {
                metadata.fillMissing(from: await AppleMetadataReader.audiovisual(url: url))
            }
        case .audio:
            if metadata.duration == nil || metadata.audioCodec == nil {
                metadata.fillMissing(from: await AppleMetadataReader.audiovisual(url: url))
            }
        }
        return metadata
    }
}

enum AppleMetadataReader {
    static func image(url: URL) -> MediaMetadata {
        var metadata = MediaMetadata()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return metadata }
        if let type = CGImageSourceGetType(source) {
            metadata.formatName = formatName(uti: type as String)
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return metadata
        }
        metadata.pixelWidth = intValue(properties[kCGImagePropertyPixelWidth])
        metadata.pixelHeight = intValue(properties[kCGImagePropertyPixelHeight])
        metadata.orientation = intValue(properties[kCGImagePropertyOrientation])
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        if let rawDate = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? exif?[kCGImagePropertyExifDateTimeDigitized] as? String
            ?? tiff?[kCGImagePropertyTIFFDateTime] as? String {
            if let interpreted = EXIFDateParser.interpret(rawDate) {
                metadata.dateTaken = interpreted.date
                metadata.dateCorrectedFromBuddhistEra = interpreted.correctedFromBuddhistEra
            }
        }
        metadata.cameraModel = CodecName.camera(
            make: tiff?[kCGImagePropertyTIFFMake] as? String,
            model: tiff?[kCGImagePropertyTIFFModel] as? String
        )
        if metadata.pixelWidth == nil {
            metadata.pixelWidth = intValue(exif?[kCGImagePropertyExifPixelXDimension])
            metadata.pixelHeight = intValue(exif?[kCGImagePropertyExifPixelYDimension])
        }
        metadata.applyOrientationSwap()
        return metadata
    }

    static func audiovisual(url: URL) async -> MediaMetadata {
        let asset = AVURLAsset(url: url)
        var metadata = MediaMetadata()
        if let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 {
            metadata.duration = duration.seconds
        }
        if let tracks = try? await asset.loadTracks(withMediaType: .video), let track = tracks.first {
            if let descriptions = try? await track.load(.formatDescriptions), let format = descriptions.first {
                let code = FourCC.string(CMFormatDescriptionGetMediaSubType(format))
                if !code.isEmpty {
                    metadata.videoCodec = CodecName.video(fourCC: code)
                }
            }
            if let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                let width = Int(abs(rect.width).rounded())
                let height = Int(abs(rect.height).rounded())
                if width > 0 { metadata.pixelWidth = width }
                if height > 0 { metadata.pixelHeight = height }
            }
        }
        if let tracks = try? await asset.loadTracks(withMediaType: .audio), let track = tracks.first,
           let descriptions = try? await track.load(.formatDescriptions), let format = descriptions.first {
            let code = FourCC.string(CMFormatDescriptionGetMediaSubType(format))
            if !code.isEmpty {
                metadata.audioCodec = CodecName.audio(fourCC: code)
            }
        }
        if let items = try? await asset.load(.commonMetadata) {
            var make: String?
            var model: String?
            for item in items {
                // `identifier` is available as soon as the item is. Only the payload
                // (string, date, number, data) is loaded asynchronously.
                switch item.identifier {
                case .commonIdentifierCreationDate where metadata.dateTaken == nil:
                    if let date = try? await item.load(.dateValue) {
                        metadata.dateTaken = date
                    } else if let string = try? await item.load(.stringValue) {
                        metadata.dateTaken = EXIFDateParser.parse(string) ?? ISO8601DateFormatter().date(from: string)
                    }
                case .commonIdentifierModel:
                    model = try? await item.load(.stringValue)
                case .commonIdentifierMake:
                    make = try? await item.load(.stringValue)
                default:
                    break
                }
            }
            if let camera = CodecName.camera(make: make, model: model) {
                metadata.cameraModel = camera
            }
        }
        return metadata
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as Int:
            return number
        case let number as NSNumber:
            return number.intValue
        case let number as Double:
            return Int(number)
        default:
            return nil
        }
    }

    private static func formatName(uti: String) -> String? {
        switch uti {
        case "public.jpeg": "JPEG"
        case "public.png": "PNG"
        case "com.compuserve.gif": "GIF"
        case "public.heic", "public.heif": "HEIC"
        case "public.avif": "AVIF"
        case "org.webmproject.webp": "WebP"
        case "public.tiff": "TIFF"
        case "com.adobe.raw-image": "DNG"
        default: nil
        }
    }
}

enum FourCC {
    static func string(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ].map { $0 >= 32 && $0 < 127 ? $0 : 32 }
        return String(bytes: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}
#endif
