import Foundation

/// One set of duplicate files for the Duplicates view: the copy to keep and the others.
public struct DuplicateSet: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        /// Byte-for-byte the same file.
        case exact
        /// Looks the same (perceptual hash), e.g. a re-saved or resized copy.
        case similar
    }

    public var number: Int
    public var kind: Kind
    public var original: MediaItem
    public var copies: [MediaItem]

    /// Sets are numbered 1, 2, 3… in display order; an item can sit in two sets.
    public var id: Int { number }
    /// Original first, then the copies.
    public var members: [MediaItem] { [original] + copies }
    public var memberIDs: [Int64] { members.map(\.id) }
    public var reclaimableBytes: Int64 { copies.reduce(0) { $0 + $1.fileSize } }
}

public enum DuplicateSetBuilder {
    /// Turns hash groups into numbered sets. Exact groups come first; a similar group that
    /// only repeats an exact group is dropped. Ids not in `items` are skipped.
    public static func sets(exact: [[Int64]], similar: [[Int64]], items: [MediaItem]) -> [DuplicateSet] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [DuplicateSet] = []
        var exactSets: [Set<Int64>] = []
        func add(_ ids: [Int64], kind: DuplicateSet.Kind) {
            let members = ids.compactMap { byID[$0] }
            guard members.count > 1 else { return }
            let ordered = members.sorted { keepOrder($0, $1, kind: kind) }
            result.append(DuplicateSet(
                number: result.count + 1,
                kind: kind,
                original: ordered[0],
                copies: Array(ordered.dropFirst())
            ))
        }
        for group in exact {
            exactSets.append(Set(group))
            add(group, kind: .exact)
        }
        for group in similar {
            let ids = Set(group)
            if exactSets.contains(where: { ids.isSubset(of: $0) }) { continue }
            add(group, kind: .similar)
        }
        return result
    }

    /// The file to keep sorts first. Exact copies: the oldest file (it was there first),
    /// then the shorter path. Similar ones: the biggest picture, then the bigger file, then
    /// the oldest, so a downscaled or re-compressed copy is the one offered for the Trash.
    static func keepOrder(_ a: MediaItem, _ b: MediaItem, kind: DuplicateSet.Kind) -> Bool {
        if kind == .similar {
            let pa = (a.pixelWidth ?? 0) * (a.pixelHeight ?? 0)
            let pb = (b.pixelWidth ?? 0) * (b.pixelHeight ?? 0)
            if pa != pb { return pa > pb }
            if a.fileSize != b.fileSize { return a.fileSize > b.fileSize }
        }
        let da = a.createdAt ?? a.modifiedAt
        let db = b.createdAt ?? b.modifiedAt
        if da != db { return da < db }
        if a.path.count != b.path.count { return a.path.count < b.path.count }
        return a.id < b.id
    }
}

/// The viewer's filmstrip and arrow keys walk a sequence: normally the whole grid, or
/// only one duplicate set when the viewer was opened from the Duplicates view.
public enum ViewerSequence {
    /// Up to `radius` items either side of `id`. Just `[]` when `id` is not in `ids`.
    public static func window(_ ids: [Int64], around id: Int64, radius: Int = 10) -> [Int64] {
        guard let index = ids.firstIndex(of: id) else { return [] }
        let lower = max(0, index - radius)
        let upper = min(ids.count, index + radius + 1)
        return Array(ids[lower..<upper])
    }

    /// The id `delta` steps from `id`, clamped to the ends.
    public static func step(_ ids: [Int64], from id: Int64?, by delta: Int) -> Int64? {
        guard !ids.isEmpty else { return nil }
        guard let id, let index = ids.firstIndex(of: id) else { return ids.first }
        return ids[min(max(0, index + delta), ids.count - 1)]
    }

    /// Where to go after `removed` leaves the sequence: the next item, or the previous
    /// one when the last was removed. Nil when nothing is left.
    public static func successor(_ ids: [Int64], removing removed: Set<Int64>, current: Int64) -> Int64? {
        guard let index = ids.firstIndex(of: current) else {
            return ids.first { !removed.contains($0) }
        }
        if let next = ids[(index + 1)...].first(where: { !removed.contains($0) }) { return next }
        return ids[..<index].last { !removed.contains($0) }
    }
}
