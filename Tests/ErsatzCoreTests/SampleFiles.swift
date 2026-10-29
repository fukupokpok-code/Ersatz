import Foundation

enum SampleFiles {
    static func jpeg(
        width: Int,
        height: Int,
        make: String? = nil,
        model: String? = nil,
        date: String? = nil,
        orientation: Int? = nil
    ) -> Data {
        let tiff = tiff(
            littleEndian: true,
            width: width,
            height: height,
            make: make,
            model: model,
            date: date,
            orientation: orientation
        )
        var payload = Data("Exif\0\0".utf8)
        payload.append(tiff)
        var data = Data([0xFF, 0xD8])
        data.append(marker(0xE1, payload))
        var sof = Data([8])
        sof.append(be16(UInt16(height)))
        sof.append(be16(UInt16(width)))
        sof.append(contentsOf: [1, 1, 0x11, 0])
        data.append(marker(0xC0, sof))
        data.append(contentsOf: [0xFF, 0xD9])
        return data
    }

    static func png(width: UInt32, height: UInt32) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        ihdr.append(be32(width))
        ihdr.append(be32(height))
        ihdr.append(contentsOf: [8, 2, 0, 0, 0])
        data.append(chunk("IHDR", ihdr))
        data.append(chunk("IEND", Data()))
        return data
    }

    static func gif(width: UInt16, height: UInt16) -> Data {
        var data = Data("GIF89a".utf8)
        data.append(le16(width))
        data.append(le16(height))
        data.append(contentsOf: [0, 0, 0])
        return data
    }

    static func wav(sampleRate: UInt32, channels: UInt16, bits: UInt16, frames: UInt32) -> Data {
        let blockAlign = channels * (bits / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = frames * UInt32(blockAlign)
        var fmt = Data()
        fmt.append(le16(1))
        fmt.append(le16(channels))
        fmt.append(le32(sampleRate))
        fmt.append(le32(byteRate))
        fmt.append(le16(blockAlign))
        fmt.append(le16(bits))
        let body = Data("WAVE".utf8) + riffChunk("fmt ", fmt) + riffChunk("data", Data(count: Int(dataSize)))
        return riffChunk("RIFF", body)
    }

    static func aiff(sampleRate: Double, frames: UInt32) -> Data {
        var comm = Data()
        comm.append(be16(1))
        comm.append(be32(frames))
        comm.append(be16(16))
        comm.append(contentsOf: [0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0])
        _ = sampleRate
        var form = Data("AIFF".utf8)
        form.append(formChunk("COMM", comm))
        let payloadSize = UInt32(form.count)
        var data = Data("FORM".utf8)
        data.append(be32(payloadSize))
        data.append(form)
        return data
    }

    static func flac(sampleRate: UInt32, samples: UInt64) -> Data {
        var stream = Data(count: 34)
        stream[10] = UInt8((sampleRate >> 12) & 0xFF)
        stream[11] = UInt8((sampleRate >> 4) & 0xFF)
        stream[12] = UInt8((sampleRate & 0x0F) << 4)
        stream[13] = UInt8((samples >> 32) & 0x0F)
        stream[14] = UInt8((samples >> 24) & 0xFF)
        stream[15] = UInt8((samples >> 16) & 0xFF)
        stream[16] = UInt8((samples >> 8) & 0xFF)
        stream[17] = UInt8(samples & 0xFF)
        var data = Data("fLaC".utf8)
        let length = UInt32(stream.count)
        data.append(0)
        data.append(UInt8((length >> 16) & 0xFF))
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))
        data.append(stream)
        return data
    }

    static func mp3(durationSeconds: Double, bitrate: Int = 128_000) -> Data {
        let size = Int(durationSeconds * Double(bitrate) / 8)
        var data = Data(count: max(size, 4))
        data[0] = 0xFF
        data[1] = 0xFB
        data[2] = 0x90
        data[3] = 0x00
        return data
    }

    static func mp4(width: UInt16, height: UInt16, duration: UInt32, timescale: UInt32) -> Data {
        let ftyp = box("ftyp", Data("isom".utf8) + be32(0) + Data("isom".utf8) + Data("mp42".utf8))
        let mvhd = box("mvhd", movieHeader(timescale: timescale, duration: duration))
        let video = trackBox(handler: "vide", codec: "avc1", width: width, height: height, timescale: timescale, duration: duration, visual: true)
        let audio = trackBox(handler: "soun", codec: "mp4a", width: 0, height: 0, timescale: timescale, duration: duration, visual: false)
        let mdat = box("mdat", Data(count: 64))
        let moov = box("moov", mvhd + video + audio)
        return ftyp + mdat + moov
    }

    static func tiff(
        littleEndian: Bool,
        width: Int,
        height: Int,
        make: String?,
        model: String?,
        date: String?,
        orientation: Int?
    ) -> Data {
        struct Entry {
            var tag: UInt16
            var type: UInt16
            var payload: Data
        }
        var entries: [Entry] = [
            Entry(tag: 256, type: 4, payload: endian32(UInt32(width), little: littleEndian)),
            Entry(tag: 257, type: 4, payload: endian32(UInt32(height), little: littleEndian))
        ]
        if let make {
            entries.append(Entry(tag: 271, type: 2, payload: cString(make)))
        }
        if let model {
            entries.append(Entry(tag: 272, type: 2, payload: cString(model)))
        }
        if let orientation {
            entries.append(Entry(tag: 274, type: 3, payload: endian16(UInt16(orientation), little: littleEndian)))
        }
        entries.sort { $0.tag < $1.tag }
        let ifd0Count = entries.count + 1
        let ifd0Size = 2 + ifd0Count * 12 + 4
        var strings = Data()
        func place(_ payload: Data) -> UInt32 {
            let offset = UInt32(8 + ifd0Size + strings.count)
            strings.append(payload)
            return offset
        }
        struct Encoded {
            var tag: UInt16
            var type: UInt16
            var count: UInt32
            var field: Data
        }
        var encoded: [Encoded] = []
        for entry in entries {
            let count = UInt32(entry.type == 2 ? entry.payload.count : entry.payload.count / max(typeSize(entry.type), 1))
            let field: Data
            if entry.payload.count <= 4 {
                var inline = entry.payload
                while inline.count < 4 { inline.append(0) }
                field = inline
            } else {
                field = endian32(place(entry.payload), little: littleEndian)
            }
            encoded.append(Encoded(tag: entry.tag, type: entry.type, count: count, field: field))
        }
        let exifBase = 8 + ifd0Size + strings.count
        let datePayload = date.map(cString) ?? Data([0])
        let exif = ifdWithOneExternal(entryTag: 0x9003, type: 2, payload: datePayload, base: exifBase, little: littleEndian)
        encoded.append(Encoded(tag: 34665, type: 4, count: 1, field: endian32(UInt32(exifBase), little: littleEndian)))
        encoded.sort { $0.tag < $1.tag }

        var ifd = Data()
        ifd.append(endian16(UInt16(encoded.count), little: littleEndian))
        for entry in encoded {
            ifd.append(endian16(entry.tag, little: littleEndian))
            ifd.append(endian16(entry.type, little: littleEndian))
            ifd.append(endian32(entry.count, little: littleEndian))
            ifd.append(entry.field.prefix(4))
        }
        ifd.append(endian32(0, little: littleEndian))

        var data = Data()
        data.append(contentsOf: littleEndian ? [0x49, 0x49] : [0x4D, 0x4D])
        data.append(endian16(42, little: littleEndian))
        data.append(endian32(8, little: littleEndian))
        data.append(ifd)
        data.append(strings)
        data.append(exif)
        return data
    }

    private static func typeSize(_ type: UInt16) -> Int {
        switch type {
        case 3: return 2
        case 4: return 4
        default: return 1
        }
    }

    private static func ifdWithOneExternal(entryTag: UInt16, type: UInt16, payload: Data, base: Int, little: Bool) -> Data {
        let ifdSize = 2 + 12 + 4
        var data = Data()
        data.append(endian16(1, little: little))
        data.append(endian16(entryTag, little: little))
        data.append(endian16(type, little: little))
        data.append(endian32(UInt32(payload.count), little: little))
        data.append(endian32(UInt32(base + ifdSize), little: little))
        data.append(endian32(0, little: little))
        data.append(payload)
        return data
    }

    private static func cString(_ value: String) -> Data {
        var data = Data(value.utf8)
        data.append(0)
        return data
    }

    private static func marker(_ marker: UInt8, _ payload: Data) -> Data {
        var data = Data([0xFF, marker])
        let length = UInt16(payload.count + 2)
        data.append(be16(length))
        data.append(payload)
        return data
    }

    private static func chunk(_ type: String, _ payload: Data) -> Data {
        var data = Data()
        data.append(be32(UInt32(payload.count)))
        data.append(Data(type.utf8))
        data.append(payload)
        data.append(be32(0))
        return data
    }

    private static func riffChunk(_ type: String, _ payload: Data) -> Data {
        var data = Data(type.utf8)
        data.append(le32(UInt32(payload.count)))
        data.append(payload)
        if payload.count % 2 == 1 { data.append(0) }
        return data
    }

    private static func formChunk(_ type: String, _ payload: Data) -> Data {
        var data = Data(type.utf8)
        data.append(be32(UInt32(payload.count)))
        data.append(payload)
        if payload.count % 2 == 1 { data.append(0) }
        return data
    }

    private static func box(_ type: String, _ payload: Data) -> Data {
        var data = Data()
        data.append(be32(UInt32(8 + payload.count)))
        data.append(Data(type.utf8))
        data.append(payload)
        return data
    }

    private static func movieHeader(timescale: UInt32, duration: UInt32) -> Data {
        var data = Data(count: 100)
        data.replaceSubrange(12..<16, with: be32(timescale))
        data.replaceSubrange(16..<20, with: be32(duration))
        return data
    }

    private static func trackBox(
        handler: String,
        codec: String,
        width: UInt16,
        height: UInt16,
        timescale: UInt32,
        duration: UInt32,
        visual: Bool
    ) -> Data {
        let tkhd = box("tkhd", trackHeader(width: width, height: height, duration: duration))
        let mdhd = box("mdhd", mediaHeader(timescale: timescale, duration: duration))
        var hdlr = Data(count: 8)
        hdlr.append(Data(handler.utf8))
        hdlr.append(Data(count: 13))
        hdlr.append(0)
        let handlerBox = box("hdlr", hdlr)
        let stsd = box("stsd", sampleDescription(codec: codec, width: width, height: height, visual: visual))
        let stbl = box("stbl", stsd)
        let minf = box("minf", stbl)
        let mdia = box("mdia", mdhd + handlerBox + minf)
        return box("trak", tkhd + mdia)
    }

    private static func trackHeader(width: UInt16, height: UInt16, duration: UInt32) -> Data {
        var data = Data(count: 84)
        data[3] = 3
        data.replaceSubrange(20..<24, with: be32(duration))
        let widthFixed = UInt32(width) << 16
        let heightFixed = UInt32(height) << 16
        data.replaceSubrange(76..<80, with: be32(widthFixed))
        data.replaceSubrange(80..<84, with: be32(heightFixed))
        return data
    }

    private static func mediaHeader(timescale: UInt32, duration: UInt32) -> Data {
        var data = Data(count: 24)
        data.replaceSubrange(12..<16, with: be32(timescale))
        data.replaceSubrange(16..<20, with: be32(duration))
        return data
    }

    private static func sampleDescription(codec: String, width: UInt16, height: UInt16, visual: Bool) -> Data {
        var entry = Data(count: visual ? 86 : 36)
        let size = UInt32(entry.count)
        entry.replaceSubrange(0..<4, with: be32(size))
        entry.replaceSubrange(4..<8, with: Data(codec.utf8))
        if visual {
            entry.replaceSubrange(32..<34, with: be16(width))
            entry.replaceSubrange(34..<36, with: be16(height))
        }
        var payload = Data(count: 4)
        payload.append(be32(1))
        payload.append(entry)
        return payload
    }

    private static func be16(_ value: UInt16) -> Data {
        Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    private static func be32(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    private static func le16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    private static func le32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }

    private static func endian16(_ value: UInt16, little: Bool) -> Data {
        little ? le16(value) : be16(value)
    }

    private static func endian32(_ value: UInt32, little: Bool) -> Data {
        little ? le32(value) : be32(value)
    }
}
