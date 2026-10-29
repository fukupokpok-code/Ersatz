import Foundation

final class RandomAccessFile {
    private let handle: FileHandle
    let size: UInt64

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
    }

    deinit {
        try? handle.close()
    }

    func read(at offset: UInt64, count: Int) throws -> Data {
        if count <= 0 { return Data() }
        guard offset < size else { return Data() }
        let available = min(UInt64(count), size - offset)
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: Int(available)) ?? Data()
    }
}

enum ISOBMFFParser {
    static func parse(file: RandomAccessFile) -> MediaMetadata {
        let movie = MovieBox()
        walk(start: 0, end: file.size, file: file, movie: movie, track: nil)
        var metadata = MediaMetadata()
        metadata.pixelWidth = movie.width
        metadata.pixelHeight = movie.height
        metadata.duration = movie.durationSeconds
        metadata.videoCodec = movie.videoCodec
        metadata.audioCodec = movie.audioCodec
        metadata.formatName = movie.formatName
        return metadata
    }

    private final class MovieBox {
        var durationSeconds: Double?
        var width: Int?
        var height: Int?
        var videoCodec: String?
        var audioCodec: String?
        var formatName: String?
    }

    private final class TrackBox {
        var handler: String?
        var width: Int?
        var height: Int?
        var codec: String?
    }

    private static func walk(
        start: UInt64,
        end: UInt64,
        file: RandomAccessFile,
        movie: MovieBox,
        track: TrackBox?
    ) {
        var offset = start
        var guardrail = 0
        while offset + 8 <= end, guardrail < 100_000 {
            guardrail += 1
            guard let header = readHeader(file: file, offset: offset), header.boxSize >= header.headerSize else { return }
            let payloadStart = offset + header.headerSize
            let payloadEnd = offset + header.boxSize
            if payloadEnd < payloadStart || payloadEnd > file.size + 1 { return }
            let limitedEnd = min(payloadEnd, file.size)
            switch header.type {
            case "moov", "mdia", "minf", "stbl", "iprp", "ipco", "edts":
                walk(start: payloadStart, end: limitedEnd, file: file, movie: movie, track: track)
            case "trak":
                let child = TrackBox()
                walk(start: payloadStart, end: limitedEnd, file: file, movie: movie, track: child)
                commit(child, to: movie)
            case "meta":
                if payloadStart + 4 < limitedEnd {
                    walk(start: payloadStart + 4, end: limitedEnd, file: file, movie: movie, track: track)
                }
            case "mvhd":
                parseMovieHeader(file: file, start: payloadStart, end: limitedEnd, movie: movie)
            case "tkhd":
                if let track {
                    parseTrackHeader(file: file, start: payloadStart, end: limitedEnd, track: track)
                }
            case "hdlr":
                if let track {
                    track.handler = parseHandler(file: file, start: payloadStart, end: limitedEnd)
                }
            case "stsd":
                if let track {
                    parseSampleDescription(file: file, start: payloadStart, end: limitedEnd, track: track)
                }
            case "ftyp":
                parseFileType(file: file, start: payloadStart, end: limitedEnd, movie: movie)
            case "ispe":
                parseImageSpatial(file: file, start: payloadStart, end: limitedEnd, movie: movie)
            default:
                break
            }
            if header.boxSize == 0 { return }
            let next = offset + header.boxSize
            if next <= offset { return }
            offset = next
        }
    }

    private static func readHeader(file: RandomAccessFile, offset: UInt64) -> (type: String, headerSize: UInt64, boxSize: UInt64)? {
        guard let data = try? file.read(at: offset, count: 16), data.count >= 8 else { return nil }
        guard let size32 = Bytes.u32be(data, 0), let type = Bytes.ascii(data, 4, 4) else { return nil }
        if size32 == 1 {
            guard data.count >= 16, let large = Bytes.u64be(data, 8), large >= 16 else { return nil }
            return (type, 16, large)
        }
        if size32 == 0 {
            return (type, 8, file.size - offset)
        }
        if size32 < 8 { return nil }
        return (type, 8, UInt64(size32))
    }

    private static func parseMovieHeader(file: RandomAccessFile, start: UInt64, end: UInt64, movie: MovieBox) {
        let count = min(128, Int(end - start))
        guard let data = try? file.read(at: start, count: count), let version = data.first else { return }
        let timescale: UInt32?
        let duration: UInt64?
        if version == 1 {
            timescale = Bytes.u32be(data, 20)
            duration = Bytes.u64be(data, 24)
        } else {
            timescale = Bytes.u32be(data, 12)
            duration = Bytes.u32be(data, 16).map(UInt64.init)
        }
        if let timescale, let duration, timescale > 0 {
            movie.durationSeconds = Double(duration) / Double(timescale)
        }
    }

    private static func parseTrackHeader(file: RandomAccessFile, start: UInt64, end: UInt64, track: TrackBox) {
        let count = min(128, Int(end - start))
        guard let data = try? file.read(at: start, count: count), let version = data.first else { return }
        let widthOffset = version == 1 ? 88 : 76
        guard data.count >= widthOffset + 8,
              let widthFixed = Bytes.u32be(data, widthOffset),
              let heightFixed = Bytes.u32be(data, widthOffset + 4) else { return }
        let width = Int(widthFixed >> 16)
        let height = Int(heightFixed >> 16)
        if width > 0 { track.width = width }
        if height > 0 { track.height = height }
    }

    private static func parseHandler(file: RandomAccessFile, start: UInt64, end: UInt64) -> String? {
        let count = min(64, Int(end - start))
        guard let data = try? file.read(at: start, count: count), data.count >= 12 else { return nil }
        return Bytes.ascii(data, 8, 4)?.trimmingCharacters(in: .whitespaces)
    }

    private static func parseSampleDescription(file: RandomAccessFile, start: UInt64, end: UInt64, track: TrackBox) {
        let count = min(4096, Int(end - start))
        guard let data = try? file.read(at: start, count: count), data.count >= 16 else { return }
        guard let entryCount = Bytes.u32be(data, 4), entryCount > 0 else { return }
        guard let entrySize = Bytes.u32be(data, 8), entrySize >= 8, let format = Bytes.ascii(data, 12, 4) else { return }
        track.codec = format.trimmingCharacters(in: .whitespaces)
        if entrySize >= 36, data.count >= 8 + 36, let width = Bytes.u16be(data, 8 + 32), let height = Bytes.u16be(data, 8 + 34) {
            if width > 0, track.width == nil { track.width = Int(width) }
            if height > 0, track.height == nil { track.height = Int(height) }
        }
    }

    private static func parseFileType(file: RandomAccessFile, start: UInt64, end: UInt64, movie: MovieBox) {
        guard movie.formatName == nil else { return }
        let count = min(64, Int(end - start))
        guard let data = try? file.read(at: start, count: count), let brand = Bytes.ascii(data, 0, 4) else { return }
        movie.formatName = formatName(for: brand)
    }

    private static func parseImageSpatial(file: RandomAccessFile, start: UInt64, end: UInt64, movie: MovieBox) {
        guard movie.width == nil || movie.height == nil else { return }
        let count = min(20, Int(end - start))
        guard let data = try? file.read(at: start, count: count), data.count >= 12 else { return }
        guard let width = Bytes.u32be(data, 4), let height = Bytes.u32be(data, 8), width > 0, height > 0 else { return }
        movie.width = Int(width)
        movie.height = Int(height)
    }

    private static func commit(_ track: TrackBox, to movie: MovieBox) {
        let codec = track.codec ?? ""
        let handler = track.handler ?? ""
        let videoHandlers: Set<String> = ["vide", "pict", "vid"]
        let audioHandlers: Set<String> = ["soun", "soun"]
        let knownVideo: Set<String> = [
            "avc1", "avc3", "hvc1", "hev1", "apch", "apcn", "apcs", "apco", "ap4h", "ap4x",
            "mp4v", "jpeg", "vp09", "av01"
        ]
        if videoHandlers.contains(handler) || knownVideo.contains(codec.trimmingCharacters(in: .whitespaces).lowercased()) {
            if !codec.isEmpty, movie.videoCodec == nil {
                movie.videoCodec = CodecName.video(fourCC: codec)
            }
            if movie.width == nil { movie.width = track.width }
            if movie.height == nil { movie.height = track.height }
        } else if audioHandlers.contains(handler) || codec.trimmingCharacters(in: .whitespaces).lowercased() == "mp4a" {
            if !codec.isEmpty, movie.audioCodec == nil {
                movie.audioCodec = CodecName.audio(fourCC: codec)
            }
        }
    }

    private static func formatName(for brand: String) -> String {
        switch brand.trimmingCharacters(in: .whitespaces) {
        case "qt":
            return "QuickTime"
        case "heic", "heix", "hevc":
            return "HEIC"
        case "mif1", "msf1":
            return "HEIF"
        case "avif":
            return "AVIF"
        case "crx":
            return "CR3"
        default:
            return "MP4"
        }
    }
}
