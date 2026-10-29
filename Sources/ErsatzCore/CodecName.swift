import Foundation

public enum CodecName {
    public static func video(fourCC: String) -> String {
        switch normalize(fourCC) {
        case "avc1", "avc3", "h264", "x264":
            return "H.264"
        case "hvc1", "hev1", "hevc":
            return "HEVC"
        case "vvc1", "vvi1":
            return "H.266"
        case "apch":
            return "ProRes 422 HQ"
        case "apcn":
            return "ProRes 422"
        case "apcs":
            return "ProRes 422 LT"
        case "apco":
            return "ProRes 422 Proxy"
        case "ap4h":
            return "ProRes 4444"
        case "ap4x":
            return "ProRes 4444 XQ"
        case "jpeg", "mjpa", "mjpb":
            return "Motion JPEG"
        case "mp4v", "xvid", "divx":
            return "MPEG-4"
        case "h263", "s263":
            return "H.263"
        case "vp09", "vp9":
            return "VP9"
        case "av01":
            return "AV1"
        case "png":
            return "PNG"
        default:
            return display(fourCC)
        }
    }

    public static func audio(fourCC: String) -> String {
        switch normalize(fourCC) {
        case "mp4a", "aac", "paac":
            return "AAC"
        case "alac":
            return "Apple Lossless"
        case "flac":
            return "FLAC"
        case "ac-3", "sac3":
            return "AC-3"
        case "ec-3":
            return "E-AC-3"
        case "opus":
            return "Opus"
        case "samr":
            return "AMR"
        case "twos", "sowt", "lpcm", "raw", "in24", "in32", "fl32", "fl64", "pcm":
            return "PCM"
        case "mp3", ".mp3":
            return "MP3"
        default:
            return display(fourCC)
        }
    }

    public static func camera(make: String?, model: String?) -> String? {
        let make = cleaned(make)
        let model = cleaned(model)
        switch (make, model) {
        case let (make?, model?):
            let brand = make.split(separator: " ").first.map(String.init)?.lowercased() ?? make.lowercased()
            let modelKey = model.lowercased()
            if modelKey.hasPrefix(make.lowercased()) || modelKey.hasPrefix(brand) {
                return model
            }
            return "\(make) \(model)"
        case let (_, model?):
            return model
        case let (make?, nil):
            return make
        default:
            return nil
        }
    }

    private static func normalize(_ fourCC: String) -> String {
        fourCC.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func display(_ fourCC: String) -> String {
        let trimmed = fourCC.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return fourCC }
        return trimmed.uppercased()
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        return trimmed.isEmpty ? nil : trimmed
    }
}
