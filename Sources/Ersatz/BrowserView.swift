#if os(macOS)
import AppKit
import ErsatzCore
import SwiftUI
import UniformTypeIdentifiers

struct BrowserView: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if model.isIndexing || model.progress != nil {
                    IndexBar()
                }
                if let status = model.analysisStatus {
                    AnalysisBar(status: status)
                }
                if model.folders.isEmpty {
                    emptyLibrary
                } else if case .blurry = model.filter {
                    VStack(spacing: 0) {
                        BlurThresholdBar()
                        Divider()
                        if model.items.isEmpty {
                            ContentUnavailableView(
                                "No blurry photos",
                                systemImage: "camera.metering.unknown",
                                description: Text("Nothing scored below the threshold yet. Raise it to catch softer photos.")
                            )
                        } else if model.viewMode == .grid {
                            GridBrowser()
                        } else {
                            ListBrowser()
                        }
                    }
                } else if model.items.isEmpty && model.folderCovers.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing in this view", systemImage: "magnifyingglass")
                    } description: {
                        Text(model.offlineFolderIDs.isEmpty
                            ? "This part of the library has no photos, video, or audio."
                            : "A folder couldn't be read. Add it again if it moved.")
                    }
                } else if case .duplicates = model.filter {
                    DuplicatesBrowser()
                } else if model.viewMode == .grid {
                    GridBrowser()
                } else {
                    ListBrowser()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.showInfo {
                Divider()
                if let item = model.currentItem {
                    InfoPanel(item: item)
                        .frame(width: 280)
                        .frame(maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "No selection",
                        systemImage: "info.circle",
                        description: Text("Select a photo, video, or audio file.")
                    )
                    .frame(width: 280)
                    .frame(maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(model.title)
        .navigationSubtitle("\(model.items.count.formatted()) items")
        .toolbar { toolbar }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            model.receiveDrop(providers)
            return true
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { model.browserWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in
                        model.browserWidth = width
                    }
            }
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("No library yet", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Add a folder of photos, video, or audio. Ersatz indexes it on this Mac and keeps the catalog updated.")
        } actions: {
            Button("Add Folder") { model.pickFolders() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.safelight)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Back", systemImage: "chevron.left") { model.navigate(.back) }
                .disabled(!model.canGoBack)
                .help("Back (⌘[ or mouse back button)")
            Button("Forward", systemImage: "chevron.right") { model.navigate(.forward) }
                .disabled(!model.canGoForward)
                .help("Forward (⌘] or mouse forward button)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Add Folder", systemImage: "folder.badge.plus") {
                model.pickFolders()
            }
            Button("Remove Folder", systemImage: "folder.badge.minus") {
                model.askToRemoveFolder()
            }
            .disabled(!model.canRemoveFolder)
            Menu {
                Picker("Sort", selection: Bindable(model).sortKey) {
                    ForEach(SortKey.allCases) { key in
                        Text(key.title).tag(key)
                    }
                }
                Picker("Order", selection: Bindable(model).sortDirection) {
                    Text("Ascending").tag(SortDirection.ascending)
                    Text("Descending").tag(SortDirection.descending)
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            Picker("Layout", selection: Bindable(model).viewMode) {
                Image(systemName: "square.grid.2x2").tag(ViewMode.grid)
                Image(systemName: "list.bullet").tag(ViewMode.list)
            }
            .pickerStyle(.segmented)
            .help("Grid or list")
            Slider(value: Bindable(model).thumbnailSide, in: 48...512, step: 8)
                .frame(width: 120)
                .controlSize(.small)
                .help("Thumbnail size")
            Button {
                model.showInfo.toggle()
            } label: {
                Label("Info", systemImage: "info.circle")
            }
            .help("Show metadata")
        }
    }
}

private struct AnalysisBar: View {
    @Environment(LibraryModel.self) private var model
    let status: AnalysisStatus

    var body: some View {
        HStack(spacing: 10) {
            if let fraction = status.fraction {
                ProgressView(value: fraction)
                    .frame(width: 140)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(status.total > 0
                ? "\(status.title) \(status.done.formatted()) of \(status.total.formatted())"
                : status.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Stop") { model.cancelAnalysis() }
                .controlSize(.small)
                .help("Stop analyzing. Finished results are kept.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

private struct IndexBar: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            if let fraction = model.progress?.fraction {
                ProgressView(value: fraction)
                    .frame(width: 140)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var label: String {
        guard let progress = model.progress else { return "Indexing" }
        switch progress.phase {
        case .scanning:
            return "Scanning \(progress.filesSeen.formatted()) files"
        case .cataloging:
            return "Adding \(progress.filesSeen.formatted()) files to the catalog"
        case .analyzing:
            return "Looking for duplicates, blur, and screenshots"
        case .reading:
            let done = progress.filesParsed + progress.filesSkipped
            let name = progress.currentPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            return "Indexing \(done.formatted()) of \(progress.filesSeen.formatted()) \(name)"
        case .finished:
            return "Index up to date"
        }
    }
}

private struct GridBrowser: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: model.thumbnailSide, maximum: model.thumbnailSide), spacing: 12)],
                        alignment: .leading,
                        spacing: 14
                    ) {
                        ForEach(model.folderCovers) { cover in
                            FolderCoverTile(cover: cover)
                        }
                        ForEach(model.items) { item in
                            GridCell(item: item)
                                .id(item.id)
                        }
                    }
                    .padding(12)
                    .frame(width: geo.size.width, alignment: .leading)
                }
                .onChange(of: model.scrollTarget) { _, request in
                    if let request { proxy.scrollTo(request.id, anchor: .center) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GridCell: View {
    @Environment(LibraryModel.self) private var model
    let item: MediaItem
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.05))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: model.thumbnailSide, height: model.thumbnailSide)
                        .clipped()
                } else {
                    Image(systemName: item.kind.symbolName)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text(caption)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.62))
                    .foregroundStyle(.white)
                if item.kind != .photo {
                    Image(systemName: item.kind.symbolName)
                        .font(.caption.weight(.semibold))
                        .padding(5)
                        .background(.black.opacity(0.45), in: Circle())
                        .foregroundStyle(.white)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(width: model.thumbnailSide, height: model.thumbnailSide)
            .clipped()
            .overlay {
                Rectangle()
                    .strokeBorder(
                        model.selectedID == item.id ? Theme.safelight : Color.primary.opacity(0.12),
                        lineWidth: model.selectedID == item.id ? 2 : 1
                    )
            }
            Text(item.filename)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: model.thumbnailSide, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.tileClicked(item.id) }
        .contextMenu {
            Button("Open") { model.openViewer(item.id) }
            Button("Show in Finder") { model.reveal(item) }
            Button("Get Info") {
                model.selectedID = item.id
                model.showInfo = true
            }
            Divider()
            Button("Move to Trash…", role: .destructive) { model.confirmTrash([item]) }
        }
        .task(id: "\(item.id)-\(Int(model.thumbnailSide))-\(item.modifiedAt.timeIntervalSince1970)") {
            let side = model.thumbnailSide
            let loaded = await model.thumbnail(for: item, side: side)
            if !Task.isCancelled { image = loaded }
        }
    }

    private var caption: String {
        var parts: [String] = []
        if let resolution = item.resolutionLabel {
            parts.append(resolution)
        } else if let duration = item.durationLabel {
            parts.append(duration)
        }
        if let codec = item.displayCodec {
            parts.append(codec)
        }
        if parts.isEmpty {
            parts.append(item.kind.label)
        }
        return parts.joined(separator: "  ")
    }
}

private struct FolderCoverTile: View {
    @Environment(LibraryModel.self) private var model
    let cover: FolderCover

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if cover.imagePaths.isEmpty {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.06))
                    Image(systemName: "folder")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(cover.imagePaths.prefix(3).enumerated()), id: \.offset) { index, path in
                        CoverImage(path: path, side: model.thumbnailSide * 0.72)
                            .rotationEffect(.degrees(cover.imagePaths.count == 1 ? 0 : Double(index - 1) * 7))
                            .offset(x: cover.imagePaths.count == 1 ? 0 : CGFloat(index - 1) * 8)
                    }
                }
            }
            .frame(width: model.thumbnailSide, height: model.thumbnailSide)
            Text(cover.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: model.thumbnailSide, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if case .folder(let id, _) = model.filter {
                model.filter = .folder(id, directory: cover.relativePath)
            }
        }
    }
}

private struct CoverImage: View {
    @Environment(LibraryModel.self) private var model
    let path: String
    let side: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.2))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: side, height: side * 0.78)
        .clipped()
        .overlay { Rectangle().strokeBorder(.white.opacity(0.8), lineWidth: 2) }
        .shadow(radius: 2, y: 1)
        .task(id: path) {
            let item = MediaItem(
                id: Int64(path.hashValue),
                folderID: 0,
                path: path,
                relativePath: path,
                filename: URL(fileURLWithPath: path).lastPathComponent,
                parentRelative: "",
                kind: .photo,
                fileSize: 0,
                createdAt: nil,
                modifiedAt: Date(),
                dateTaken: nil,
                takenYear: nil,
                takenMonth: nil,
                pixelWidth: nil,
                pixelHeight: nil,
                duration: nil,
                videoCodec: nil,
                audioCodec: nil,
                cameraModel: nil,
                formatName: nil,
                indexedAt: Date()
            )
            image = await model.thumbnail(for: item, side: side)
        }
    }
}

/// Sharpness runs 0 (smeared) to 100 (crisp). Moving the slider re-filters after a pause.
private struct BlurThresholdBar: View {
    @Environment(LibraryModel.self) private var model
    @State private var pending: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 10) {
            Text("Sharpness below \(Int(model.blurryThreshold))")
                .font(.caption)
                .monospacedDigit()
            Slider(value: Bindable(model).blurryThreshold, in: 10...90, step: 1)
                .frame(maxWidth: 240)
            Button("Default") { model.blurryThreshold = Double(BlurDetector.defaultThreshold) }
                .disabled(model.blurryThreshold == BlurDetector.defaultThreshold)
            Spacer()
            Text("\(model.items.count) photos")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onChange(of: model.blurryThreshold) { _, value in
            UserDefaults.standard.set(value, forKey: "blurThresholdV2")
            pending?.cancel()
            pending = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await model.reloadItems()
            }
        }
    }
}

/// One section per duplicate set: the copy Ersatz would keep, then the others, each
/// with the folder it lives in, so it is clear what goes where.
private struct DuplicatesBrowser: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                    if model.duplicateSets.isEmpty {
                        ContentUnavailableView("No duplicates", systemImage: "checkmark.circle", description: Text("Exact matches use a SHA-256 of the file. Near matches use a perceptual hash."))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(model.duplicateSets) { set in
                        Section {
                            VStack(spacing: 0) {
                                ForEach(set.members) { item in
                                    DuplicateRow(item: item, set: set, isOriginal: item.id == set.original.id)
                                        .id(item.id)
                                    if item.id != set.members.last?.id { Divider().padding(.leading, 96) }
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
                            .padding(.horizontal, 12)
                        } header: {
                            DuplicateSetHeader(set: set)
                        }
                    }
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.scrollTarget) { _, request in
                if let request { proxy.scrollTo(request.id, anchor: .center) }
            }
        }
    }
}

private struct DuplicateSetHeader: View {
    @Environment(LibraryModel.self) private var model
    let set: DuplicateSet

    var body: some View {
        HStack(spacing: 8) {
            Text("Set \(set.number)")
                .font(.headline)
            Text(set.kind == .exact ? "Exact copies" : "Look alike")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(set.kind == .exact ? Color.orange.opacity(0.2) : Color.blue.opacity(0.18)))
            Text("\(set.members.count) files · \(ByteCountText.string(bytes: set.reclaimableBytes)) to reclaim")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Keep Original, Trash \(set.copies.count == 1 ? "the Copy" : "\(set.copies.count) Copies")") {
                model.confirmTrashCopies(of: set)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

private struct DuplicateRow: View {
    @Environment(LibraryModel.self) private var model
    let item: MediaItem
    let set: DuplicateSet
    let isOriginal: Bool
    @State private var image: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.18))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: item.kind.symbolName).foregroundStyle(.secondary)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(isOriginal ? "Original" : "Copy")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(isOriginal ? Color.green.opacity(0.25) : Color.primary.opacity(0.1)))
                    Text(item.filename)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(folderPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(item.path)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(model.selectedID == item.id ? Theme.safelight.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { model.tileClicked(item.id) }
        .contextMenu {
            Button("Open") { model.openViewer(item.id) }
            Button("Show in Finder") { model.reveal(item) }
            Divider()
            Button("Keep This One, Trash the Others…") { model.confirmKeepOnly(item, in: set) }
            Button("Move to Trash…", role: .destructive) { model.confirmTrash([item]) }
        }
        .task(id: "\(item.id)-\(item.modifiedAt.timeIntervalSince1970)") {
            let loaded = await model.thumbnail(for: item, side: 144)
            if !Task.isCancelled { image = loaded }
        }
    }

    private var folderPath: String {
        let folder = (item.path as NSString).deletingLastPathComponent
        return (folder as NSString).abbreviatingWithTildeInPath
    }

    private var details: String {
        var parts = [ByteCountText.string(bytes: item.fileSize)]
        if let resolution = item.resolutionLabel { parts.append(resolution) }
        parts.append(DisplayDate.dateTime(item.dateTaken ?? item.createdAt ?? item.modifiedAt))
        return parts.joined(separator: " · ")
    }
}

private struct ListBrowser: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            listHeader
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.items) { item in
                            ListRow(item: item)
                                .id(item.id)
                        }
                    }
                }
                .onChange(of: model.scrollTarget) { _, request in
                    if let request { proxy.scrollTo(request.id, anchor: .center) }
                }
            }
        }
    }

    private var listHeader: some View {
        HStack(spacing: 12) {
            header(.name, width: nil, trailing: false)
            header(.dateTaken, width: 150, trailing: false)
            header(.fileSize, width: 80, trailing: true)
            header(.resolution, width: 120, trailing: false)
            header(.codec, width: 130, trailing: false)
            Text("Duration").frame(width: 72, alignment: .trailing)
            Text("Camera").frame(width: 160, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func header(_ key: SortKey, width: CGFloat?, trailing: Bool) -> some View {
        Button {
            model.toggleSort(key)
        } label: {
            HStack(spacing: 4) {
                Text(key.title)
                if model.sortKey == key {
                    Image(systemName: model.sortDirection == .ascending ? "chevron.up" : "chevron.down")
                }
            }
            .frame(width: width, alignment: trailing ? .trailing : .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

private struct ListRow: View {
    @Environment(LibraryModel.self) private var model
    let item: MediaItem

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: item.kind.symbolName)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(item.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(DisplayDate.dateTime(item.dateTaken))
                .frame(width: 150, alignment: .leading)
            Text(ByteCountText.string(bytes: item.fileSize))
                .frame(width: 80, alignment: .trailing)
                .monospacedDigit()
            Text(item.resolutionLabel ?? "—")
                .frame(width: 120, alignment: .leading)
                .monospacedDigit()
            Text(item.displayCodec ?? "—")
                .frame(width: 130, alignment: .leading)
            Text(item.durationLabel ?? "—")
                .frame(width: 72, alignment: .trailing)
                .monospacedDigit()
            Text(item.cameraModel ?? "—")
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(model.selectedID == item.id ? Theme.safelight.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { model.tileClicked(item.id) }
        .contextMenu {
            Button("Open") { model.openViewer(item.id) }
            Button("Show in Finder") { model.reveal(item) }
            Divider()
            Button("Move to Trash…", role: .destructive) { model.confirmTrash([item]) }
        }
    }
}
#endif
