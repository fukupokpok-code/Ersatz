import Foundation

public enum AppPaths {
    /// Where the catalog, caches and log go. Nil (the normal case) means the usual
    /// `~/Library` folders; a developer data directory (`DevLaunchOptions`) puts
    /// everything under that one folder instead.
    public static var dataRoot: URL? { DevLaunchOptions.current.dataDirectory }

    public static func databaseURL(fileManager: FileManager = .default, root: URL? = dataRoot) throws -> URL {
        let directory: URL
        if let root {
            directory = root
        } else {
            let base = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            directory = base.appendingPathComponent("Ersatz", isDirectory: true)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("library.sqlite")
    }

    public static func thumbnailCacheURL(fileManager: FileManager = .default, root: URL? = dataRoot) throws -> URL {
        try cacheDirectory("Thumbnails", fileManager: fileManager, root: root)
    }

    /// Remuxed and transcoded playback files. Originals are never written here.
    public static func playbackCacheURL(fileManager: FileManager = .default, root: URL? = dataRoot) throws -> URL {
        try cacheDirectory("Playback", fileManager: fileManager, root: root)
    }

    /// The activity log folder: `~/Library/Logs/Ersatz`, or `Logs` under a data directory.
    /// Not created here; `ActivityLogFile` creates it.
    public static func logsDirectory(root: URL? = dataRoot, home: String = NSHomeDirectory()) -> URL {
        if let root {
            return root.appendingPathComponent("Logs", isDirectory: true)
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Logs/Ersatz", isDirectory: true)
    }

    private static func cacheDirectory(_ name: String, fileManager: FileManager, root: URL?) throws -> URL {
        let directory: URL
        if let root {
            directory = root
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
        } else {
            let base = try fileManager.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            directory = base
                .appendingPathComponent("Ersatz", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

public struct ThumbnailCache: Sendable {
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func fileURL(itemID: Int64, token: String) -> URL {
        directory.appendingPathComponent("\(itemID)-\(Self.safe(token)).jpg")
    }

    public func load(itemID: Int64, token: String) -> Data? {
        try? Data(contentsOf: fileURL(itemID: itemID, token: token))
    }

    public func store(_ data: Data, itemID: Int64, token: String) throws {
        try data.write(to: fileURL(itemID: itemID, token: token), options: .atomic)
    }

    public func remove(itemID: Int64) throws {
        let prefix = "\(itemID)-"
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            try FileManager.default.removeItem(at: file)
        }
    }

    private static func safe(_ token: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let scalars = token.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let cleaned = String(scalars)
        return cleaned.isEmpty ? "thumb" : cleaned
    }
}
