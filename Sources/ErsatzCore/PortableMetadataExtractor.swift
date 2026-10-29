import Foundation

public protocol MetadataExtracting: Sendable {
    func extract(from url: URL, kind: MediaType) async -> MediaMetadata
}

public struct PortableMetadataExtractor: MetadataExtracting {
    public init() {}

    public func extract(from url: URL, kind: MediaType) async -> MediaMetadata {
        extractSync(from: url, kind: kind)
    }

    func extractSync(from url: URL, kind: MediaType) -> MediaMetadata {
        let ext = url.pathExtension.lowercased()
        guard let file = try? RandomAccessFile(url: url) else {
            return MediaMetadata(formatName: FormatNames.preferred(forExtension: ext))
        }
        let magic = (try? file.read(at: 0, count: 16)) ?? Data()
        if shouldParseISO(magic: magic, ext: ext) {
            var metadata = ISOBMFFParser.parse(file: file)
            if kind == .raw {
                metadata.formatName = FormatNames.preferred(forExtension: ext)
            } else if metadata.formatName == nil {
                metadata.formatName = FormatNames.preferred(forExtension: ext)
            }
            return metadata
        }
        let prefixCount = Int(min(file.size, 4 * 1024 * 1024))
        let prefix = (try? file.read(at: 0, count: prefixCount)) ?? Data()
        var metadata = parsePrefix(prefix, ext: ext, kind: kind, fileSize: file.size)
        if kind == .raw {
            metadata.formatName = FormatNames.preferred(forExtension: ext)
        } else if metadata.formatName == nil {
            metadata.formatName = FormatNames.preferred(forExtension: ext)
        }
        return metadata
    }

    private func shouldParseISO(magic: Data, ext: String) -> Bool {
        if Bytes.ascii(magic, 4, 4) == "ftyp" { return true }
        if MediaTypeDetector.isoExtensions.contains(ext) {
            if Bytes.hasPrefix(magic, [0xFF, 0xD8]) { return false }
            if Bytes.ascii(magic, 0, 4) == "RIFF" { return false }
            return true
        }
        return false
    }

    private func parsePrefix(_ prefix: Data, ext: String, kind: MediaType, fileSize: UInt64) -> MediaMetadata {
        if Bytes.ascii(prefix, 0, 4) == "RIFF" {
            return RIFFParser.parse(prefix: prefix, fileExtension: ext) ?? MediaMetadata(formatName: FormatNames.preferred(forExtension: ext))
        }
        if Bytes.ascii(prefix, 0, 4) == "FORM" {
            return AudioFormatParser.parseAIFF(prefix: prefix)
        }
        if Bytes.ascii(prefix, 0, 4) == "fLaC" || ext == "flac" {
            return AudioFormatParser.parseFLAC(prefix: prefix)
        }
        if ext == "mp3" || Bytes.ascii(prefix, 0, 3) == "ID3" || (prefix.first == 0xFF && (prefix.dropFirst().first ?? 0) & 0xE0 == 0xE0 && kind == .audio) {
            return AudioFormatParser.parseMP3(prefix: prefix, fileSize: fileSize)
        }
        if let image = ImageContainerParser.parse(prefix: prefix, fileExtension: ext) {
            return image
        }
        if kind == .audio, ext == "wav" {
            return MediaMetadata(audioCodec: "PCM", formatName: "WAV")
        }
        return MediaMetadata(formatName: FormatNames.preferred(forExtension: ext))
    }
}
