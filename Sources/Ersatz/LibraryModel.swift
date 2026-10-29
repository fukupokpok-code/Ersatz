#if os(macOS)
import AppKit
import ErsatzCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class LibraryModel {
    var folders: [LibraryFolder] = []
    var folderCounts: [Int64: Int] = [:]
    var trees: [Int64: [FolderNode]] = [:]
    var dateBuckets: [DateBucket] = []
    var kindCounts: [MediaType: Int] = [:]
    var totalCount = 0
    var unknownDateCount = 0
    var items: [MediaItem] = []
    var filter: LibraryFilter = .all
    var selectedID: Int64?
    var sortKey: SortKey = .dateTaken
    var sortDirection: SortDirection = .descending
    var viewMode: ViewMode = .grid
    var thumbnailSide: Double = 192
    var showInfo = true
    var viewerPresented = false
    var progress: IndexProgress?
    var isIndexing = false
    var isReady = false
    var errorMessage: String?
    var showError = false
    var pendingRemoval: LibraryFolder?
    var browserWidth: CGFloat = 900
    var offlineFolderIDs: Set<Int64> = []
    var folderCovers: [FolderCover] = []
    var duplicateGroups: [[MediaItem]] = []
    var showHistory = false
    var showBuddhistConfirm = false
    var trashCandidates: [MediaItem] = []
    var showTrashConfirm = false
    var blurryThreshold: Double = 50
    var checkpointDays: Double = 30
    var checkpointMaxGigabytes: Double = 2
    var screenshotCount = 0
    var qrCount = 0
    var bankSlipCount = 0
    var buddhistDateCount = 0
    var duplicateCount = 0

    var database: MediaDatabase?
    private var thumbnails: ThumbnailService?
    private var accessed: [Int64: URL] = [:]
    private var securityScoped: Set<Int64> = []
    private var watchers: [Int64: FolderWatcher] = [:]
    private var jobs: [(id: Int64, force: Bool)] = []
    private var pumping = false
    private var debounce: [Int64: Task<Void, Never>] = [:]
    private let keys = KeyMonitor()
    private var didStart = false

    var currentItem: MediaItem? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    var canRemoveFolder: Bool { removableFolder != nil }

    var removableFolder: LibraryFolder? {
        guard case .folder(let id, _) = filter else { return nil }
        return folders.first { $0.id == id }
    }

    var gridColumns: Int {
        let stride = thumbnailSide + 18
        return max(1, Int((browserWidth / stride).rounded(.down)))
    }

    var title: String {
        switch filter {
        case .all:
            return "All Media"
        case .folder(let id, let directory):
            if let directory, !directory.isEmpty {
                return directory.split(separator: "/").last.map(String.init) ?? directory
            }
            return folders.first { $0.id == id }?.displayName ?? "Folder"
        case .year(let year):
            return String(year)
        case .month(let year, let month):
            return "\(monthTitle(month)) \(year)"
        case .unknownDate:
            return "Unknown Date"
        case .kind(let kind):
            return kind.pluralTitle
        case .screenshots:
            return "Screenshots"
        case .qrCodes:
            return "QR Codes"
        case .bankSlips:
            return "Bank Slips"
        case .blurry:
            return "Blurry"
        case .duplicates:
            return "Duplicates"
        case .buddhistDates:
            return "Buddhist-Era Dates"
        }
    }

    var yearGroups: [YearGroup] {
        let grouped = Dictionary(grouping: dateBuckets, by: \.year)
        return grouped.keys.sorted(by: >).map { year in
            let months = (grouped[year] ?? []).sorted { $0.month > $1.month }
            return YearGroup(year: year, count: months.reduce(0) { $0 + $1.count }, months: months)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.thumbnail) != nil {
            let value = defaults.double(forKey: Keys.thumbnail)
            if (96...320).contains(value) { thumbnailSide = value }
        }
        if let raw = defaults.string(forKey: Keys.sort), let key = SortKey(rawValue: raw) {
            sortKey = key
        }
        if let raw = defaults.string(forKey: Keys.direction), let direction = SortDirection(rawValue: raw) {
            sortDirection = direction
        }
        if let raw = defaults.string(forKey: Keys.view), let mode = ViewMode(rawValue: raw) {
            viewMode = mode
        }
        if defaults.object(forKey: Keys.info) != nil {
            showInfo = defaults.bool(forKey: Keys.info)
        }
        if defaults.object(forKey: Keys.blur) != nil {
            blurryThreshold = defaults.double(forKey: Keys.blur)
        }
        if defaults.object(forKey: Keys.checkpointDays) != nil {
            checkpointDays = defaults.double(forKey: Keys.checkpointDays)
        }
        if defaults.object(forKey: Keys.checkpointGB) != nil {
            checkpointMaxGigabytes = defaults.double(forKey: Keys.checkpointGB)
        }
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        do {
            let databaseURL = try AppPaths.databaseURL()
            let cacheURL = try AppPaths.thumbnailCacheURL()
            database = try MediaDatabase(path: databaseURL.path)
            thumbnails = try ThumbnailService(directory: cacheURL)
            await restoreFolders()
            await refreshSidebar()
            await reloadItems()
            for folder in folders where !offlineFolderIDs.contains(folder.id) {
                enqueue(folder.id, force: false)
            }
        } catch {
            present(error)
        }
        isReady = true
        installKeys()
        await pruneCheckpoints()
    }

    func installKeys() {
        keys.install { [weak self] code in
            self?.handleKey(code) ?? false
        }
    }

    func pickFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Folder"
        panel.message = "Choose a folder of photos, video, or audio."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await addFolders(urls) }
    }

    func receiveDrop(_ providers: [NSItemProvider]) {
        Task {
            for provider in providers {
                guard let url = await Self.loadFileURL(provider) else { continue }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    continue
                }
                await addFolders([url])
            }
        }
    }

    func askToRemoveFolder() {
        pendingRemoval = removableFolder
    }

    func removeFolder(_ folder: LibraryFolder) async {
        watchers[folder.id]?.stop()
        watchers[folder.id] = nil
        debounce[folder.id]?.cancel()
        releaseAccess(folder.id)
        do {
            try await database?.removeFolder(id: folder.id)
        } catch {
            present(error)
        }
        if case .folder(let id, _) = filter, id == folder.id {
            filter = .all
        }
        pendingRemoval = nil
        await refreshSidebar()
        await reloadItems()
    }

    func reindexSelection() {
        switch filter {
        case .folder(let id, _):
            enqueue(id, force: true)
        default:
            for folder in folders where !offlineFolderIDs.contains(folder.id) {
                enqueue(folder.id, force: true)
            }
        }
    }

    func reloadItems() async {
        guard let database else { return }
        do {
            var query = filter.query
            query.blurryThreshold = blurryThreshold
            let fetched = try await database.media(matching: query)
            items = MediaSorter.sorted(fetched, key: sortKey, direction: sortDirection)
            folderCovers = []
            duplicateGroups = []
            if case .folder(let id, let directory) = filter {
                let paths = try await database.imagePaths(folderID: id)
                let current = directory ?? ""
                let directories = (trees[id] ?? []).flatMap { Self.childPaths($0, under: current) }
                folderCovers = FolderCoverPlanner.covers(files: paths, directories: directories, directory: current)
            }
            if case .duplicates = filter {
                let records = try await database.hashRecords()
                let groups = DuplicateFinder.exactGroups(records) + DuplicateFinder.nearGroups(records, threshold: 8)
                let byID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
                duplicateGroups = groups.compactMap { ids in
                    let members = ids.compactMap { byID[$0] }
                    return members.count > 1 ? members : nil
                }
                duplicateCount = duplicateGroups.reduce(0) { $0 + $1.count }
            }
            if let selectedID, !items.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
        } catch {
            present(error)
        }
    }

    func resort() {
        items = MediaSorter.sorted(items, key: sortKey, direction: sortDirection)
        UserDefaults.standard.set(sortKey.rawValue, forKey: Keys.sort)
        UserDefaults.standard.set(sortDirection.rawValue, forKey: Keys.direction)
    }

    func toggleSort(_ key: SortKey) {
        if sortKey == key {
            sortDirection = sortDirection == .ascending ? .descending : .ascending
        } else {
            sortKey = key
            sortDirection = key == .name ? .ascending : .descending
        }
        resort()
    }

    func persistChrome() {
        let defaults = UserDefaults.standard
        defaults.set(thumbnailSide, forKey: Keys.thumbnail)
        defaults.set(viewMode.rawValue, forKey: Keys.view)
        defaults.set(showInfo, forKey: Keys.info)
    }

    func thumbnail(for item: MediaItem, side: CGFloat) async -> NSImage? {
        await thumbnails?.image(for: item, side: side)
    }

    func viewerImage(for item: MediaItem, maxPixel: Int) async -> NSImage? {
        await thumbnails?.viewerImage(for: item, maxPixel: maxPixel)
    }

    func reveal(_ item: MediaItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    func openViewer(_ id: Int64? = nil) {
        if let id {
            selectedID = id
        } else if selectedID == nil {
            selectedID = items.first?.id
        }
        guard selectedID != nil else { return }
        viewerPresented = true
    }

    func closeViewer() {
        viewerPresented = false
    }

    func toggleViewer() {
        if viewerPresented {
            closeViewer()
        } else {
            openViewer()
        }
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        guard let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) else {
            self.selectedID = items.first?.id
            return
        }
        let next = min(max(0, index + delta), items.count - 1)
        self.selectedID = items[next].id
    }

    private static func childPaths(_ node: FolderNode, under directory: String) -> [String] {
        if directory.isEmpty {
            return [node.relativePath]
        }
        if node.relativePath == directory {
            return node.children.map(\.relativePath)
        }
        return node.children.flatMap { childPaths($0, under: directory) }
    }

    func monthTitle(_ month: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .current
        let symbols = calendar.monthSymbols
        guard month >= 1, month <= symbols.count else { return String(month) }
        return symbols[month - 1]
    }

    func handleKey(_ code: UInt16) -> Bool {
        switch code {
        case 49:
            toggleViewer()
            return true
        case 53:
            guard viewerPresented else { return false }
            closeViewer()
            return true
        case 123:
            moveSelection(by: -1)
            return true
        case 124:
            moveSelection(by: 1)
            return true
        case 126:
            moveSelection(by: viewerPresented || viewMode == .list ? -1 : -gridColumns)
            return true
        case 125:
            moveSelection(by: viewerPresented || viewMode == .list ? 1 : gridColumns)
            return true
        case 36:
            openViewer()
            return true
        default:
            return false
        }
    }

    private func addFolders(_ urls: [URL]) async {
        for url in urls {
            await addFolder(url.standardizedFileURL)
        }
    }

    private func addFolder(_ url: URL) async {
        guard let database else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            present(message: "Choose a folder, not a file.")
            return
        }
        if let existing = folders.first(where: { $0.path == url.path }) {
            await relink(existing, to: url)
            return
        }
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        do {
            let folder = try await database.addFolder(
                path: url.path,
                bookmark: bookmark,
                displayName: url.lastPathComponent
            )
            beginAccess(url, id: folder.id)
            startWatching(folder.id, url: url)
            await refreshSidebar()
            enqueue(folder.id, force: false)
        } catch {
            present(error)
        }
    }

    private func relink(_ folder: LibraryFolder, to url: URL) async {
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        do {
            try await database?.updateFolder(id: folder.id, path: url.path, bookmark: bookmark, displayName: url.lastPathComponent)
        } catch {
            present(error)
            return
        }
        releaseAccess(folder.id)
        beginAccess(url, id: folder.id)
        watchers[folder.id]?.stop()
        startWatching(folder.id, url: url)
        offlineFolderIDs.remove(folder.id)
        await refreshSidebar()
        enqueue(folder.id, force: false)
    }

    private func restoreFolders() async {
        guard let database else { return }
        let stored = (try? await database.folders()) ?? []
        for folder in stored {
            guard let url = await resolve(folder) else {
                offlineFolderIDs.insert(folder.id)
                continue
            }
            offlineFolderIDs.remove(folder.id)
            if url.path != folder.path {
                let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                try? await database.updateFolder(
                    id: folder.id,
                    path: url.path,
                    bookmark: bookmark ?? folder.bookmark,
                    displayName: url.lastPathComponent
                )
            }
            beginAccess(url, id: folder.id)
            startWatching(folder.id, url: url)
        }
    }

    private func resolve(_ folder: LibraryFolder) async -> URL? {
        if let data = folder.bookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), directoryExists(url) {
                if stale, let refreshed = try? url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    try? await database?.updateFolder(
                        id: folder.id,
                        path: url.path,
                        bookmark: refreshed,
                        displayName: url.lastPathComponent
                    )
                }
                return url.standardizedFileURL
            }
        }
        let fallback = URL(fileURLWithPath: folder.path)
        return directoryExists(fallback) ? fallback.standardizedFileURL : nil
    }

    private func refreshSidebar() async {
        guard let database else { return }
        do {
            let summary = try await database.summary()
            folders = summary.folders
            folderCounts = summary.folderCounts
            totalCount = summary.totalCount
            unknownDateCount = summary.unknownDateCount
            kindCounts = summary.kindCounts
            dateBuckets = summary.dateBuckets
            screenshotCount = summary.screenshotCount
            qrCount = summary.qrCount
            bankSlipCount = summary.bankSlipCount
            buddhistDateCount = summary.buddhistDateCount
            var built: [Int64: [FolderNode]] = [:]
            for (id, directories) in summary.directoryCounts {
                built[id] = FolderTreeBuilder.makeTree(directories)
            }
            trees = built
        } catch {
            present(error)
        }
    }

    private func enqueue(_ id: Int64, force: Bool) {
        jobs.append((id, force))
        guard !pumping else { return }
        pumping = true
        Task { await drain() }
    }

    private func drain() async {
        while !jobs.isEmpty {
            let job = jobs.removeFirst()
            await index(folderID: job.id, force: job.force)
        }
        pumping = false
        if !jobs.isEmpty {
            pumping = true
            await drain()
        }
    }

    private func index(folderID: Int64, force: Bool) async {
        guard let database, let root = accessed[folderID] else { return }
        let indexer = LibraryIndexer()
        let extractor = MacMetadataExtractor()
        isIndexing = true
        let model = self
        do {
            _ = try await Task.detached(priority: .utility) {
                try await indexer.index(
                    root: root,
                    folderID: folderID,
                    database: database,
                    extractor: extractor,
                    force: force
                ) { progress in
                    Task { @MainActor in
                        let previous = model.progress?.phase
                        model.progress = progress
                        if progress.phase == .cataloging && previous != .cataloging {
                            await model.reloadItems()
                        }
                    }
                }
            }.value
        } catch is CancellationError {
        } catch {
            present(error)
        }
        isIndexing = false
        progress = IndexProgress(phase: .analyzing, filesSeen: 1, filesParsed: 0)
        await refreshSidebar()
        await reloadItems()
        await runAnalysis()
        progress = nil
        await refreshSidebar()
        await reloadItems()
    }

    private func startWatching(_ id: Int64, url: URL) {
        let watcher = FolderWatcher(url: url) { [weak self] in
            Task { @MainActor in
                self?.scheduleReindex(id)
            }
        }
        watcher.start()
        watchers[id] = watcher
    }

    private func scheduleReindex(_ id: Int64) {
        debounce[id]?.cancel()
        debounce[id] = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            self.enqueue(id, force: false)
        }
    }

    private func beginAccess(_ url: URL, id: Int64) {
        if url.startAccessingSecurityScopedResource() {
            securityScoped.insert(id)
        }
        accessed[id] = url
    }

    private func releaseAccess(_ id: Int64) {
        if securityScoped.remove(id) != nil, let url = accessed[id] {
            url.stopAccessingSecurityScopedResource()
        }
        accessed[id] = nil
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func present(_ error: Error) {
        present(message: error.localizedDescription)
    }

    func present(message: String) {
        errorMessage = message
        showError = true
    }

    private static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        let identifier = UTType.fileURL.identifier
        guard provider.hasItemConformingToTypeIdentifier(identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

private enum Keys {
    static let thumbnail = "thumbnailSide"
    static let sort = "sortKey"
    static let direction = "sortDirection"
    static let view = "viewMode"
    static let info = "showInfo"
    static let blur = "blurryThreshold"
    static let checkpointDays = "checkpointDays"
    static let checkpointGB = "checkpointMaxGigabytes"
}
#endif
