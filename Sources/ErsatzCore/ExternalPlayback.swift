import Foundation

/// Playback for containers AVFoundation cannot open.
/// ffmpeg and ffprobe are never bundled or linked. Callers pass a path they located at runtime.
public enum ExternalPlayback {
    public static let containerExtensions: Set<String> = ["mkv", "webm", "avi", "flv", "wmv"]

    public static func needsExternalPlayer(path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return containerExtensions.contains(ext)
    }
}

public enum FFmpegInstallGuide {
    public static let brewCommand = "brew install ffmpeg"

    public static let summary = """
    This file needs ffmpeg, which Ersatz does not include or link.

    Install it with Homebrew, then open the file again:

    brew install ffmpeg

    Ersatz looks for ffmpeg and ffprobe in /opt/homebrew/bin, /usr/local/bin, and your PATH. A custom path can be set in Settings. The original file is never modified.
    """
}

public struct FFmpegTools: Sendable, Equatable {
    public var ffmpegPath: String
    public var ffprobePath: String

    public init(ffmpegPath: String, ffprobePath: String) {
        self.ffmpegPath = ffmpegPath
        self.ffprobePath = ffprobePath
    }
}

public enum FFmpegLocator {
    public static let preferredDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// Search order: custom file or directory, Homebrew, /usr/local, then PATH.
    /// A hit requires both ffmpeg and ffprobe in the same directory.
    public static func locate(
        customPath: String?,
        pathEnvironment: String?,
        isExecutable: (String) -> Bool
    ) -> FFmpegTools? {
        var directories: [String] = []
        if let customPath {
            let trimmed = customPath
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !trimmed.isEmpty {
                directories.append(directory(for: trimmed))
            }
        }
        directories.append(contentsOf: preferredDirectories)
        if let pathEnvironment {
            for part in pathEnvironment.split(separator: ":", omittingEmptySubsequences: true) {
                directories.append(String(part))
            }
        }
        var seen = Set<String>()
        for directory in directories {
            let normalized = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
                .standardizedFileURL
                .path
            if !seen.insert(normalized).inserted { continue }
            let folder = URL(fileURLWithPath: normalized, isDirectory: true)
            let ffmpeg = folder.appendingPathComponent("ffmpeg").path
            let ffprobe = folder.appendingPathComponent("ffprobe").path
            if isExecutable(ffmpeg), isExecutable(ffprobe) {
                return FFmpegTools(ffmpegPath: ffmpeg, ffprobePath: ffprobe)
            }
        }
        return nil
    }

    private static func directory(for candidate: String) -> String {
        let expanded = (candidate as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        switch url.lastPathComponent {
        case "ffmpeg", "ffprobe":
            return url.deletingLastPathComponent().path
        default:
            return expanded
        }
    }
}

public enum VideoToolboxEncoder: String, Sendable, Equatable {
    case h264 = "h264_videotoolbox"
    case hevc = "hevc_videotoolbox"
}

public enum PlaybackPlan: Sendable, Equatable {
    case remux(hevcTag: Bool, includeAudio: Bool)
    case transcode(encoder: VideoToolboxEncoder, includeAudio: Bool)
    case unsupported(String)
}

public struct PlaybackProgress: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        case probing
        case remuxing
        case transcoding
    }

    public var stage: Stage
    public var fraction: Double?

    public init(stage: Stage, fraction: Double?) {
        self.stage = stage
        self.fraction = fraction
    }
}

public enum PlaybackPlanner {
    public static func plan(videoCodec: String?, audioCodec: String?) -> PlaybackPlan {
        guard let video = normalized(videoCodec) else {
            return .unsupported("No video stream")
        }
        let audio = normalized(audioCodec)
        let includeAudio = audio != nil
        let audioCanCopy = audio == nil || copyAudio.contains(audio ?? "")
        if h264.contains(video), audioCanCopy {
            return .remux(hevcTag: false, includeAudio: includeAudio)
        }
        if hevc.contains(video), audioCanCopy {
            return .remux(hevcTag: true, includeAudio: includeAudio)
        }
        let encoder: VideoToolboxEncoder = hevc.contains(video) ? .hevc : .h264
        return .transcode(encoder: encoder, includeAudio: includeAudio)
    }

    private static let h264: Set<String> = ["h264", "avc", "avc1", "libx264"]
    private static let hevc: Set<String> = ["hevc", "h265", "hvc1", "hev1", "libx265"]
    private static let copyAudio: Set<String> = ["aac", "alac", "mp3", "ac3", "eac3"]

    private static func normalized(_ codec: String?) -> String? {
        guard let codec else { return nil }
        let trimmed = codec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum FFmpegCodecNames {
    public static func video(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "h264", "avc", "avc1", "libx264":
            return "H.264"
        case "hevc", "h265", "hvc1", "hev1", "libx265":
            return "HEVC"
        case "vp8":
            return "VP8"
        case "vp9":
            return "VP9"
        case "av1":
            return "AV1"
        case "mpeg4", "msmpeg4", "msmpeg4v1", "msmpeg4v2", "msmpeg4v3":
            return "MPEG-4"
        case "mpeg2video", "mpeg2":
            return "MPEG-2"
        case "mpeg1video":
            return "MPEG-1"
        case "wmv1", "wmv2", "wmv3":
            return "WMV"
        case "vc1":
            return "VC-1"
        case "flv1", "flv":
            return "FLV"
        case "theora":
            return "Theora"
        case "mjpeg":
            return "Motion JPEG"
        case "prores":
            return "ProRes"
        case "h263":
            return "H.263"
        case "dvvideo":
            return "DV"
        default:
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? raw : trimmed.uppercased()
        }
    }

    public static func audio(_ raw: String) -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "aac":
            return "AAC"
        case "alac":
            return "Apple Lossless"
        case "mp3":
            return "MP3"
        case "ac3":
            return "AC-3"
        case "eac3":
            return "E-AC-3"
        case "opus":
            return "Opus"
        case "vorbis":
            return "Vorbis"
        case "flac":
            return "FLAC"
        case "wmav1", "wmav2":
            return "WMA"
        case "dts":
            return "DTS"
        case "truehd":
            return "TrueHD"
        default:
            if key.hasPrefix("pcm_") { return "PCM" }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? raw : trimmed.uppercased()
        }
    }
}

public struct ProbeReport: Sendable, Equatable {
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var videoCodecRaw: String?
    public var audioCodecRaw: String?
    public var videoCodec: String?
    public var audioCodec: String?
    public var plan: PlaybackPlan

    public init(
        width: Int?,
        height: Int?,
        duration: Double?,
        videoCodecRaw: String?,
        audioCodecRaw: String?,
        videoCodec: String?,
        audioCodec: String?,
        plan: PlaybackPlan
    ) {
        self.width = width
        self.height = height
        self.duration = duration
        self.videoCodecRaw = videoCodecRaw
        self.audioCodecRaw = audioCodecRaw
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.plan = plan
    }

    public func metadata(formatName: String?) -> MediaMetadata {
        MediaMetadata(
            pixelWidth: width,
            pixelHeight: height,
            duration: duration,
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            formatName: formatName
        )
    }
}

public enum FFProbeJSON {
    public static func parse(_ data: Data) -> ProbeReport? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let streams = root["streams"] as? [Any] ?? []
        var videoStream: [String: Any]?
        var audioStream: [String: Any]?
        for case let stream as [String: Any] in streams {
            let kind = (string(stream["codec_type"]) ?? "").lowercased()
            switch kind {
            case "video":
                if videoStream == nil, !attachedPicture(stream) {
                    videoStream = stream
                }
            case "audio":
                if audioStream == nil {
                    audioStream = stream
                }
            default:
                break
            }
        }
        let videoRaw = videoStream.flatMap { string($0["codec_name"]) }
        let audioRaw = audioStream.flatMap { string($0["codec_name"]) }
        let format = root["format"] as? [String: Any] ?? [:]
        let width = positiveInt(videoStream?["width"]) ?? positiveInt(videoStream?["coded_width"])
        let height = positiveInt(videoStream?["height"]) ?? positiveInt(videoStream?["coded_height"])
        return ProbeReport(
            width: width,
            height: height,
            duration: duration(format: format, video: videoStream),
            videoCodecRaw: videoRaw,
            audioCodecRaw: audioRaw,
            videoCodec: videoRaw.map(FFmpegCodecNames.video),
            audioCodec: audioRaw.map(FFmpegCodecNames.audio),
            plan: PlaybackPlanner.plan(videoCodec: videoRaw, audioCodec: audioRaw)
        )
    }

    private static func attachedPicture(_ stream: [String: Any]) -> Bool {
        guard let disposition = stream["disposition"] as? [String: Any] else { return false }
        return flag(disposition["attached_pic"])
    }

    private static func duration(format: [String: Any], video: [String: Any]?) -> Double? {
        if let value = positive(format["duration"]) { return value }
        if let value = clock(format["tags"]) { return value }
        if let video {
            if let value = positive(video["duration"]) { return value }
            if let value = clock(video["tags"]) { return value }
        }
        return nil
    }

    private static func clock(_ tags: Any?) -> Double? {
        guard let tags = tags as? [String: Any] else { return nil }
        let raw = tags["DURATION"] ?? tags["duration"] ?? tags["Duration"]
        guard let text = string(raw) else { return nil }
        return FFmpegProgressParser.parseClock(text)
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        guard let number = positive(value) else { return nil }
        return Int(number)
    }

    private static func positive(_ value: Any?) -> Double? {
        guard let number = double(value), number.isFinite, number > 0 else { return nil }
        return number
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "N/A" { return nil }
        return trimmed
    }

    private static func flag(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? Int { return value != 0 }
        if let value = value as? NSNumber { return value.intValue != 0 }
        return false
    }
}

public enum FFmpegArguments {
    public static func probe(input: String) -> [String] {
        [
            "-v", "error",
            "-print_format", "json",
            "-show_streams",
            "-show_format",
            "-analyzeduration", "5000000",
            "-probesize", "5000000",
            input
        ]
    }

    /// Returns nil when the plan cannot produce a file, or when output is the original path.
    public static func make(plan: PlaybackPlan, input: String, output: String) -> [String]? {
        if PlaybackPaths.sameFile(input, output) { return nil }
        var args = ["-y", "-i", input, "-map", "0:V:0"]
        switch plan {
        case .remux(let hevcTag, let includeAudio):
            if includeAudio { args += ["-map", "0:a:0"] }
            args += ["-c", "copy"]
            if hevcTag { args += ["-tag:v", "hvc1"] }
        case .transcode(let encoder, let includeAudio):
            if includeAudio { args += ["-map", "0:a:0"] }
            args += ["-c:v", encoder.rawValue]
            if encoder == .hevc { args += ["-tag:v", "hvc1"] }
            if includeAudio { args += ["-c:a", "aac"] }
        case .unsupported:
            return nil
        }
        args += ["-movflags", "+faststart", "-progress", "pipe:1", "-nostats", output]
        return args
    }

    public static func thumbnail(input: String, output: String, seekSeconds: Double, maxSide: Int) -> [String] {
        let side = max(16, maxSide)
        return [
            "-y",
            "-ss", seconds(seekSeconds),
            "-i", input,
            "-frames:v", "1",
            "-an",
            "-vf", "scale=\(side):\(side):force_original_aspect_ratio=decrease",
            output
        ]
    }

    public static func seconds(_ value: Double) -> String {
        let safe = value.isFinite && value > 0 ? value : 0
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), safe)
    }
}

public enum PlaybackPaths {
    public static func sameFile(_ lhs: String, _ rhs: String) -> Bool {
        let left = URL(fileURLWithPath: lhs).standardizedFileURL.path
        let right = URL(fileURLWithPath: rhs).standardizedFileURL.path
        return left == right
    }
}

public struct FFmpegProgressParser: Sendable {
    public let duration: Double
    private var buffer = ""

    public init(duration: Double) {
        self.duration = duration
    }

    /// Fraction in `0...1` from the newest complete progress line, if one arrived.
    public mutating func ingest(_ text: String) -> Double? {
        buffer += text
        var latest: Double?
        while let range = buffer.range(of: "\n") {
            let line = buffer[..<range.lowerBound]
            buffer.removeSubrange(..<range.upperBound)
            if let fraction = fraction(from: String(line)) {
                latest = fraction
            }
        }
        return latest
    }

    public static func parseClock(_ value: String) -> Double? {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]),
              hours >= 0, minutes >= 0, seconds >= 0 else {
            return nil
        }
        return hours * 3600 + minutes * 60 + seconds
    }

    private func fraction(from line: String) -> Double? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let key = String(parts[0])
        let value = String(parts[1])
        switch key {
        case "out_time_us", "out_time_ms":
            // ffmpeg writes microseconds in both fields.
            guard duration > 0, let micros = Double(value) else { return nil }
            return clamp(micros / 1_000_000)
        case "out_time":
            guard duration > 0, let seconds = Self.parseClock(value) else { return nil }
            return clamp(seconds)
        case "progress":
            return value == "end" ? 1 : nil
        default:
            return nil
        }
    }

    private func clamp(_ seconds: Double) -> Double {
        min(1, max(0, seconds / duration))
    }
}

public enum PlaybackCacheKey {
    public static func filename(path: String, fileSize: Int64, modifiedAt: Date) -> String {
        let stamp = Timestamp.milliseconds(modifiedAt)
        let material = "\(path)|\(fileSize)|\(stamp)"
        return SHA256Digest.hex(Data(material.utf8)) + ".mp4"
    }
}

public struct PlaybackCacheEntry: Sendable, Equatable {
    public var path: String
    public var bytes: Int64
    public var lastUsed: Date

    public init(path: String, bytes: Int64, lastUsed: Date) {
        self.path = path
        self.bytes = bytes
        self.lastUsed = lastUsed
    }
}

public enum PlaybackCachePolicy {
    public static let defaultMaxBytes: Int64 = 5 * 1024 * 1024 * 1024

    public static func bytes(gigabytes: Double) -> Int64 {
        let clamped = min(100, max(1, gigabytes))
        return Int64(clamped * 1_073_741_824)
    }
}

public enum CacheEviction {
    /// Oldest `lastUsed` first, until the remainder fits. `protecting` is never chosen.
    public static func victims(
        entries: [PlaybackCacheEntry],
        maxBytes: Int64,
        protecting path: String? = nil
    ) -> [PlaybackCacheEntry] {
        let pool = entries.filter { $0.path != path }
        let protectedBytes = entries
            .filter { $0.path == path }
            .reduce(Int64(0)) { $0 + max(0, $1.bytes) }
        let poolBytes = pool.reduce(Int64(0)) { $0 + max(0, $1.bytes) }
        let total = protectedBytes + poolBytes
        guard total > maxBytes else { return [] }
        var overflow = total - maxBytes
        let ordered = pool.sorted { lhs, rhs in
            if lhs.lastUsed != rhs.lastUsed { return lhs.lastUsed < rhs.lastUsed }
            return lhs.path < rhs.path
        }
        var chosen: [PlaybackCacheEntry] = []
        for entry in ordered {
            if overflow <= 0 { break }
            chosen.append(entry)
            overflow -= max(0, entry.bytes)
        }
        return chosen
    }
}

public struct PlaybackCache: Sendable {
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func fileURL(path: String, fileSize: Int64, modifiedAt: Date) -> URL {
        directory.appendingPathComponent(
            PlaybackCacheKey.filename(path: path, fileSize: fileSize, modifiedAt: modifiedAt)
        )
    }

    /// Returns the cached movie and touches its modification date so LRU sees the read.
    public func existing(path: String, fileSize: Int64, modifiedAt: Date) -> URL? {
        let url = fileURL(path: path, fileSize: fileSize, modifiedAt: modifiedAt)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard Self.byteCount(attributes ?? [:]) > 0 else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    public func enforceLimit(maxBytes: Int64, protecting path: String? = nil) throws {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        var entries: [PlaybackCacheEntry] = []
        for url in urls where url.pathExtension.lowercased() == "mp4" && !url.lastPathComponent.hasSuffix(".mp4.partial") {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            entries.append(PlaybackCacheEntry(
                path: url.path,
                bytes: Int64(values.fileSize ?? 0),
                lastUsed: values.contentModificationDate ?? .distantPast
            ))
        }
        for victim in CacheEviction.victims(entries: entries, maxBytes: maxBytes, protecting: path) {
            try FileManager.default.removeItem(atPath: victim.path)
        }
    }

    private static func byteCount(_ attributes: [FileAttributeKey: Any]) -> Int64 {
        guard let value = attributes[.size] else { return 0 }
        switch value {
        case let number as NSNumber:
            return number.int64Value
        case let number as Int64:
            return number
        case let number as Int:
            return Int64(number)
        case let number as UInt64:
            return Int64(clamping: number)
        default:
            return 0
        }
    }
}
