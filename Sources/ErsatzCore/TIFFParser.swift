import Foundation

enum TIFFParser {
    static func parse(_ data: Data, applyOrientation: Bool = true) -> MediaMetadata? {
        guard data.count >= 8 else { return nil }
        let little: Bool
        if Bytes.ascii(data, 0, 2) == "II" {
            little = true
        } else if Bytes.ascii(data, 0, 2) == "MM" {
            little = false
        } else {
            return nil
        }
        let reader = EndianReader(data: data, little: little)
        guard reader.u16(2) == 42, let first = reader.u32(4) else { return nil }
        var state = State()
        var seen = Set<Int>()
        walk(ifd: Int(first), reader: reader, state: &state, seen: &seen, depth: 0)
        guard state.sawIFD else { return nil }
        var metadata = MediaMetadata()
        metadata.pixelWidth = state.width
        metadata.pixelHeight = state.height
        metadata.cameraModel = CodecName.camera(make: state.make, model: state.model)
        metadata.orientation = state.orientation
        let dateString = state.dateOriginal ?? state.dateTime
        if let dateString, let interpreted = EXIFDateParser.interpret(dateString) {
            metadata.dateTaken = interpreted.date
            metadata.dateCorrectedFromBuddhistEra = interpreted.correctedFromBuddhistEra
        }
        metadata.formatName = "TIFF"
        if applyOrientation {
            metadata.applyOrientationSwap()
        }
        return metadata
    }

    private struct State {
        var sawIFD = false
        var width: Int?
        var height: Int?
        var bestPixels: Int64 = -1
        var make: String?
        var model: String?
        var dateOriginal: String?
        var dateTime: String?
        var orientation: Int?
    }

    private static func walk(
        ifd offset: Int,
        reader: EndianReader,
        state: inout State,
        seen: inout Set<Int>,
        depth: Int
    ) {
        guard depth < 6, offset > 0, seen.insert(offset).inserted else { return }
        guard let count16 = reader.u16(offset) else { return }
        let count = Int(count16)
        guard count > 0, count < 4096 else { return }
        let entryBytes = count * 12
        guard offset + 2 + entryBytes + 4 <= reader.data.count else { return }
        state.sawIFD = true
        var imageWidth: Int?
        var imageHeight: Int?
        var pixelX: Int?
        var pixelY: Int?
        var subIFDs: [Int] = []
        var exifIFD: Int?
        var nextIFD: Int?
        for index in 0..<count {
            let entry = offset + 2 + index * 12
            guard
                let tag = reader.u16(entry),
                let type = reader.u16(entry + 2),
                let valueCount = reader.u32(entry + 4)
            else { continue }
            switch tag {
            case 256:
                imageWidth = firstInt(reader: reader, type: type, count: valueCount, entry: entry)
            case 257:
                imageHeight = firstInt(reader: reader, type: type, count: valueCount, entry: entry)
            case 271:
                if state.make == nil {
                    state.make = ascii(reader: reader, type: type, count: valueCount, entry: entry)
                }
            case 272:
                if state.model == nil {
                    state.model = ascii(reader: reader, type: type, count: valueCount, entry: entry)
                }
            case 274:
                state.orientation = firstInt(reader: reader, type: type, count: valueCount, entry: entry)
            case 306:
                state.dateTime = ascii(reader: reader, type: type, count: valueCount, entry: entry)
            case 330:
                subIFDs = integers(reader: reader, type: type, count: valueCount, entry: entry)
            case 34665:
                exifIFD = firstInt(reader: reader, type: type, count: valueCount, entry: entry)
            case 36867:
                state.dateOriginal = ascii(reader: reader, type: type, count: valueCount, entry: entry)
            case 40962:
                pixelX = firstInt(reader: reader, type: type, count: valueCount, entry: entry)
            case 40963:
                pixelY = firstInt(reader: reader, type: type, count: valueCount, entry: entry)
            default:
                break
            }
        }
        consider(width: imageWidth, height: imageHeight, state: &state)
        consider(width: pixelX, height: pixelY, state: &state)
        if let next = reader.u32(offset + 2 + entryBytes), next > 0 {
            nextIFD = Int(next)
        }
        if let exifIFD {
            walk(ifd: exifIFD, reader: reader, state: &state, seen: &seen, depth: depth + 1)
        }
        for sub in subIFDs {
            walk(ifd: sub, reader: reader, state: &state, seen: &seen, depth: depth + 1)
        }
        if let nextIFD {
            walk(ifd: nextIFD, reader: reader, state: &state, seen: &seen, depth: depth + 1)
        }
    }

    private static func consider(width: Int?, height: Int?, state: inout State) {
        guard let width, let height, width > 0, height > 0 else { return }
        let pixels = Int64(width) * Int64(height)
        if pixels > state.bestPixels {
            state.bestPixels = pixels
            state.width = width
            state.height = height
        }
    }

    private static func typeSize(_ type: UInt16) -> Int? {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8: return 2
        case 4, 9: return 4
        case 5, 10: return 8
        default: return nil
        }
    }

    private static func valueOffset(reader: EndianReader, type: UInt16, count: UInt32, entry: Int) -> Int? {
        guard let size = typeSize(type), count > 0, count < 2_000_000 else { return nil }
        let bytes = Int(count) * size
        if bytes <= 4 {
            return entry + 8
        }
        guard let offset = reader.u32(entry + 8) else { return nil }
        return Int(offset)
    }

    private static func firstInt(reader: EndianReader, type: UInt16, count: UInt32, entry: Int) -> Int? {
        integers(reader: reader, type: type, count: min(count, 1), entry: entry).first
    }

    private static func integers(reader: EndianReader, type: UInt16, count: UInt32, entry: Int) -> [Int] {
        guard let start = valueOffset(reader: reader, type: type, count: count, entry: entry) else { return [] }
        let limited = min(Int(count), 64)
        var values: [Int] = []
        for index in 0..<limited {
            switch type {
            case 3, 8:
                let offset = start + index * 2
                if let value = reader.u16(offset) { values.append(Int(value)) }
            case 4, 9:
                let offset = start + index * 4
                if let value = reader.u32(offset) { values.append(Int(value)) }
            case 1, 6, 7:
                let offset = start + index
                guard offset >= 0, offset < reader.data.count else { continue }
                values.append(Int(reader.data[reader.data.startIndex + offset]))
            default:
                break
            }
        }
        return values
    }

    private static func ascii(reader: EndianReader, type: UInt16, count: UInt32, entry: Int) -> String? {
        guard type == 2 || type == 7 || type == 1 else { return nil }
        guard let start = valueOffset(reader: reader, type: type, count: count, entry: entry) else { return nil }
        let length = min(Int(count), 512)
        guard start >= 0, start + length <= reader.data.count else { return nil }
        let slice = reader.data.subdata(in: start..<(start + length))
        let text = String(data: slice, encoding: .utf8) ?? String(data: slice, encoding: .ascii)
        let cleaned = text?
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleaned, !cleaned.isEmpty { return cleaned }
        return nil
    }
}
