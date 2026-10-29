import Foundation

enum ImageContainerParser {
    static func parse(prefix: Data, fileExtension: String) -> MediaMetadata? {
        if Bytes.hasPrefix(prefix, [0xFF, 0xD8]) {
            return parseJPEG(prefix)
        }
        if Bytes.hasPrefix(prefix, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return parsePNG(prefix)
        }
        if Bytes.ascii(prefix, 0, 3) == "GIF" {
            return parseGIF(prefix)
        }
        if Bytes.ascii(prefix, 0, 2) == "BM" {
            return parseBMP(prefix)
        }
        if Bytes.ascii(prefix, 0, 2) == "II" || Bytes.ascii(prefix, 0, 2) == "MM" {
            return TIFFParser.parse(prefix)
        }
        switch fileExtension {
        case "jpg", "jpeg", "jpe", "jfif":
            return parseJPEG(prefix)
        case "png":
            return parsePNG(prefix)
        case "gif":
            return parseGIF(prefix)
        case "bmp":
            return parseBMP(prefix)
        case "tif", "tiff", "dng", "cr2", "nef", "nrw", "arw", "srf", "sr2", "orf", "rw2", "pef", "srw":
            return TIFFParser.parse(prefix)
        default:
            return nil
        }
    }

    private static func parseJPEG(_ data: Data) -> MediaMetadata? {
        guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else { return nil }
        var metadata = MediaMetadata(formatName: "JPEG")
        var index = 2
        while index + 1 < data.count {
            if data[index] != 0xFF {
                break
            }
            while index < data.count, data[index] == 0xFF {
                index += 1
            }
            guard index < data.count else { break }
            let marker = data[index]
            index += 1
            if marker == 0xD9 || marker == 0xDA {
                break
            }
            if marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8) {
                continue
            }
            guard let length = Bytes.u16be(data, index), length >= 2 else { break }
            let payloadStart = index + 2
            let payloadLength = Int(length) - 2
            guard payloadStart + payloadLength <= data.count else { break }
            let payload = data.subdata(in: payloadStart..<(payloadStart + payloadLength))
            if marker == 0xE1, payload.count > 6, Bytes.ascii(payload, 0, 6) == "Exif\0\0" {
                let tiff = payload.subdata(in: 6..<payload.count)
                if let exif = TIFFParser.parse(tiff, applyOrientation: false) {
                    metadata.fillMissing(from: exif)
                }
            }
            if isSOF(marker), payload.count >= 5, let height = Bytes.u16be(payload, 1), let width = Bytes.u16be(payload, 3) {
                metadata.pixelWidth = Int(width)
                metadata.pixelHeight = Int(height)
            }
            index = payloadStart + payloadLength
        }
        metadata.formatName = "JPEG"
        metadata.applyOrientationSwap()
        return metadata
    }

    private static func isSOF(_ marker: UInt8) -> Bool {
        switch marker {
        case 0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF:
            return true
        default:
            return false
        }
    }

    private static func parsePNG(_ data: Data) -> MediaMetadata? {
        guard data.count >= 24 else { return nil }
        var metadata = MediaMetadata(formatName: "PNG")
        var offset = 8
        while offset + 12 <= data.count {
            guard let length = Bytes.u32be(data, offset), let type = Bytes.ascii(data, offset + 4, 4) else { break }
            let body = offset + 8
            let next = body + Int(length) + 4
            if length > 32_000_000 || next > data.count { break }
            if type == "IHDR", length >= 8, let width = Bytes.u32be(data, body), let height = Bytes.u32be(data, body + 4) {
                metadata.pixelWidth = Int(width)
                metadata.pixelHeight = Int(height)
            } else if type == "eXIf" {
                let tiff = data.subdata(in: body..<(body + Int(length)))
                if let exif = TIFFParser.parse(tiff, applyOrientation: false) {
                    metadata.fillMissing(from: exif)
                    metadata.formatName = "PNG"
                }
            }
            offset = next
        }
        metadata.applyOrientationSwap()
        return metadata.pixelWidth == nil && metadata.dateTaken == nil ? nil : metadata
    }

    private static func parseGIF(_ data: Data) -> MediaMetadata? {
        guard data.count >= 10, Bytes.ascii(data, 0, 3) == "GIF" else { return nil }
        guard let width = Bytes.u16le(data, 6), let height = Bytes.u16le(data, 8) else { return nil }
        return MediaMetadata(pixelWidth: Int(width), pixelHeight: Int(height), formatName: "GIF")
    }

    private static func parseBMP(_ data: Data) -> MediaMetadata? {
        guard data.count >= 26, Bytes.ascii(data, 0, 2) == "BM" else { return nil }
        guard let width = Bytes.u32le(data, 18), let heightRaw = Bytes.u32le(data, 22) else { return nil }
        let height = Int(Int32(bitPattern: heightRaw).magnitude)
        guard width > 0, height > 0 else { return nil }
        return MediaMetadata(pixelWidth: Int(width), pixelHeight: height, formatName: "BMP")
    }
}
