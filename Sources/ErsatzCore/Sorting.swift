import Foundation

public enum SortKey: String, Sendable, CaseIterable, Identifiable, Equatable {
    case name
    case dateTaken
    case dateModified
    case fileSize
    case resolution
    case codec
    case fileType

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .name: "Name"
        case .dateTaken: "Date Taken"
        case .dateModified: "Date Modified"
        case .fileSize: "File Size"
        case .resolution: "Resolution"
        case .codec: "Codec"
        case .fileType: "File Type"
        }
    }
}

public enum SortDirection: String, Sendable, CaseIterable, Identifiable, Equatable {
    case ascending
    case descending

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ascending: "Ascending"
        case .descending: "Descending"
        }
    }
}

public enum FilenameOrder {
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = chunks(lhs)
        let right = chunks(rhs)
        let count = min(left.count, right.count)
        for index in 0..<count {
            let result = compareChunk(left[index], right[index])
            if result != .orderedSame { return result }
        }
        if left.count == right.count { return .orderedSame }
        return left.count < right.count ? .orderedAscending : .orderedDescending
    }

    public static func less(_ lhs: String, _ rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    private struct Chunk {
        var isNumber: Bool
        var text: String
        var number: UInt64?
    }

    private static func chunks(_ value: String) -> [Chunk] {
        var result: [Chunk] = []
        var current = ""
        var currentIsNumber: Bool?
        func flush() {
            guard !current.isEmpty, let isNumber = currentIsNumber else { return }
            if isNumber {
                result.append(Chunk(isNumber: true, text: current, number: UInt64(current)))
            } else {
                result.append(Chunk(isNumber: false, text: current.lowercased(), number: nil))
            }
            current = ""
        }
        for character in value {
            let isNumber = character.isNumber
            if currentIsNumber != isNumber {
                flush()
                currentIsNumber = isNumber
            }
            current.append(character)
        }
        flush()
        return result
    }

    private static func compareChunk(_ lhs: Chunk, _ rhs: Chunk) -> ComparisonResult {
        if lhs.isNumber, rhs.isNumber {
            switch (lhs.number, rhs.number) {
            case let (left?, right?) where left != right:
                return left < right ? .orderedAscending : .orderedDescending
            case (nil, _?):
                return .orderedDescending
            case (_?, nil):
                return .orderedAscending
            default:
                if lhs.text.count != rhs.text.count {
                    return lhs.text.count < rhs.text.count ? .orderedAscending : .orderedDescending
                }
                if lhs.text == rhs.text { return .orderedSame }
                return lhs.text < rhs.text ? .orderedAscending : .orderedDescending
            }
        }
        if lhs.text == rhs.text { return .orderedSame }
        return lhs.text < rhs.text ? .orderedAscending : .orderedDescending
    }
}

public enum MediaSorter {
    /// Missing values sort last in both directions. Equal keys fall back to filename, then id.
    public static func sorted(
        _ items: [MediaItem],
        key: SortKey,
        direction: SortDirection
    ) -> [MediaItem] {
        items.sorted { lhs, rhs in
            less(lhs, rhs, key: key, descending: direction == .descending)
        }
    }

    private static func less(_ lhs: MediaItem, _ rhs: MediaItem, key: SortKey, descending: Bool) -> Bool {
        let primary: (equal: Bool, less: Bool)
        switch key {
        case .name:
            let result = FilenameOrder.compare(lhs.filename, rhs.filename)
            if result == .orderedSame {
                primary = (true, false)
            } else if descending {
                primary = (false, result == .orderedDescending)
            } else {
                primary = (false, result == .orderedAscending)
            }
        case .dateTaken:
            primary = lessOptional(lhs.dateTaken, rhs.dateTaken, descending: descending)
        case .dateModified:
            primary = lessOptional(lhs.modifiedAt, rhs.modifiedAt, descending: descending)
        case .fileSize:
            primary = lessOptional(lhs.fileSize, rhs.fileSize, descending: descending)
        case .resolution:
            primary = lessOptional(lhs.pixelCount, rhs.pixelCount, descending: descending)
        case .codec:
            primary = lessOptional(lhs.displayCodec?.lowercased(), rhs.displayCodec?.lowercased(), descending: descending)
        case .fileType:
            primary = lessOptional(lhs.fileTypeSortKey, rhs.fileTypeSortKey, descending: descending)
        }
        if !primary.equal { return primary.less }
        let name = FilenameOrder.compare(lhs.filename, rhs.filename)
        if name != .orderedSame { return name == .orderedAscending }
        return lhs.id < rhs.id
    }

    private static func lessOptional<T: Comparable>(
        _ lhs: T?,
        _ rhs: T?,
        descending: Bool
    ) -> (equal: Bool, less: Bool) {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            if lhs == rhs { return (true, false) }
            return (false, descending ? lhs > rhs : lhs < rhs)
        case (nil, nil):
            return (true, false)
        case (_?, nil):
            return (false, true)
        case (nil, _?):
            return (false, false)
        }
    }
}
