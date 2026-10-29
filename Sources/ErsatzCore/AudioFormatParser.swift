import Foundation

enum AudioFormatParser {
    static func parseMP3(prefix: Data, fileSize: UInt64) -> MediaMetadata {
        var metadata = MediaMetadata(audioCodec: "MP3", formatName: "MP3")
        var offset = 0
        if prefix.count >= 10, Bytes.ascii(prefix, 0, 3) == "ID3" {
            let size = synchsafe(prefix, 6)
            offset = 10 + size
        }
        var index = offset
        while index + 4 < prefix.count {
            if prefix[index] == 0xFF, prefix[index + 1] & 0xE0 == 0xE0, let bitrate = bitrate(prefix, index) {
                let audioBytes = fileSize > UInt64(index) ? fileSize - UInt64(index) : fileSize
                metadata.duration = Double(audioBytes) * 8.0 / Double(bitrate)
                return metadata
            }
            index += 1
        }
        return metadata
    }

    static func parseFLAC(prefix: Data) -> MediaMetadata {
        var metadata = MediaMetadata(audioCodec: "FLAC", formatName: "FLAC")
        guard prefix.count >= 42, Bytes.ascii(prefix, 0, 4) == "fLaC" else { return metadata }
        let blockType = prefix[4] & 0x7F
        guard blockType == 0 else { return metadata }
        let start = 8
        guard prefix.count >= start + 18 else { return metadata }
        let sampleRate = (UInt32(prefix[start + 10]) << 12)
            | (UInt32(prefix[start + 11]) << 4)
            | (UInt32(prefix[start + 12]) >> 4)
        let samples = (UInt64(prefix[start + 13] & 0x0F) << 32)
            | (UInt64(prefix[start + 14]) << 24)
            | (UInt64(prefix[start + 15]) << 16)
            | (UInt64(prefix[start + 16]) << 8)
            | UInt64(prefix[start + 17])
        if sampleRate > 0, samples > 0 {
            metadata.duration = Double(samples) / Double(sampleRate)
        }
        return metadata
    }

    static func parseAIFF(prefix: Data) -> MediaMetadata {
        var metadata = MediaMetadata(audioCodec: "PCM", formatName: "AIFF")
        guard prefix.count >= 12, Bytes.ascii(prefix, 0, 4) == "FORM" else { return metadata }
        let form = Bytes.ascii(prefix, 8, 4) ?? ""
        if form == "AIFC" { metadata.formatName = "AIFC" }
        var offset = 12
        while offset + 8 <= prefix.count {
            guard let id = Bytes.ascii(prefix, offset, 4), let size = Bytes.u32be(prefix, offset + 4) else { break }
            let body = offset + 8
            if id == "COMM", body + 18 <= prefix.count {
                let frames = Bytes.u32be(prefix, body + 2) ?? 0
                let rate = decodeExtended80(prefix, body + 8)
                if let rate, rate > 0, frames > 0 {
                    metadata.duration = Double(frames) / rate
                }
                if form == "AIFC", body + 22 <= prefix.count, let compression = Bytes.ascii(prefix, body + 18, 4) {
                    metadata.audioCodec = CodecName.audio(fourCC: compression)
                }
            }
            let step = 8 + Int(size) + (size % 2 == 0 ? 0 : 1)
            if step <= 0 { break }
            offset += step
        }
        return metadata
    }

    private static func synchsafe(_ data: Data, _ offset: Int) -> Int {
        guard offset + 4 <= data.count else { return 0 }
        let b0 = Int(data[offset])
        let b1 = Int(data[offset + 1])
        let b2 = Int(data[offset + 2])
        let b3 = Int(data[offset + 3])
        return (b0 << 21) | (b1 << 14) | (b2 << 7) | b3
    }

    private static func bitrate(_ data: Data, _ offset: Int) -> Int? {
        let b1 = data[offset + 1]
        let b2 = data[offset + 2]
        let versionBits = (b1 >> 3) & 0x03
        let layerBits = (b1 >> 1) & 0x03
        let bitrateIndex = Int((b2 >> 4) & 0x0F)
        let sampleIndex = Int((b2 >> 2) & 0x03)
        guard versionBits != 0x01, layerBits != 0x00, bitrateIndex != 0, bitrateIndex != 0x0F, sampleIndex != 0x03 else {
            return nil
        }
        let mpeg1 = versionBits == 0x03
        let layer: Int
        switch layerBits {
        case 0x03: layer = 1
        case 0x02: layer = 2
        default: layer = 3
        }
        let table: [[Int]]
        if mpeg1 {
            table = [
                [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
                [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
                [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
            ]
        } else {
            table = [
                [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],
                [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
                [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
            ]
        }
        let kbps = table[layer - 1][bitrateIndex]
        return kbps * 1000
    }

    /// Decodes an 80-bit SANE / AIFF extended float.
    private static func decodeExtended80(_ data: Data, _ offset: Int) -> Double? {
        guard offset + 10 <= data.count else { return nil }
        let exponent = Int(Bytes.u16be(data, offset) ?? 0) & 0x7FFF
        var mantissa: UInt64 = 0
        for index in 0..<8 {
            mantissa = (mantissa << 8) | UInt64(data[offset + 2 + index])
        }
        if mantissa == 0 { return 0 }
        let value = Double(mantissa) * pow(2.0, Double(exponent - 16383 - 63))
        let sign = (data[offset] & 0x80) != 0
        return sign ? -value : value
    }
}
