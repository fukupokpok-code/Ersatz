import Foundation

public enum MediaType: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case photo
    case raw
    case video
    case audio

    public var label: String {
        switch self {
        case .photo: "Photo"
        case .raw: "RAW"
        case .video: "Video"
        case .audio: "Audio"
        }
    }
}

public enum FormatNames {
    public static func preferred(forExtension ext: String) -> String {
        let key = ext.lowercased()
        if let known = names[key] { return known }
        if key.isEmpty { return "File" }
        return key.uppercased()
    }

    private static let names: [String: String] = [
        "jpg": "JPEG", "jpeg": "JPEG", "jpe": "JPEG", "jfif": "JPEG",
        "png": "PNG", "gif": "GIF", "tif": "TIFF", "tiff": "TIFF",
        "heic": "HEIC", "heif": "HEIF", "heics": "HEIC", "avif": "AVIF",
        "webp": "WebP", "bmp": "BMP",
        "dng": "DNG", "cr2": "CR2", "cr3": "CR3", "nef": "NEF", "nrw": "NEF",
        "arw": "ARW", "srf": "ARW", "sr2": "ARW", "raf": "RAF", "orf": "ORF",
        "rw2": "RW2", "pef": "PEF", "srw": "SRW", "x3f": "X3F",
        "mov": "QuickTime", "mp4": "MP4", "m4v": "MP4", "avi": "AVI",
        "mkv": "MKV", "mpg": "MPEG", "mpeg": "MPEG", "webm": "WebM",
        "flv": "FLV", "wmv": "WMV",
        "m4a": "M4A", "mp3": "MP3", "wav": "WAV", "aif": "AIFF", "aiff": "AIFF",
        "aifc": "AIFF", "flac": "FLAC", "aac": "AAC", "ogg": "Ogg", "caf": "CAF"
    ]
}

public enum MediaTypeDetector {
    public static func kind(for path: String) -> MediaType? {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if photo.contains(ext) { return .photo }
        if raw.contains(ext) { return .raw }
        if video.contains(ext) { return .video }
        if audio.contains(ext) { return .audio }
        return nil
    }

    public static let photo: Set<String> = [
        "jpg", "jpeg", "jpe", "jfif", "png", "gif", "tif", "tiff",
        "heic", "heif", "heics", "webp", "bmp", "avif"
    ]

    public static let raw: Set<String> = [
        "dng", "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf",
        "rw2", "pef", "srw", "x3f", "3fr", "fff", "iiq", "rwl", "erf", "kdc",
        "dcr", "mos", "raw", "bay", "mef", "mrw"
    ]

    public static let video: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "mpg", "mpeg", "wmv", "webm",
        "mts", "m2ts", "ts", "3gp", "vob", "flv"
    ]

    public static let audio: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aiff", "aif", "aifc", "flac", "ogg",
        "oga", "caf", "wma", "alac", "opus"
    ]

    static let isoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "m4a", "m4b", "heic", "heif", "heics", "avif", "cr3", "3gp"
    ]
}
