#if os(macOS)
import AppKit
import AVFoundation
import ErsatzCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum ViewerPlayback: Equatable {
    case idle
    case checking
    case working
    case ready(URL)
    case needsFFmpeg
    case failed(String)
}

/// Asks the grid or list to scroll to an item. The token makes repeat requests for the same item fire.
/// Why files are about to go to the Trash; names the checkpoint and the dialog.
enum TrashReason: Sendable {
    case delete
    case duplicates

    var action: String {
        switch self {
        case .delete: return "trash-files"
        case .duplicates: return "trash-duplicates"
        }
    }
}

struct ScrollRequest: Equatable {
    let id: Int64
    let token = UUID()
}

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
    var duplicateSets: [DuplicateSet] = []
    /// When the viewer was opened from Duplicates, the set it walks through.
    var viewerScope: [Int64]?
    var showHistory = false
    var showBuddhistConfirm = false
    var trashCandidates: [MediaItem] = []
    var trashReason: TrashReason = .delete
    var showTrashConfirm = false
    var blurryThreshold: Double = Double(BlurDetector.defaultThreshold)
    var checkpointDays: Double = 30
    var checkpointMaxGigabytes: Double = 2
    var ffmpegPath = ""
    var playbackCacheGigabytes: Double = 5
    var playbackProgress: PlaybackProgress?
    var viewerPlayback: ViewerPlayback = .idle
    var screenshotCount = 0
    var qrCount = 0
    var bankSlipCount = 0
    var buddhistDateCount = 0
    var duplicateCount = 0
    /// Duplicate, blur, screenshot, QR and bank slip analysis runs only when a smart
    /// filter or Library > Analyze Library asks for it, never on launch or after indexing.
    var analysisStatus: AnalysisStatus?
    /// The library the Date Taken, Type and Smart views are limited to: the last library
    /// (or sub-folder) picked in the sidebar. All Media clears it.
    private(set) var libraryScope: LibraryScope?
    var showFolderPicker = false
    /// Item the grid or list should scroll to. Set only by keyboard moves, so a click
    /// never scrolls the tile out from under the mouse between the two clicks of a double-click.
    var scrollTarget: ScrollRequest?
    @ObservationIgnored weak var hostWindow: NSWindow?

    var database: MediaDatabase?
    private var thumbnails: ThumbnailService?
    private var accessed: [Int64: URL] = [:]
    private var securityScoped: Set<Int64> = []
    private var watchers: [Int64: FolderWatcher] = [:]
    private var jobs: [(id: Int64, force: Bool)] = []
    private var pumping = false
    private var debounce: [Int64: Task<Void, Never>] = [:]
    private let keys = KeyMonitor()
    private let mouse = MouseButtonMonitor()
    /// Back and forward through sidebar places, like Finder. Opening the viewer is an
    /// entry too, so Back closes it (like the viewer's Back button) and Forward reopens it.
    private(set) var history = NavigationHistory(BrowsePlace<LibraryFilter>(.all))
    private var didStart = false
    private var playbackCache: PlaybackCache?
    private var videoTask: Task<Void, Never>?
    private var playbackGeneration = 0
    private var viewerUsedExternal = false
    private var indexTask: Task<Void, Error>?
    private var indexingFolderID: Int64?
    private var isQuitting = false
    /// Thumbnails in the foreground lane, analysis in the background lane.
    let workGate = WorkGate(
        foregroundLimit: max(4, ProcessInfo.processInfo.activeProcessorCount / 2),
        backgroundLimit: max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    )
    private var analysisWork: Task<Void, Error>?
    private var analysisGeneration = 0
    /// Decides when analysis starts and stops (see AnalysisPlanner). There is no queue:
    /// leaving a smart filter or pressing Stop ends its pass for good.
    private var planner = AnalysisPlanner()
    private var lastAnalysisReload = Date.distantPast
    private var analysisReloadPending = false

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

    /// Name of the library the Date Taken, Type and Smart views are limited to, or nil for all.
    var scopeTitle: String? {
        guard let libraryScope else { return nil }
        if let directory = libraryScope.directory, !directory.isEmpty {
            return directory.split(separator: "/").last.map(String.init) ?? directory
        }
        return folders.first { $0.id == libraryScope.folderID }?.displayName ?? "Folder"
    }

    /// "Date Taken · clips" while a library is picked, so it is clear the counts are scoped.
    func sectionTitle(_ name: String) -> String {
        guard let scopeTitle else { return name }
        return "\(name) · \(scopeTitle)"
    }

    var title: String {
        let base = baseTitle
        switch filter {
        case .all, .folder: return base
        default:
            guard let scopeTitle else { return base }
            return "\(base) · \(scopeTitle)"
        }
    }

    private var baseTitle: String {
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
        if let path = defaults.string(forKey: PlaybackPreferences.pathKey) {
            ffmpegPath = path
        }
        if defaults.object(forKey: PlaybackPreferences.cacheKey) != nil {
            playbackCacheGigabytes = defaults.double(forKey: PlaybackPreferences.cacheKey)
        }
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        do {
            let databaseURL = try AppPaths.databaseURL()
            let cacheURL = try AppPaths.thumbnailCacheURL()
            let playbackURL = try AppPaths.playbackCacheURL()
            database = try MediaDatabase(path: databaseURL.path)
            thumbnails = try ThumbnailService(directory: cacheURL, gate: workGate)
            playbackCache = try PlaybackCache(directory: playbackURL)
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
        trimPlaybackCache()
        await pruneCheckpoints()
    }

    func installKeys() {
        keys.install { [weak self] code in
            self?.handleKey(code) ?? false
        }
        mouse.install { [weak self] direction in
            self?.navigate(direction) ?? false
        }
    }

    var canGoBack: Bool { viewerPresented || history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    /// Called when the sidebar or a folder tile changes `filter`.
    func recordNavigation(_ location: LibraryFilter) {
        // A back/forward move already set this place.
        guard history.current.filter != location else { return }
        // Leaving a folder while the viewer is up: keep the grid entry, not the viewer entry.
        if history.current.isViewer {
            history.replaceCurrent(history.current.browser)
        }
        history.visit(BrowsePlace(location))
    }

    /// Mouse back/forward, swipe, Command-[ / Command-] and the toolbar arrows.
    /// In the viewer, Back is the viewer's Back button: close it and return to the grid
    /// with the item still selected. Forward then reopens the viewer on that item.
    /// In the browser they move through folder history. Arrow keys still change photos.
    @discardableResult
    func navigate(_ direction: NavigationDirection) -> Bool {
        let name = direction == .back ? "back" : "forward"
        if viewerPresented {
            if direction == .back {
                AppLog.ui.info("navigate back: close viewer")
                closeViewer()
            } else if let target = history.goForward() {
                apply(target)
            } else {
                AppLog.ui.info("navigate forward in viewer: nothing ahead")
            }
            return true
        }
        let target = direction == .back ? history.goBack() : history.goForward()
        guard let target else {
            AppLog.ui.info("navigate \(name, privacy: .public): end of history")
            return true
        }
        AppLog.ui.info("navigate \(name, privacy: .public) to \(String(describing: target), privacy: .public)")
        apply(target)
        return true
    }

    private func apply(_ place: BrowsePlace<LibraryFilter>) {
        if filter != place.filter {
            filter = place.filter
        }
        if let id = place.viewing {
            guard items.contains(where: { $0.id == id }) else {
                AppLog.viewer.notice("navigate: item \(id, privacy: .public) is gone; staying in the grid")
                history.replaceCurrent(place.browser)
                return
            }
            presentViewer(id)
        } else if viewerPresented {
            stopViewerPlayback()
            viewerPresented = false
            revealSelection()
        }
    }

    private func revealSelection() {
        if let selectedID {
            scrollTarget = ScrollRequest(id: selectedID)
        }
    }

    /// Shows the folder picker as a sheet on the main window (see ContentView's
    /// `.fileImporter`). It never runs an app-wide modal loop, so the menu bar and
    /// Command-Q keep working while it is open.
    func pickFolders() {
        guard !showFolderPicker else {
            AppLog.ui.info("pickFolders: picker already open")
            return
        }
        WindowKeeper.bringForward(hostWindow)
        AppLog.ui.info("pickFolders: presenting folder picker")
        showFolderPicker = true
    }

    func finishPicking(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            AppLog.ui.info("pickFolders: chose \(urls.count, privacy: .public) folders")
            for url in urls {
                AppLog.library.info("pickFolders: \(url.path, privacy: .public)")
            }
            Task { await addFolders(urls) }
        case .failure(let error):
            AppLog.ui.error("pickFolders failed: \(error.localizedDescription, privacy: .public)")
            present(error)
        }
    }

    func folderPickerCancelled() {
        AppLog.ui.info("pickFolders: cancelled")
    }

    func openHistory() {
        AppLog.ui.info("sheet: History")
        WindowKeeper.bringForward(hostWindow)
        showHistory = true
    }

    /// Called from applicationShouldTerminate. Stops background work so quitting is immediate.
    func prepareForQuit() {
        guard !isQuitting else { return }
        isQuitting = true
        AppLog.app.info("prepareForQuit: indexing \(self.isIndexing, privacy: .public), queued \(self.jobs.count, privacy: .public)")
        jobs.removeAll()
        indexTask?.cancel()
        indexTask = nil
        _ = planner.reset()
        analysisGeneration += 1
        analysisWork?.cancel()
        analysisWork = nil
        analysisStatus = nil
        stopViewerPlayback()
        for task in debounce.values { task.cancel() }
        debounce.removeAll()
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
        keys.remove()
        mouse.remove()
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
        AppLog.ui.info("removeFolder \(folder.id, privacy: .public) \(folder.path, privacy: .public)")
        watchers[folder.id]?.stop()
        watchers[folder.id] = nil
        debounce[folder.id]?.cancel()
        debounce[folder.id] = nil
        jobs.removeAll { $0.id == folder.id }
        // Stop an index run for this folder and wait for it, so it can't write rows for
        // a folder that no longer exists (that was the FOREIGN KEY constraint alert).
        if indexingFolderID == folder.id, let running = indexTask {
            AppLog.ui.info("removeFolder: stopping the index run for it first")
            running.cancel()
            _ = try? await running.value
        }
        releaseAccess(folder.id)
        do {
            try await database?.removeFolder(id: folder.id)
        } catch {
            present(error)
        }
        history.removeAll(where: { place in
            if case .folder(let id, _) = place.filter { return id == folder.id }
            return false
        }, replacement: BrowsePlace(.all))
        if case .folder(let id, _) = filter, id == folder.id {
            filter = .all
        }
        if libraryScope?.folderID == folder.id {
            libraryScope = nil
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
            var query = filter.query.scoped(to: libraryScope)
            query.blurryThreshold = blurryThreshold
            let fetched = try await database.media(matching: query)
            items = MediaSorter.sorted(fetched, key: sortKey, direction: sortDirection)
            folderCovers = []
            duplicateSets = []
            if case .folder(let id, let directory) = filter {
                let paths = try await database.imagePaths(folderID: id)
                let current = directory ?? ""
                let directories = (trees[id] ?? []).flatMap { Self.childPaths($0, under: current) }
                folderCovers = FolderCoverPlanner.covers(files: paths, directories: directories, directory: current)
            }
            if case .duplicates = filter {
                let records = try await database.hashRecords(scope: libraryScope)
                let exact = DuplicateFinder.exactGroups(records)
                let similar = DuplicateFinder.nearGroups(records, threshold: 8)
                duplicateSets = DuplicateSetBuilder.sets(exact: exact, similar: similar, items: fetched)
                duplicateCount = Set(duplicateSets.flatMap(\.memberIDs)).count
            }
            if viewerPresented, viewerScope != nil, let selectedID {
                viewerScope = scope(for: selectedID)
            }
            if let selectedID, !items.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
                if viewerPresented {
                    AppLog.viewer.info("closeViewer: selected item left the current view")
                    closeViewer()
                }
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
        guard let thumbnails else {
            AppLog.viewer.error("image load failed: thumbnail service unavailable for \(item.path, privacy: .public)")
            return nil
        }
        let started = Date()
        let image = await thumbnails.viewerImage(for: item, maxPixel: maxPixel)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if let image {
            AppLog.viewer.info("image loaded \(Int(image.size.width), privacy: .public)x\(Int(image.size.height), privacy: .public) in \(ms, privacy: .public) ms: \(item.path, privacy: .public)")
        } else {
            let exists = FileManager.default.isReadableFile(atPath: item.path)
            AppLog.viewer.error("image load failed after \(ms, privacy: .public) ms (readable \(exists, privacy: .public)): \(item.path, privacy: .public)")
        }
        return image
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
        guard let item = currentItem else {
            AppLog.viewer.notice("openViewer: nothing to open (selected \(String(describing: self.selectedID), privacy: .public), \(self.items.count, privacy: .public) items)")
            return
        }
        guard !viewerPresented else { return }
        if history.current.isViewer {
            history.replaceCurrent(history.current.browser)
        }
        history.visit(BrowsePlace(filter, viewing: item.id))
        presentViewer(item.id)
    }

    /// Shows the viewer without touching history.
    private func presentViewer(_ id: Int64) {
        selectedID = id
        guard let item = currentItem else { return }
        viewerScope = scope(for: id)
        AppLog.viewer.info("openViewer: \(item.kind.rawValue, privacy: .public) \(item.path, privacy: .public)")
        viewerPresented = true
    }

    /// Opened from Duplicates, the viewer stays inside the item's duplicate set.
    func scope(for id: Int64) -> [Int64]? {
        guard case .duplicates = filter else { return nil }
        return duplicateSets.first { $0.memberIDs.contains(id) }?.memberIDs ?? [id]
    }

    /// What the viewer's filmstrip and Previous / Next walk through.
    var viewerSequenceIDs: [Int64] {
        viewerScope ?? items.map(\.id)
    }

    /// What arrow keys walk through in the browser. Duplicates lists sets in order.
    var browserSequenceIDs: [Int64] {
        if case .duplicates = filter { return duplicateSets.flatMap(\.memberIDs) }
        return items.map(\.id)
    }

    /// "Set 3 · 2 of 4" in the viewer header when it is scoped to a duplicate set.
    var viewerScopeLabel: String? {
        guard let viewerScope, let selectedID,
              let set = duplicateSets.first(where: { $0.memberIDs.contains(selectedID) }),
              let index = viewerScope.firstIndex(of: selectedID) else { return nil }
        return "Duplicate set \(set.number) · \(index + 1) of \(viewerScope.count)"
    }

    func item(withID id: Int64) -> MediaItem? {
        items.first { $0.id == id }
    }

    /// Click on a grid tile or list row. One recognizer reads AppKit's click count, so
    /// a single click selects at once and the second click of a double-click opens,
    /// with no wait for a double-click timeout and no competing gestures.
    func tileClicked(_ id: Int64) {
        let clicks = NSApp.currentEvent?.clickCount ?? 1
        if clicks >= 2 {
            AppLog.ui.info("double-click on item \(id, privacy: .public)")
            openViewer(id)
        } else {
            selectedID = id
        }
    }

    /// The viewer's Back button, Esc, mouse Back and Command-[ all end here.
    /// It steps history back to the grid, so Forward can reopen the same item.
    func closeViewer() {
        if viewerPresented {
            AppLog.viewer.info("closeViewer")
        }
        if history.current.isViewer {
            if let selectedID {
                history.replaceCurrent(BrowsePlace(history.current.filter, viewing: selectedID))
                if history.backStack.last == history.current.browser {
                    history.goBack()
                } else {
                    history.replaceCurrent(history.current.browser)
                }
            } else {
                history.replaceCurrent(history.current.browser)
            }
        }
        stopViewerPlayback()
        viewerPresented = false
        viewerScope = nil
        revealSelection()
    }

    func prepareViewerVideo(_ item: MediaItem) {
        playbackGeneration += 1
        let generation = playbackGeneration
        videoTask?.cancel()
        playbackProgress = nil
        viewerUsedExternal = false
        guard item.kind == .video else {
            viewerPlayback = .idle
            videoTask = nil
            return
        }
        if ExternalPlayback.needsExternalPlayer(path: item.path) {
            viewerPlayback = .working
            videoTask = Task { @MainActor in
                await self.transcode(item, generation: generation)
            }
            return
        }
        viewerPlayback = .checking
        videoTask = Task { @MainActor in
            await self.checkNative(item, generation: generation)
        }
    }

    func cancelViewerPlayback() {
        videoTask?.cancel()
    }

    func stopViewerPlayback() {
        playbackGeneration += 1
        videoTask?.cancel()
        videoTask = nil
        playbackProgress = nil
        viewerPlayback = .idle
    }

    func fallBackToFFmpeg(_ item: MediaItem) {
        guard !viewerUsedExternal else {
            publish(.failed("This file could not be played."), generation: playbackGeneration)
            return
        }
        playbackGeneration += 1
        let generation = playbackGeneration
        videoTask?.cancel()
        viewerPlayback = .working
        videoTask = Task { @MainActor in
            await self.transcode(item, generation: generation)
        }
    }

    func persistPlaybackSettings() {
        let defaults = UserDefaults.standard
        defaults.set(ffmpegPath, forKey: PlaybackPreferences.pathKey)
        defaults.set(playbackCacheGigabytes, forKey: PlaybackPreferences.cacheKey)
    }

    func trimPlaybackCache() {
        guard let playbackCache else { return }
        let maxBytes = PlaybackCachePolicy.bytes(gigabytes: playbackCacheGigabytes)
        let cache = playbackCache
        Task.detached {
            try? cache.enforceLimit(maxBytes: maxBytes)
        }
    }

    private func checkNative(_ item: MediaItem, generation: Int) async {
        let source = URL(fileURLWithPath: item.path)
        let playable = (try? await AVURLAsset(url: source).load(.isPlayable)) ?? false
        guard generation == playbackGeneration else { return }
        if Task.isCancelled {
            publish(.failed("Cancelled"), generation: generation)
            return
        }
        if playable {
            publish(.ready(source), generation: generation)
        } else {
            await transcode(item, generation: generation)
        }
    }

    private func transcode(_ item: MediaItem, generation: Int) async {
        guard generation == playbackGeneration else { return }
        viewerUsedExternal = true
        publish(.working, generation: generation)
        playbackProgress = PlaybackProgress(stage: .probing, fraction: nil)
        do {
            let url = try await preparedPlaybackURL(for: item)
            guard generation == playbackGeneration, !Task.isCancelled else { return }
            playbackProgress = nil
            publish(.ready(url), generation: generation)
        } catch is CancellationError {
            playbackProgress = nil
            publish(.failed("Cancelled"), generation: generation)
        } catch let error as FFmpegRunnerError {
            playbackProgress = nil
            switch error {
            case .notInstalled:
                publish(.needsFFmpeg, generation: generation)
            case .probeFailed(let detail), .failed(let detail):
                publish(.failed(detail), generation: generation)
            case .unsupported(let reason):
                publish(.failed(reason), generation: generation)
            }
        } catch {
            playbackProgress = nil
            publish(.failed(error.localizedDescription), generation: generation)
        }
    }

    private func publish(_ playback: ViewerPlayback, generation: Int) {
        guard generation == playbackGeneration else { return }
        viewerPlayback = playback
    }

    func preparedPlaybackURL(for item: MediaItem) async throws -> URL {
        persistPlaybackSettings()
        guard let playbackCache else {
            throw FFmpegRunnerError.failed("Playback cache is unavailable.")
        }
        guard let tools = PlaybackPreferences.tools() else {
            throw FFmpegRunnerError.notInstalled
        }
        let source = URL(fileURLWithPath: item.path)
        let maxBytes = PlaybackCachePolicy.bytes(gigabytes: playbackCacheGigabytes)
        let generation = playbackGeneration
        let model = self
        return try await FFmpegRunner.materialize(
            tools: tools,
            source: source,
            fileSize: item.fileSize,
            modifiedAt: item.modifiedAt,
            cache: playbackCache,
            maxBytes: maxBytes
        ) { progress in
            Task { @MainActor in
                guard model.playbackGeneration == generation else { return }
                model.playbackProgress = progress
            }
        }
    }

    func toggleViewer() {
        if viewerPresented {
            closeViewer()
        } else {
            openViewer()
        }
    }

    func moveSelection(by delta: Int) {
        let ids = viewerPresented ? viewerSequenceIDs : browserSequenceIDs
        guard let next = ViewerSequence.step(ids, from: selectedID, by: delta) else { return }
        selectedID = next
        scrollTarget = ScrollRequest(id: next)
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
        case 36, 76:
            guard !viewerPresented else { return false }
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
            let summary = try await database.summary(scope: libraryScope)
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
        guard !isQuitting else { return }
        jobs.append((id, force))
        guard !pumping else { return }
        pumping = true
        Task { await drain() }
    }

    private func drain() async {
        while !jobs.isEmpty, !isQuitting {
            let job = jobs.removeFirst()
            await index(folderID: job.id, force: job.force)
        }
        pumping = false
        if !jobs.isEmpty, !isQuitting {
            pumping = true
            await drain()
        }
    }

    private func index(folderID: Int64, force: Bool) async {
        guard let database, let root = accessed[folderID] else {
            // A skipped (offline) last job still has to end indexing, or a smart filter
            // would wait for it forever.
            if jobs.isEmpty, planner.isIndexing {
                perform(planner.indexing(false, filterParts: filter.analysisParts, scope: libraryScope))
            }
            return
        }
        indexingFolderID = folderID
        defer { indexingFolderID = nil }
        let indexer = LibraryIndexer()
        persistPlaybackSettings()
        let extractor = ExternalContainerExtractor()
        isIndexing = true
        perform(planner.indexing(true))
        let model = self
        let task = Task.detached(priority: .utility) {
                _ = try await indexer.index(
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
            }
        indexTask = task
        do {
            _ = try await task.value
        } catch is CancellationError {
        } catch DatabaseError.folderRemoved(let id) {
            AppLog.ui.info("index: folder \(id, privacy: .public) was removed during indexing")
        } catch {
            if !isQuitting { present(error) }
        }
        indexTask = nil
        isIndexing = false
        progress = nil
        guard !isQuitting else { return }
        if Task.isCancelled {
            if jobs.isEmpty { perform(planner.indexing(false)) }
            return
        }
        await refreshSidebar()
        await reloadItems()
        // No automatic analysis here: launch and folder changes only index. A smart filter
        // still on screen catches up on new files, unless the user pressed Stop.
        if jobs.isEmpty {
            perform(planner.indexing(false, filterParts: filter.analysisParts, scope: libraryScope))
        }
    }

    // MARK: Lazy analysis

    /// Called when the sidebar selection changes. Picking a library scopes the Date Taken,
    /// Type and Smart views to it; a smart filter analyzes just what it shows, and leaving
    /// one stops its analysis.
    func filterDidChange() {
        let previous = libraryScope
        switch filter {
        case .all: libraryScope = nil
        case .folder(let id, let directory): libraryScope = LibraryScope(folderID: id, directory: directory)
        default: break
        }
        if libraryScope != previous {
            Task { await refreshSidebar(); await refreshAnalysisCounts() }
        }
        analyzeForCurrentFilter()
    }

    func analyzeForCurrentFilter() {
        guard database != nil, !isQuitting else { return }
        AppLog.ui.notice("analysis: place \(String(describing: self.filter), privacy: .public) needs parts \(self.filter.analysisParts.rawValue, privacy: .public)")
        perform(planner.select(parts: filter.analysisParts, scope: libraryScope))
    }

    /// Library > Analyze Library: every part, every library.
    func analyzeLibrary() {
        guard database != nil, !isQuitting else { return }
        perform(planner.analyzeLibrary())
    }

    var canAnalyzeLibrary: Bool { database != nil && analysisStatus == nil && !folders.isEmpty }

    /// The Stop button and Cmd-. The bar goes away at once; the pass is cancelled, and
    /// nothing restarts it until a smart filter or Analyze Library is picked again.
    func cancelAnalysis() {
        AppLog.ui.notice("analysis: stopped by the user")
        perform(planner.stop())
        // Stop always stops: cancel whatever pass exists, even one the planner lost track of.
        stopAnalysisWork()
    }

    private func perform(_ action: AnalysisPlanner.Action) {
        switch action {
        case .none:
            break
        case .cancel:
            stopAnalysisWork()
        case .start(let demand):
            startAnalysis(demand)
        case .cancelAndStart(let demand):
            stopAnalysisWork()
            startAnalysis(demand)
        }
        // The bar and the work follow the planner: when it says nothing runs, nothing does.
        if planner.running == nil {
            if analysisWork != nil { stopAnalysisWork() }
            analysisStatus = nil
        }
    }

    private func stopAnalysisWork() {
        analysisStatus = nil
        guard let work = analysisWork else { return }
        AppLog.ui.notice("analysis: cancel the running pass")
        // Bump the generation first so its late progress, batches and completion are ignored.
        analysisGeneration += 1
        work.cancel()
        analysisWork = nil
        analysisStatus = nil
        Task {
            _ = try? await work.value
            await refreshAnalysisCounts()
            await refreshSidebar()
        }
    }

    private func startAnalysis(_ demand: AnalysisDemand) {
        let run = planner.run
        // Never leave an older pass running next to the new one.
        if analysisWork != nil { stopAnalysisWork() }
        guard let database, !isQuitting else {
            _ = planner.finished(demand, run: run)
            return
        }
        let parts = demand.parts
        let scope = demand.scope
        analysisGeneration += 1
        let generation = analysisGeneration
        analysisStatus = AnalysisStatus(demand: demand, done: 0, total: 0)
        let gate = workGate
        let model = self
        AppLog.ui.notice("analysis: start run \(run, privacy: .public) \(demand.title, privacy: .public) parts \(parts.rawValue, privacy: .public) origin \(String(describing: demand.origin), privacy: .public) scope \(String(describing: scope), privacy: .public) filter \(String(describing: self.filter), privacy: .public)")
        let work = Task.detached(priority: .utility) {
            try await LibraryAnalyzer().analyze(
                database: database,
                parts: parts,
                scoring: MacImageScoring(),
                gate: gate,
                scope: scope,
                progress: { done, total in
                    Task { @MainActor in
                        guard model.analysisGeneration == generation else { return }
                        model.analysisStatus = AnalysisStatus(demand: demand, done: done, total: total)
                    }
                },
                saved: { _ in
                    Task { @MainActor in
                        guard model.analysisGeneration == generation else { return }
                        model.analysisBatchSaved(parts)
                    }
                }
            )
        }
        analysisWork = work
        Task { @MainActor in
            var finished = false
            do {
                try await work.value
                finished = true
            } catch is CancellationError {
            } catch {
                AppLog.ui.error("analysis failed: \(error.localizedDescription, privacy: .public)")
            }
            guard model.analysisGeneration == generation else { return }
            model.analysisWork = nil
            model.analysisStatus = nil
            AppLog.ui.notice("analysis: run \(run, privacy: .public) \(finished ? "finished" : "stopped", privacy: .public)")
            await model.refreshAnalysisCounts()
            await model.refreshSidebar()
            if !model.filter.analysisParts.isEmpty {
                await model.reloadItems()
            }
            guard !model.isQuitting else { return }
            model.perform(model.planner.finished(demand, run: run))
        }
    }

    /// Results show up while a pass runs, not only when it ends: the filter on screen
    /// reloads at most every two seconds as batches are saved.
    private func analysisBatchSaved(_ parts: AnalysisParts) {
        let shown = filter.analysisParts
        guard !shown.isEmpty, !shown.isDisjoint(with: parts) else { return }
        let wait = 2 - Date().timeIntervalSince(lastAnalysisReload)
        if wait <= 0 {
            lastAnalysisReload = Date()
            Task { await refreshAfterBatch() }
        } else if !analysisReloadPending {
            analysisReloadPending = true
            Task {
                try? await Task.sleep(for: .seconds(wait))
                analysisReloadPending = false
                lastAnalysisReload = Date()
                await refreshAfterBatch()
            }
        }
    }

    private func refreshAfterBatch() async {
        guard !isQuitting, analysisWork != nil else { return }
        if let summary = try? await database?.summary(scope: libraryScope) {
            screenshotCount = summary.screenshotCount
            qrCount = summary.qrCount
            bankSlipCount = summary.bankSlipCount
        }
        await reloadItems()
    }

    /// After files went to the Trash: sidebar counts and the duplicate count.
    func refreshAfterTrash() async {
        await refreshAnalysisCounts()
        await refreshSidebar()
    }

    private func refreshAnalysisCounts() async {
        guard let database, let records = try? await database.hashRecords(scope: libraryScope) else { return }
        let exact = DuplicateFinder.exactGroups(records)
        let similar = DuplicateFinder.nearGroups(records, threshold: 8)
        duplicateCount = Set((exact + similar).joined()).count
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
        guard !isQuitting else { return }
        errorMessage = message
        WindowKeeper.bringForward(hostWindow)
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
    static let blur = "blurThresholdV2"
    static let checkpointDays = "checkpointDays"
    static let checkpointGB = "checkpointMaxGigabytes"
}
#endif
