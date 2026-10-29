import Foundation

public enum Timestamp {
    public static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    public static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}

public enum CalendarParts {
    public static var gregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    public static func yearMonth(of date: Date) -> (year: Int, month: Int)? {
        let parts = gregorian.dateComponents([.year, .month], from: date)
        guard let year = parts.year, let month = parts.month else { return nil }
        return (year, month)
    }
}

public struct EXIFDateInterpretation: Sendable, Equatable {
    public var date: Date
    /// True when the EXIF year was above 2400 and treated as a Buddhist-era year.
    public var correctedFromBuddhistEra: Bool
    public var originalYear: Int
    public var storedYear: Int

    public init(date: Date, correctedFromBuddhistEra: Bool, originalYear: Int, storedYear: Int) {
        self.date = date
        self.correctedFromBuddhistEra = correctedFromBuddhistEra
        self.originalYear = originalYear
        self.storedYear = storedYear
    }
}

public enum EXIFDateParser {
    /// Years above this are treated as Buddhist Era (Gregorian + 543).
    public static let buddhistEraThreshold = 2400
    public static let buddhistEraOffset = 543

    /// Parses an EXIF wall-clock string (`yyyy:MM:dd HH:mm:ss`) into a Gregorian date.
    public static func parse(_ raw: String) -> Date? {
        interpret(raw)?.date
    }

    public static func interpret(_ raw: String) -> EXIFDateInterpretation? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = Array(trimmed)
        guard scalars.count >= 19 else { return nil }
        func number(_ start: Int, _ length: Int) -> Int? {
            let piece = String(scalars[start..<(start + length)])
            return Int(piece)
        }
        guard
            scalars[4] == ":", scalars[7] == ":", scalars[10] == " ",
            scalars[13] == ":", scalars[16] == ":",
            let parsedYear = number(0, 4),
            let month = number(5, 2),
            let day = number(8, 2),
            let hour = number(11, 2),
            let minute = number(14, 2),
            let second = number(17, 2),
            (1...12).contains(month),
            (1...31).contains(day),
            (0...23).contains(hour),
            (0...59).contains(minute),
            (0...60).contains(second)
        else {
            return nil
        }
        let corrected = parsedYear > buddhistEraThreshold
        let year = corrected ? parsedYear - buddhistEraOffset : parsedYear
        guard year > 0 else { return nil }
        var components = DateComponents()
        components.calendar = CalendarParts.gregorian
        components.timeZone = .current
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let date = components.date else { return nil }
        return EXIFDateInterpretation(
            date: date,
            correctedFromBuddhistEra: corrected,
            originalYear: parsedYear,
            storedYear: year
        )
    }

    /// Gregorian EXIF string, suitable to write back into a file.
    public static func format(_ date: Date) -> String {
        let parts = CalendarParts.gregorian.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d:%02d:%02d %02d:%02d:%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }
}
