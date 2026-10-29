import Foundation

public struct MediaMetadata: Sendable, Equatable {
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var duration: Double?
    public var videoCodec: String?
    public var audioCodec: String?
    public var cameraModel: String?
    public var dateTaken: Date?
    public var dateCorrectedFromBuddhistEra: Bool
    public var formatName: String?
    public var orientation: Int?

    public init(
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        duration: Double? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        cameraModel: String? = nil,
        dateTaken: Date? = nil,
        dateCorrectedFromBuddhistEra: Bool = false,
        formatName: String? = nil,
        orientation: Int? = nil
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.cameraModel = cameraModel
        self.dateTaken = dateTaken
        self.dateCorrectedFromBuddhistEra = dateCorrectedFromBuddhistEra
        self.formatName = formatName
        self.orientation = orientation
    }

    /// Fills any field this value does not already have.
    public mutating func fillMissing(from other: MediaMetadata) {
        if pixelWidth == nil { pixelWidth = other.pixelWidth }
        if pixelHeight == nil { pixelHeight = other.pixelHeight }
        if duration == nil { duration = other.duration }
        if videoCodec == nil { videoCodec = other.videoCodec }
        if audioCodec == nil { audioCodec = other.audioCodec }
        if cameraModel == nil { cameraModel = other.cameraModel }
        if dateTaken == nil {
            dateTaken = other.dateTaken
            dateCorrectedFromBuddhistEra = other.dateCorrectedFromBuddhistEra
        }
        if formatName == nil { formatName = other.formatName }
        if orientation == nil { orientation = other.orientation }
    }

    /// Prefers values from `other` when they are present. Used when a platform reader is authoritative.
    public mutating func overlay(_ other: MediaMetadata) {
        if let value = other.pixelWidth { pixelWidth = value }
        if let value = other.pixelHeight { pixelHeight = value }
        if let value = other.duration { duration = value }
        if let value = other.videoCodec { videoCodec = value }
        if let value = other.audioCodec { audioCodec = value }
        if let value = other.cameraModel { cameraModel = value }
        if let value = other.dateTaken {
            dateTaken = value
            dateCorrectedFromBuddhistEra = other.dateCorrectedFromBuddhistEra
        }
        if let value = other.formatName { formatName = value }
        if let value = other.orientation { orientation = value }
    }

    public mutating func applyOrientationSwap() {
        guard let orientation, (5...8).contains(orientation) else { return }
        swap(&pixelWidth, &pixelHeight)
    }
}

public struct MediaItem: Sendable, Equatable, Hashable, Identifiable {
    public var id: Int64
    public var folderID: Int64
    public var path: String
    public var relativePath: String
    public var filename: String
    public var parentRelative: String
    public var kind: MediaType
    public var fileSize: Int64
    public var createdAt: Date?
    public var modifiedAt: Date
    public var dateTaken: Date?
    public var takenYear: Int?
    public var takenMonth: Int?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var duration: Double?
    public var videoCodec: String?
    public var audioCodec: String?
    public var cameraModel: String?
    public var formatName: String?
    public var indexedAt: Date
    public var dateCorrected: Bool
    public var metadataReady: Bool

    public init(
        id: Int64,
        folderID: Int64,
        path: String,
        relativePath: String,
        filename: String,
        parentRelative: String,
        kind: MediaType,
        fileSize: Int64,
        createdAt: Date?,
        modifiedAt: Date,
        dateTaken: Date?,
        takenYear: Int?,
        takenMonth: Int?,
        pixelWidth: Int?,
        pixelHeight: Int?,
        duration: Double?,
        videoCodec: String?,
        audioCodec: String?,
        cameraModel: String?,
        formatName: String?,
        indexedAt: Date,
        dateCorrected: Bool = false,
        metadataReady: Bool = true
    ) {
        self.id = id
        self.folderID = folderID
        self.path = path
        self.relativePath = relativePath
        self.filename = filename
        self.parentRelative = parentRelative
        self.kind = kind
        self.fileSize = fileSize
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.dateTaken = dateTaken
        self.takenYear = takenYear
        self.takenMonth = takenMonth
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.cameraModel = cameraModel
        self.formatName = formatName
        self.indexedAt = indexedAt
        self.dateCorrected = dateCorrected
        self.metadataReady = metadataReady
    }

    public var pixelCount: Int64? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
        return Int64(pixelWidth) * Int64(pixelHeight)
    }

    public var resolutionLabel: String? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
        return "\(pixelWidth)×\(pixelHeight)"
    }

    /// Kind first, then format, so JPEG photos sort apart from JPEG motion and from HEIC.
    public var fileTypeSortKey: String {
        let order: String
        switch kind {
        case .photo: order = "0"
        case .raw: order = "1"
        case .video: order = "2"
        case .audio: order = "3"
        }
        let format = (formatName ?? "").lowercased()
        return "\(order) \(format) \(filename.lowercased())"
    }

    public var displayCodec: String? {
        if let videoCodec, !videoCodec.isEmpty { return videoCodec }
        if let audioCodec, !audioCodec.isEmpty { return audioCodec }
        if let formatName, !formatName.isEmpty { return formatName }
        return nil
    }

    public var durationLabel: String? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        let total = Int(duration.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

public struct LibraryFolder: Sendable, Equatable, Identifiable, Hashable {
    public var id: Int64
    public var path: String
    public var bookmark: Data?
    public var displayName: String
    public var addedAt: Date

    public init(id: Int64, path: String, bookmark: Data?, displayName: String, addedAt: Date) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.displayName = displayName
        self.addedAt = addedAt
    }
}

public struct NewMedia: Sendable, Equatable {
    public var folderID: Int64
    public var path: String
    public var relativePath: String
    public var filename: String
    public var parentRelative: String
    public var kind: MediaType
    public var fileSize: Int64
    public var createdAt: Date?
    public var modifiedAt: Date
    public var dateTaken: Date?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var duration: Double?
    public var videoCodec: String?
    public var audioCodec: String?
    public var cameraModel: String?
    public var formatName: String?
    public var dateCorrected: Bool
    public var metadataReady: Bool

    public init(
        folderID: Int64,
        path: String,
        relativePath: String,
        filename: String,
        parentRelative: String,
        kind: MediaType,
        fileSize: Int64,
        createdAt: Date?,
        modifiedAt: Date,
        dateTaken: Date? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        duration: Double? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        cameraModel: String? = nil,
        formatName: String? = nil,
        dateCorrected: Bool = false,
        metadataReady: Bool = false
    ) {
        self.folderID = folderID
        self.path = path
        self.relativePath = relativePath
        self.filename = filename
        self.parentRelative = parentRelative
        self.kind = kind
        self.fileSize = fileSize
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.dateTaken = dateTaken
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.cameraModel = cameraModel
        self.formatName = formatName
        self.dateCorrected = dateCorrected
        self.metadataReady = metadataReady
    }
}

public struct FileSnapshot: Sendable, Equatable {
    public var fileSize: Int64
    public var modifiedAtMS: Int64
    public var metadataReady: Bool

    public init(fileSize: Int64, modifiedAtMS: Int64, metadataReady: Bool) {
        self.fileSize = fileSize
        self.modifiedAtMS = modifiedAtMS
        self.metadataReady = metadataReady
    }
}

public struct MediaQuery: Sendable, Equatable {
    public var folderID: Int64?
    public var directoryPrefix: String?
    /// When set with `directoryPrefix`, match that directory and its descendants.
    public var kind: MediaType?
    public var year: Int?
    public var month: Int?
    public var unknownDateOnly: Bool
    public var screenshotsOnly: Bool
    public var qrOnly: Bool
    public var bankSlipsOnly: Bool
    public var blurryOnly: Bool
    public var blurryThreshold: Double
    public var correctedDatesOnly: Bool

    public init(
        folderID: Int64? = nil,
        directoryPrefix: String? = nil,
        kind: MediaType? = nil,
        year: Int? = nil,
        month: Int? = nil,
        unknownDateOnly: Bool = false,
        screenshotsOnly: Bool = false,
        qrOnly: Bool = false,
        bankSlipsOnly: Bool = false,
        blurryOnly: Bool = false,
        blurryThreshold: Double = 50,
        correctedDatesOnly: Bool = false
    ) {
        self.folderID = folderID
        self.directoryPrefix = directoryPrefix
        self.kind = kind
        self.year = year
        self.month = month
        self.unknownDateOnly = unknownDateOnly
        self.screenshotsOnly = screenshotsOnly
        self.qrOnly = qrOnly
        self.bankSlipsOnly = bankSlipsOnly
        self.blurryOnly = blurryOnly
        self.blurryThreshold = blurryThreshold
        self.correctedDatesOnly = correctedDatesOnly
    }
}

public struct DateBucket: Sendable, Equatable, Hashable {
    public var year: Int
    public var month: Int
    public var count: Int

    public init(year: Int, month: Int, count: Int) {
        self.year = year
        self.month = month
        self.count = count
    }
}

public struct DirectoryCount: Sendable, Equatable, Hashable {
    public var parentRelative: String
    public var count: Int

    public init(parentRelative: String, count: Int) {
        self.parentRelative = parentRelative
        self.count = count
    }
}

public struct LibrarySummary: Sendable, Equatable {
    public var totalCount: Int
    public var unknownDateCount: Int
    public var kindCounts: [MediaType: Int]
    public var dateBuckets: [DateBucket]
    public var folders: [LibraryFolder]
    public var folderCounts: [Int64: Int]
    public var directoryCounts: [Int64: [DirectoryCount]]
    public var screenshotCount: Int
    public var qrCount: Int
    public var bankSlipCount: Int
    public var buddhistDateCount: Int

    public init(
        totalCount: Int,
        unknownDateCount: Int,
        kindCounts: [MediaType: Int],
        dateBuckets: [DateBucket],
        folders: [LibraryFolder],
        folderCounts: [Int64: Int],
        directoryCounts: [Int64: [DirectoryCount]],
        screenshotCount: Int = 0,
        qrCount: Int = 0,
        bankSlipCount: Int = 0,
        buddhistDateCount: Int = 0
    ) {
        self.totalCount = totalCount
        self.unknownDateCount = unknownDateCount
        self.kindCounts = kindCounts
        self.dateBuckets = dateBuckets
        self.folders = folders
        self.folderCounts = folderCounts
        self.directoryCounts = directoryCounts
        self.screenshotCount = screenshotCount
        self.qrCount = qrCount
        self.bankSlipCount = bankSlipCount
        self.buddhistDateCount = buddhistDateCount
    }
}

public struct IndexProgress: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case scanning
        case cataloging
        case reading
        case analyzing
        case finished
    }

    public var phase: Phase
    public var filesSeen: Int
    public var filesParsed: Int
    public var filesSkipped: Int
    public var filesRemoved: Int
    public var currentPath: String?

    public init(
        phase: Phase,
        filesSeen: Int = 0,
        filesParsed: Int = 0,
        filesSkipped: Int = 0,
        filesRemoved: Int = 0,
        currentPath: String? = nil
    ) {
        self.phase = phase
        self.filesSeen = filesSeen
        self.filesParsed = filesParsed
        self.filesSkipped = filesSkipped
        self.filesRemoved = filesRemoved
        self.currentPath = currentPath
    }

    public var fraction: Double? {
        guard phase == .reading || phase == .analyzing, filesSeen > 0 else { return nil }
        return Double(filesParsed + filesSkipped) / Double(filesSeen)
    }
}

public struct IndexResult: Sendable, Equatable {
    public var filesSeen: Int
    public var filesParsed: Int
    public var filesSkipped: Int
    public var filesRemoved: Int

    public init(filesSeen: Int, filesParsed: Int, filesSkipped: Int, filesRemoved: Int) {
        self.filesSeen = filesSeen
        self.filesParsed = filesParsed
        self.filesSkipped = filesSkipped
        self.filesRemoved = filesRemoved
    }
}
