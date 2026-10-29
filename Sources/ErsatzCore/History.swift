import Foundation

public enum CheckpointFileKind: String, Sendable, Codable {
    case metadata
    case content
    case deletion
}

public struct Checkpoint: Sendable, Equatable, Hashable, Identifiable {
    public var id: Int64
    public var createdAt: Date
    public var action: String
    public var fileCount: Int
    public var note: String?

    public init(id: Int64, createdAt: Date, action: String, fileCount: Int, note: String?) {
        self.id = id
        self.createdAt = createdAt
        self.action = action
        self.fileCount = fileCount
        self.note = note
    }
}

public struct CheckpointFile: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var checkpointID: Int64
    public var path: String
    public var kind: CheckpointFileKind
    public var originalMetadata: String?
    public var backupPath: String?
    public var backupBytes: Int64
    public var trashURL: String?

    public init(
        id: Int64,
        checkpointID: Int64,
        path: String,
        kind: CheckpointFileKind,
        originalMetadata: String?,
        backupPath: String?,
        backupBytes: Int64,
        trashURL: String?
    ) {
        self.id = id
        self.checkpointID = checkpointID
        self.path = path
        self.kind = kind
        self.originalMetadata = originalMetadata
        self.backupPath = backupPath
        self.backupBytes = backupBytes
        self.trashURL = trashURL
    }
}

public struct CheckpointFileDraft: Sendable {
    public var path: String
    public var kind: CheckpointFileKind
    public var originalMetadata: String?
    public var backupPath: String?
    public var backupBytes: Int64
    public var trashURL: String?

    public init(
        path: String,
        kind: CheckpointFileKind,
        originalMetadata: String? = nil,
        backupPath: String? = nil,
        backupBytes: Int64 = 0,
        trashURL: String? = nil
    ) {
        self.path = path
        self.kind = kind
        self.originalMetadata = originalMetadata
        self.backupPath = backupPath
        self.backupBytes = backupBytes
        self.trashURL = trashURL
    }
}

public struct ActivityEntry: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var createdAt: Date
    public var action: String
    public var path: String
    public var oldValue: String?
    public var newValue: String?
    public var checkpointID: Int64?
    public var success: Bool
    public var restorable: Bool

    public init(
        id: Int64,
        createdAt: Date,
        action: String,
        path: String,
        oldValue: String?,
        newValue: String?,
        checkpointID: Int64?,
        success: Bool,
        restorable: Bool
    ) {
        self.id = id
        self.createdAt = createdAt
        self.action = action
        self.path = path
        self.oldValue = oldValue
        self.newValue = newValue
        self.checkpointID = checkpointID
        self.success = success
        self.restorable = restorable
    }

    public var line: String {
        let stamp = ActivityLogFile.stamp(createdAt)
        let outcome = success ? "ok" : "failed"
        let restore = restorable ? "restorable" : "not-restorable"
        let checkpoint = checkpointID.map(String.init) ?? "-"
        return [
            stamp,
            action,
            path,
            "\(oldValue ?? "-") -> \(newValue ?? "-")",
            "checkpoint=\(checkpoint)",
            outcome,
            restore
        ].joined(separator: "\t")
    }
}

public final class ActivityLogFile: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()
    private let maxBytes: Int

    public init(directory: URL, maxBytes: Int = 10 * 1024 * 1024) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("activity.log")
        self.maxBytes = maxBytes
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        }
    }

    public func append(_ entry: ActivityEntry) throws {
        try locked {
            try rotateUnlocked()
            let line = entry.line + "\n"
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        }
    }

    public func rotateIfNeeded() throws {
        try locked { try rotateUnlocked() }
    }

    private func rotateUnlocked() throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        guard size >= maxBytes else { return }
        let archived = fileURL.deletingPathExtension().appendingPathExtension("1.log")
        if FileManager.default.fileExists(atPath: archived.path) {
            try FileManager.default.removeItem(at: archived)
        }
        try FileManager.default.moveItem(at: fileURL, to: archived)
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())
    }

    private func locked(_ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try body()
    }

    public static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

public enum CheckpointStore {
    /// Copies a file into the checkpoint directory. `copyItem` clones on APFS.
    public static func backup(original: URL, directory: URL, checkpointID: Int64) throws -> (url: URL, bytes: Int64) {
        let folder = directory.appendingPathComponent(String(checkpointID), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var destination = folder.appendingPathComponent(original.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(UUID().uuidString)-\(original.lastPathComponent)")
        }
        try FileManager.default.copyItem(at: original, to: destination)
        let bytes = Int64((try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0)
        return (destination, bytes)
    }
}

public struct AnalysisUpdate: Sendable {
    public var mediaID: Int64
    public var partialHash: String?
    public var contentHash: String?
    public var perceptualHash: UInt64?
    public var sharpness: Double?
    public var isScreenshot: Bool
    public var hasQR: Bool
    public var isBankSlip: Bool
    public var analyzedMTime: Int64

    public init(
        mediaID: Int64,
        partialHash: String?,
        contentHash: String?,
        perceptualHash: UInt64?,
        sharpness: Double?,
        isScreenshot: Bool,
        hasQR: Bool,
        isBankSlip: Bool,
        analyzedMTime: Int64
    ) {
        self.mediaID = mediaID
        self.partialHash = partialHash
        self.contentHash = contentHash
        self.perceptualHash = perceptualHash
        self.sharpness = sharpness
        self.isScreenshot = isScreenshot
        self.hasQR = hasQR
        self.isBankSlip = isBankSlip
        self.analyzedMTime = analyzedMTime
    }
}

public struct MetadataUpdate: Sendable {
    public var path: String
    public var metadata: MediaMetadata
    public var dateCorrected: Bool

    public init(path: String, metadata: MediaMetadata, dateCorrected: Bool) {
        self.path = path
        self.metadata = metadata
        self.dateCorrected = dateCorrected
    }
}
