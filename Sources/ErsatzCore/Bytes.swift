import Foundation

enum Bytes {
    static func u16(_ data: Data, _ offset: Int, little: Bool) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        let b0 = UInt16(data[data.startIndex + offset])
        let b1 = UInt16(data[data.startIndex + offset + 1])
        if little {
            return b0 | (b1 << 8)
        }
        return (b0 << 8) | b1
    }

    static func u32(_ data: Data, _ offset: Int, little: Bool) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let b3 = UInt32(data[data.startIndex + offset + 3])
        if little {
            return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
        }
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    static func u16be(_ data: Data, _ offset: Int) -> UInt16? {
        u16(data, offset, little: false)
    }

    static func u16le(_ data: Data, _ offset: Int) -> UInt16? {
        u16(data, offset, little: true)
    }

    static func u32be(_ data: Data, _ offset: Int) -> UInt32? {
        u32(data, offset, little: false)
    }

    static func u32le(_ data: Data, _ offset: Int) -> UInt32? {
        u32(data, offset, little: true)
    }

    static func u64be(_ data: Data, _ offset: Int) -> UInt64? {
        guard let high = u32be(data, offset), let low = u32be(data, offset + 4) else { return nil }
        return (UInt64(high) << 32) | UInt64(low)
    }

    static func ascii(_ data: Data, _ offset: Int, _ count: Int) -> String? {
        guard count >= 0, offset >= 0, offset + count <= data.count else { return nil }
        let slice = data.subdata(in: (offset)..<(offset + count))
        return String(data: slice, encoding: .ascii)
    }

    static func hasPrefix(_ data: Data, _ bytes: [UInt8]) -> Bool {
        guard data.count >= bytes.count else { return false }
        return zip(data.prefix(bytes.count), bytes).allSatisfy { $0 == $1 }
    }
}

struct EndianReader {
    let data: Data
    let little: Bool

    func u16(_ offset: Int) -> UInt16? {
        Bytes.u16(data, offset, little: little)
    }

    func u32(_ offset: Int) -> UInt32? {
        Bytes.u32(data, offset, little: little)
    }
}
