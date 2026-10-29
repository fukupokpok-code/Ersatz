#if os(macOS)
import ErsatzCore
import SwiftUI

enum Theme {
    static let safelight = Color(red: 0.62, green: 0.15, blue: 0.12)
}

enum ViewMode: String, CaseIterable, Identifiable {
    case grid
    case list
    var id: String { rawValue }
}

enum LibraryFilter: Hashable {
    case all
    case folder(Int64, directory: String?)
    case year(Int)
    case month(Int, Int)
    case unknownDate
    case kind(MediaType)
    case screenshots
    case qrCodes
    case bankSlips
    case blurry
    case duplicates
    case buddhistDates

    var query: MediaQuery {
        var query = MediaQuery()
        switch self {
        case .all, .duplicates:
            break
        case .folder(let id, let directory):
            query.folderID = id
            query.directoryPrefix = directory
        case .year(let year):
            query.year = year
        case .month(let year, let month):
            query.year = year
            query.month = month
        case .unknownDate:
            query.unknownDateOnly = true
        case .kind(let kind):
            query.kind = kind
        case .screenshots:
            query.screenshotsOnly = true
        case .qrCodes:
            query.qrOnly = true
        case .bankSlips:
            query.bankSlipsOnly = true
        case .blurry:
            query.blurryOnly = true
        case .buddhistDates:
            query.correctedDatesOnly = true
        }
        return query
    }
}

struct YearGroup: Identifiable {
    var year: Int
    var count: Int
    var months: [DateBucket]
    var id: Int { year }
}

enum DisplayDate {
    static func dateTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

extension MediaType {
    var symbolName: String {
        switch self {
        case .photo: "photo"
        case .raw: "camera.aperture"
        case .video: "film"
        case .audio: "waveform"
        }
    }

    var pluralTitle: String {
        switch self {
        case .photo: "Photos"
        case .raw: "RAW"
        case .video: "Videos"
        case .audio: "Audio"
        }
    }
}
#endif
