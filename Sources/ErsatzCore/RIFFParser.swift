import Foundation

enum RIFFParser {
    static func parse(prefix: Data, fileExtension: String) -> MediaMetadata? {
        guard prefix.count >= 12, Bytes.ascii(prefix, 0, 4) == "RIFF" else {
            if fileExtension == "webp" { return MediaMetadata(formatName: "WebP") }
            if fileExtension == "wav" { return MediaMetadata(audioCodec: "PCM", formatName: "WAV") }
            if fileExtension == "avi" { return MediaMetadata(formatName: "AVI") }
            return nil
        }
        let form = Bytes.ascii(prefix, 8, 4) ?? ""
        switch form {
        case "WAVE":
            return parseWAVE(prefix)
        case "WEBP":
            return parseWEBP(prefix)
        case "AVI ":
            return parseAVI(prefix)
        default:
            return nil
        }
    }

    private static func parseWAVE(_ data: Data) -> MediaMetadata {
        var metadata = MediaMetadata(audioCodec: "PCM", formatName: "WAV")
        var format: UInt16 = 1
        var byteRate: UInt32 = 0
        var dataSize: UInt32?
        walk(data) { id, size, body in
            if id == "fmt ", body + 16 <= data.count {
                format = Bytes.u16le(data, body) ?? 1
                byteRate = Bytes.u32le(data, body + 8) ?? 0
            } else if id == "data" {
                dataSize = size
            }
        }
        metadata.audioCodec = waveCodec(format)
        if let dataSize, byteRate > 0 {
            metadata.duration = Double(dataSize) / Double(byteRate)
        }
        return metadata
    }

    private static func waveCodec(_ format: UInt16) -> String {
        switch format {
        case 1, 0xFFFE:
            return "PCM"
        case 3:
            return "IEEE Float"
        case 85:
            return "MP3"
        case 0x00FF:
            return "AAC"
        default:
            return "WAV"
        }
    }

    private static func parseWEBP(_ data: Data) -> MediaMetadata {
        var metadata = MediaMetadata(formatName: "WebP")
        walk(data) { id, size, body in
            if id == "VP8X", size >= 10, body + 10 <= data.count {
                let width = Int(data[body + 4]) | (Int(data[body + 5]) << 8) | (Int(data[body + 6]) << 16)
                let height = Int(data[body + 7]) | (Int(data[body + 8]) << 8) | (Int(data[body + 9]) << 16)
                metadata.pixelWidth = width + 1
                metadata.pixelHeight = height + 1
            } else if id == "VP8 ", size >= 10, body + 10 <= data.count, Bytes.ascii(data, body + 3, 3) == "\u{9D}\u{01}\u{2A}" {
                if let width = Bytes.u16le(data, body + 6), let height = Bytes.u16le(data, body + 8) {
                    metadata.pixelWidth = Int(width & 0x3FFF)
                    metadata.pixelHeight = Int(height & 0x3FFF)
                }
            } else if id == "VP8L", size >= 5, body + 5 <= data.count, data[body] == 0x2F {
                let b1 = UInt32(data[body + 1])
                let b2 = UInt32(data[body + 2])
                let b3 = UInt32(data[body + 3])
                let b4 = UInt32(data[body + 4])
                let bits = b1 | (b2 << 8) | (b3 << 16) | (b4 << 24)
                metadata.pixelWidth = Int(bits & 0x3FFF) + 1
                metadata.pixelHeight = Int((bits >> 14) & 0x3FFF) + 1
            } else if id == "EXIF" {
                let end = min(data.count, body + Int(size))
                if end > body, let exif = TIFFParser.parse(data.subdata(in: body..<end), applyOrientation: false) {
                    metadata.fillMissing(from: exif)
                    metadata.formatName = "WebP"
                }
            }
        }
        metadata.applyOrientationSwap()
        return metadata
    }

    private static func parseAVI(_ data: Data) -> MediaMetadata {
        var metadata = MediaMetadata(formatName: "AVI")
        var microSeconds: UInt32?
        var frames: UInt32?
        walk(data) { id, size, body in
            if id == "avih", body + 40 <= data.count {
                microSeconds = Bytes.u32le(data, body)
                frames = Bytes.u32le(data, body + 16)
                if let width = Bytes.u32le(data, body + 32), let height = Bytes.u32le(data, body + 36), width > 0, height > 0 {
                    metadata.pixelWidth = Int(width)
                    metadata.pixelHeight = Int(height)
                }
            }
            if id == "strf", size >= 20, body + 20 <= data.count {
                let headerSize = Bytes.u32le(data, body) ?? 0
                if headerSize >= 16, let width = Bytes.u32le(data, body + 4) {
                    let heightBits = Bytes.u32le(data, body + 8) ?? 0
                    let height = Int(Int32(bitPattern: heightBits).magnitude)
                    if metadata.pixelWidth == nil, width > 0, height > 0 {
                        metadata.pixelWidth = Int(width)
                        metadata.pixelHeight = height
                    }
                    if body + 20 <= data.count, let four = Bytes.ascii(data, body + 16, 4), metadata.videoCodec == nil {
                        let printable = four.contains { $0.isLetter || $0.isNumber }
                        if printable {
                            metadata.videoCodec = CodecName.video(fourCC: four)
                        }
                    }
                } else if metadata.audioCodec == nil, body + 2 <= data.count, let format = Bytes.u16le(data, body) {
                    metadata.audioCodec = waveCodec(format)
                }
            }
        }
        if let microSeconds, let frames, microSeconds > 0, frames > 0 {
            metadata.duration = Double(microSeconds) * Double(frames) / 1_000_000
        }
        return metadata
    }

    private static func walk(_ data: Data, _ body: (String, UInt32, Int) -> Void) {
        var offset = 12
        var guardrail = 0
        while offset + 8 <= data.count, guardrail < 10_000 {
            guardrail += 1
            guard let id = Bytes.ascii(data, offset, 4), let size = Bytes.u32le(data, offset + 4) else { return }
            let chunkBody = offset + 8
            if id == "LIST", chunkBody + 4 <= data.count {
                let listEnd = min(data.count, chunkBody + Int(size))
                var inner = chunkBody + 4
                var innerGuard = 0
                while inner + 8 <= listEnd, innerGuard < 10_000 {
                    innerGuard += 1
                    guard let innerID = Bytes.ascii(data, inner, 4), let innerSize = Bytes.u32le(data, inner + 4) else { break }
                    body(innerID, innerSize, inner + 8)
                    let step = 8 + Int(innerSize) + (innerSize % 2 == 0 ? 0 : 1)
                    if step <= 0 { break }
                    inner += step
                }
            } else {
                body(id, size, chunkBody)
            }
            let step = 8 + Int(size) + (size % 2 == 0 ? 0 : 1)
            if step <= 0 { return }
            let next = offset + step
            if next <= offset { return }
            if next > data.count {
                // The size field is still meaningful for duration even when the body was truncated.
                return
            }
            offset = next
        }
    }
}
