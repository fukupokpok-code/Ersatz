import Foundation

public struct ScannedFile: Sendable, Equatable {
    public var url: URL
    public var relativePath: String
    public var filename: String
    public var parentRelative: String
    public var kind: MediaType
    public var fileSize: Int64
    public var createdAt: Date?
    public var modifiedAt: Date

    public init(
        url: URL,
        relativePath: String,
        filename: String,
        parentRelative: String,
        kind: MediaType,
        fileSize: Int64,
        createdAt: Date?,
        modifiedAt: Date
    ) {
        self.url = url
        self.relativePath = relativePath
        self.filename = filename
        self.parentRelative = parentRelative
        self.kind = kind
        self.fileSize = fileSize
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

public enum ScanError: Error, LocalizedError, Equatable {
    case missing(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let path):
            return "Folder not found: \(path)"
        case .unreadable(let path):
            return "Can't read folder: \(path)"
        }
    }
}

public struct FileScanner: Sendable {
    public init() {}

    public func enumerate(root: URL) throws -> [ScannedFile] {
        let fileManager = FileManager()
        var isDirectory: ObjCBool = false
        let rootURL = root.standardizedFileURL
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ScanError.missing(rootURL.path)
        }
        guard fileManager.isReadableFile(atPath: rootURL.path) else {
            throw ScanError.unreadable(rootURL.path)
        }
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw ScanError.unreadable(rootURL.path)
        }
        var files: [ScannedFile] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true { continue }
            guard values?.isRegularFile == true else { continue }
            let filename = url.lastPathComponent
            if filename.hasPrefix(".") || filename.hasPrefix("._") { continue }
            guard let kind = MediaTypeDetector.kind(for: url.path) else { continue }
            guard let relative = relativePath(file: url, root: rootURL) else { continue }
            let parent: String
            if let slash = relative.lastIndex(of: "/") {
                parent = String(relative[..<slash])
            } else {
                parent = ""
            }
            let size = Int64(values?.fileSize ?? 0)
            let modified = values?.contentModificationDate ?? Date()
            files.append(
                ScannedFile(
                    url: url.standardizedFileURL,
                    relativePath: relative,
                    filename: filename,
                    parentRelative: parent,
                    kind: kind,
                    fileSize: size,
                    createdAt: values?.creationDate,
                    modifiedAt: modified
                )
            )
        }
        return files
    }

    private func relativePath(file: URL, root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        let withSlash = prefix + "/"
        guard filePath.hasPrefix(withSlash) else { return nil }
        let relative = String(filePath.dropFirst(withSlash.count))
        return relative.isEmpty ? nil : relative
    }
}
