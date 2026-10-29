import Foundation

public struct FolderNode: Sendable, Equatable, Identifiable {
    public var relativePath: String
    public var name: String
    public var fileCount: Int
    public var children: [FolderNode]

    public var id: String { relativePath }

    public init(relativePath: String, name: String, fileCount: Int, children: [FolderNode]) {
        self.relativePath = relativePath
        self.name = name
        self.fileCount = fileCount
        self.children = children
    }
}

public enum FolderTreeBuilder {
    /// Builds a directory tree from parent-relative directory counts.
    /// `fileCount` includes files in nested directories. Empty root paths are ignored.
    public static func makeTree(_ directories: [DirectoryCount]) -> [FolderNode] {
        var direct: [String: Int] = [:]
        for entry in directories where !entry.parentRelative.isEmpty {
            direct[entry.parentRelative, default: 0] += entry.count
            let parts = entry.parentRelative.split(separator: "/").map(String.init)
            if parts.count > 1 {
                for index in 1..<parts.count {
                    let ancestor = parts.prefix(index).joined(separator: "/")
                    if direct[ancestor] == nil {
                        direct[ancestor] = 0
                    }
                }
            }
        }
        let paths = direct.keys.sorted { FilenameOrder.compare($0, $1) == .orderedAscending }
        func children(of parent: String?) -> [FolderNode] {
            var nodes: [FolderNode] = []
            for path in paths {
                let parentPath = parentPath(of: path)
                let matches = parent == nil ? parentPath.isEmpty : parentPath == parent
                if !matches { continue }
                let nested = children(of: path)
                let recursive = direct[path, default: 0] + nested.reduce(0) { $0 + $1.fileCount }
                let name = path.split(separator: "/").last.map(String.init) ?? path
                nodes.append(FolderNode(relativePath: path, name: name, fileCount: recursive, children: nested))
            }
            return nodes
        }
        return children(of: nil)
    }

    private static func parentPath(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
}
