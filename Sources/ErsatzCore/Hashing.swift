import Foundation

public enum SHA256Digest {
    public static func hex(_ data: Data) -> String {
        var hasher = Hasher()
        hasher.update(data)
        return hex(hasher.finalize())
    }

    /// SHA-256 of the file, or of the first `maxBytes` when that limit is set.
    public static func hexFile(at url: URL, maxBytes: Int? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Hasher()
        var remaining = maxBytes ?? Int.max
        while remaining > 0 {
            let count = min(remaining, 64 * 1024)
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
            hasher.update(chunk)
            remaining -= chunk.count
            if maxBytes == nil, chunk.count < count { break }
        }
        return hex(hasher.finalize())
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private struct Hasher {
        private var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        ]
        private var buffer = [UInt8]()
        private var bitCount: UInt64 = 0

        mutating func update(_ data: Data) {
            buffer.append(contentsOf: data)
            bitCount += UInt64(data.count) * 8
            while buffer.count >= 64 {
                let block = Array(buffer.prefix(64))
                buffer.removeFirst(64)
                compress(block)
            }
        }

        mutating func finalize() -> [UInt8] {
            var end = buffer
            end.append(0x80)
            while (end.count % 64) != 56 {
                end.append(0)
            }
            var length = bitCount.bigEndian
            withUnsafeBytes(of: &length) { end.append(contentsOf: $0) }
            var index = 0
            while index < end.count {
                compress(Array(end[index..<(index + 64)]))
                index += 64
            }
            return h.flatMap { word -> [UInt8] in
                let value = word.bigEndian
                return withUnsafeBytes(of: value) { Array($0) }
            }
        }

        private mutating func compress(_ block: [UInt8]) {
            var w = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let offset = index * 4
                w[index] = (UInt32(block[offset]) << 24)
                    | (UInt32(block[offset + 1]) << 16)
                    | (UInt32(block[offset + 2]) << 8)
                    | UInt32(block[offset + 3])
            }
            for index in 16..<64 {
                let s0 = rotate(w[index - 15], 7) ^ rotate(w[index - 15], 18) ^ (w[index - 15] >> 3)
                let s1 = rotate(w[index - 2], 17) ^ rotate(w[index - 2], 19) ^ (w[index - 2] >> 10)
                w[index] = w[index - 16] &+ s0 &+ w[index - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]
            for index in 0..<64 {
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ ch &+ k[index] &+ w[index]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                hh = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
            h[5] = h[5] &+ f
            h[6] = h[6] &+ g
            h[7] = h[7] &+ hh
        }

        private func rotate(_ value: UInt32, _ bits: UInt32) -> UInt32 {
            (value >> bits) | (value << (32 - bits))
        }
    }

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]
}

public enum PerceptualHash {
    /// Difference hash. `gray` is row-major, one byte per pixel.
    public static func dHash(gray: [UInt8], width: Int, height: Int) -> UInt64 {
        guard width > 1, height > 1, gray.count >= width * height else { return 0 }
        var bits: UInt64 = 0
        var bit = 0
        for y in 0..<8 {
            var samples = [UInt8](repeating: 0, count: 9)
            for x in 0..<9 {
                samples[x] = sample(gray, width: width, height: height, x: x, y: y, columns: 9, rows: 8)
            }
            for x in 0..<8 where bit < 64 {
                if samples[x] > samples[x + 1] {
                    bits |= 1 << bit
                }
                bit += 1
            }
        }
        return bits
    }

    public static func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    private static func sample(
        _ gray: [UInt8],
        width: Int,
        height: Int,
        x: Int,
        y: Int,
        columns: Int,
        rows: Int
    ) -> UInt8 {
        let sourceX = min(width - 1, x * width / columns)
        let sourceY = min(height - 1, y * height / rows)
        return gray[sourceY * width + sourceX]
    }
}

public enum SharpnessScore {
    /// Variance of a 4-neighbor Laplacian. A flat image scores near 0.
    public static func laplacianVariance(gray: [UInt8], width: Int, height: Int) -> Double {
        guard width > 2, height > 2, gray.count >= width * height else { return 0 }
        var sum = 0.0
        var sumSquares = 0.0
        var count = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let center = Int(gray[y * width + x])
                let value = Double(
                    Int(gray[(y - 1) * width + x])
                        + Int(gray[(y + 1) * width + x])
                        + Int(gray[y * width + (x - 1)])
                        + Int(gray[y * width + (x + 1)])
                        - 4 * center
                )
                sum += value
                sumSquares += value * value
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        return max(0, sumSquares / count - mean * mean)
    }
}

public struct HashRecord: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var fileSize: Int64
    public var contentHash: String?
    public var perceptualHash: UInt64?

    public init(id: Int64, fileSize: Int64, contentHash: String?, perceptualHash: UInt64?) {
        self.id = id
        self.fileSize = fileSize
        self.contentHash = contentHash
        self.perceptualHash = perceptualHash
    }
}

public enum DuplicateFinder {
    public static func exactGroups(_ records: [HashRecord]) -> [[Int64]] {
        var buckets: [String: [Int64]] = [:]
        for record in records {
            guard let hash = record.contentHash, !hash.isEmpty else { continue }
            let key = "\(record.fileSize)|\(hash)"
            buckets[key, default: []].append(record.id)
        }
        return buckets.values.filter { $0.count > 1 }.map { $0.sorted() }.sorted { ($0.first ?? 0) < ($1.first ?? 0) }
    }

    /// Groups photos whose dHash is within `threshold` bits. Each id appears in at most one group.
    public static func nearGroups(_ records: [HashRecord], threshold: Int) -> [[Int64]] {
        let hashed = records.filter { $0.perceptualHash != nil }.sorted { $0.id < $1.id }
        var used = Set<Int64>()
        var groups: [[Int64]] = []
        for (index, record) in hashed.enumerated() {
            guard !used.contains(record.id), let hash = record.perceptualHash else { continue }
            var group = [record.id]
            for other in hashed[(index + 1)...] {
                guard !used.contains(other.id), let otherHash = other.perceptualHash else { continue }
                if PerceptualHash.hammingDistance(hash, otherHash) <= threshold {
                    group.append(other.id)
                }
            }
            if group.count > 1 {
                used.formUnion(group)
                groups.append(group.sorted())
            }
        }
        return groups
    }
}

public enum ScreenshotDetector {
    public static func matches(
        filename: String,
        formatName: String?,
        pixelWidth: Int?,
        pixelHeight: Int?,
        hasCameraModel: Bool,
        markedScreenCapture: Bool = false
    ) -> Bool {
        if markedScreenCapture { return true }
        let name = filename.lowercased()
        if name.contains("screenshot") || name.contains("screen shot") || name.contains("ภาพหน้าจอ") {
            return true
        }
        let format = (formatName ?? "").lowercased()
        guard format == "png" || name.hasSuffix(".png"), !hasCameraModel else { return false }
        guard let pixelWidth, let pixelHeight else { return false }
        let longSide = max(pixelWidth, pixelHeight)
        let shortSide = min(pixelWidth, pixelHeight)
        return knownScreens.contains(where: { max($0.0, $0.1) == longSide && min($0.0, $0.1) == shortSide })
    }

    /// Common Mac and iPhone framebuffer sizes, either orientation.
    private static let knownScreens: [(Int, Int)] = [
        (1920, 1080), (2560, 1440), (2880, 1800), (3024, 1964), (3456, 2234),
        (1512, 982), (1728, 1117), (1496, 967), (1800, 1169),
        (1170, 2532), (1284, 2778), (1290, 2796), (1179, 2556), (1206, 2622),
        (1125, 2436), (828, 1792), (1242, 2688), (750, 1334)
    ]
}

public enum BankSlipClassifier {
    public static let keywords = [
        "โอนเงินสำเร็จ", "จำนวนเงิน", "ค่าธรรมเนียม", "เลขที่รายการ",
        "กสิกร", "k plus", "kplus", "scb", "กรุงเทพ", "กรุงไทย", "krungthai",
        "ttb", "กรุงศรี", "promptpay", "พร้อมเพย์", "พร้อมเพย", "transfer successful",
        "amount", "fee", "reference",
        // Round 8: phrases Thai bank apps print that the first list missed.
        "ทำรายการสำเร็จ", "ชำระเงินสำเร็จ", "จ่ายบิลสำเร็จ", "เติมเงินสำเร็จ", "รหัสอ้างอิง",
        "เลขที่อ้างอิง", "สแกนตรวจสอบสลิป", "ตรวจสอบสลิป", "ออมสิน", "ธนาคาร", "ไทยพาณิชย์",
        "kbank", "krungsri", "bualuang", "make by kbank", "mymo", "paotang", "เป๋าตัง",
        "transaction id", "ref no", "successful"
    ]

    /// A slip usually has a QR plus at least two banking phrases, or three phrases without one.
    /// Text recognition often splits Thai words with spaces, so matching ignores whitespace.
    public static func isSlip(text: String, hasQR: Bool) -> Bool {
        let folded = squeezed(text)
        let hits = keywords.reduce(into: 0) { count, word in
            if folded.contains(squeezed(word)) { count += 1 }
        }
        if hasQR && hits >= 2 { return true }
        return hits >= 3
    }

    /// Text recognition is the slow step, so it runs only where a slip is plausible:
    /// a QR was found (Thai slips carry a verification QR), or the image did not come
    /// from a camera (screenshots and saved slips have no camera model).
    public static func shouldReadText(hasQR: Bool, hasCameraModel: Bool) -> Bool {
        hasQR || !hasCameraModel
    }

    private static func squeezed(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }
}

public struct FolderCover: Sendable, Equatable, Identifiable {
    public var relativePath: String
    public var name: String
    public var imagePaths: [String]

    public var id: String { relativePath }

    public init(relativePath: String, name: String, imagePaths: [String]) {
        self.relativePath = relativePath
        self.name = name
        self.imagePaths = imagePaths
    }
}

public enum FolderCoverPlanner {
    /// Immediate child folders of `directory` (empty string for the library root) and up to three image paths each.
    public static func covers(
        files: [(parent: String, path: String)],
        directories: [String] = [],
        directory: String
    ) -> [FolderCover] {
        var images: [String: [String]] = [:]
        for name in directories where !name.isEmpty {
            images[name] = images[name] ?? []
        }
        let prefix = directory.isEmpty ? "" : directory + "/"
        for file in files {
            let parent = file.parent
            let child: String
            if directory.isEmpty {
                guard !parent.isEmpty else { continue }
                child = parent.split(separator: "/").first.map(String.init) ?? parent
            } else {
                guard parent == directory || parent.hasPrefix(prefix) else { continue }
                if parent == directory { continue }
                let rest = parent.dropFirst(prefix.count)
                child = rest.split(separator: "/").first.map(String.init) ?? String(rest)
            }
            let key = directory.isEmpty ? child : prefix + child
            var list = images[key] ?? []
            if list.count < 3 {
                list.append(file.path)
                images[key] = list
            } else if images[key] == nil {
                images[key] = []
            }
        }
        return images.keys.sorted { FilenameOrder.compare($0, $1) == .orderedAscending }.map { key in
            let name = key.split(separator: "/").last.map(String.init) ?? key
            return FolderCover(relativePath: key, name: name, imagePaths: images[key] ?? [])
        }
    }
}
