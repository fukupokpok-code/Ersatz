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

/// A running smart-filter or Analyze Library pass, shown with a Stop button.
struct AnalysisStatus: Equatable {
    var parts: AnalysisParts
    var title: String
    var done: Int
    var total: Int

    init(demand: AnalysisDemand, done: Int, total: Int) {
        parts = demand.parts
        title = demand.title
        self.done = done
        self.total = total
    }

    var fraction: Double? { total > 0 ? Double(done) / Double(total) : nil }
}

enum LibraryFilter: Hashable, Sendable {
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

    /// What this filter needs analyzed before it can show anything. Empty for plain places.
    var analysisParts: AnalysisParts {
        switch self {
        case .screenshots: return .screenshot
        case .qrCodes: return .qr
        case .bankSlips: return [.qr, .bankSlip]
        case .blurry: return .sharpness
        case .duplicates: return .duplicates
        default: return []
        }
    }

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
