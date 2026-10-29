import Foundation

public enum ByteCountText {
    /// 1024-based size text. Pass a locale in tests so the decimal separator stays stable.
    public static func string(bytes: Int64, locale: Locale = .current) -> String {
        let sign = bytes < 0 ? "-" : ""
        var amount = Double(abs(bytes))
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var index = 0
        while amount >= 1024, index < units.count - 1 {
            amount /= 1024
            index += 1
        }
        if index == 0 {
            return "\(sign)\(Int(amount)) \(units[index])"
        }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        formatter.numberStyle = .decimal
        let number = formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.1f", amount)
        return "\(sign)\(number) \(units[index])"
    }
}
