#if os(macOS)
import ErsatzCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let viewing = model.viewerPresented && model.currentItem != nil
        ZStack {
            if model.isReady {
                NavigationSplitView(columnVisibility: .constant(.doubleColumn)) {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 196, ideal: 232, max: 320)
                } detail: {
                    BrowserView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .opacity(viewing ? 0 : 1)
                .allowsHitTesting(!viewing)
                if viewing, let item = model.currentItem {
                    ViewerView(item: item)
                }
            } else {
                ProgressView("Opening library")
                    .controlSize(.large)
            }
        }
        .background {
            WindowReader { window in
                model.hostWindow = window
                WindowKeeper.rescue(window)
            }
            .frame(width: 0, height: 0)
        }
        .task { await model.start() }
        .onAppear { model.installKeys() }
        .fileImporter(
            isPresented: $model.showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            model.finishPicking(result)
        } onCancellation: {
            model.folderPickerCancelled()
        }
        .fileDialogMessage("Choose a folder of photos, video, or audio.")
        .fileDialogConfirmationLabel("Add Folder")
        .onChange(of: model.viewerPresented && model.currentItem == nil) { _, orphaned in
            if orphaned {
                AppLog.viewer.notice("closeViewer: current item disappeared")
                model.closeViewer()
            }
        }
        .onChange(of: model.showError) { _, shown in
            if shown { AppLog.ui.notice("alert: \(model.errorMessage ?? "", privacy: .public)") }
        }
        .onChange(of: model.pendingRemoval != nil) { _, shown in
            if shown { AppLog.ui.info("dialog: remove folder") }
        }
        .onChange(of: model.showHistory) { _, shown in
            AppLog.ui.info("sheet: History \(shown ? "shown" : "closed", privacy: .public)")
        }
        .onChange(of: model.showBuddhistConfirm) { _, shown in
            if shown { AppLog.ui.info("dialog: Buddhist-era dates") }
        }
        .onChange(of: model.showTrashConfirm) { _, shown in
            if shown { AppLog.ui.info("dialog: move \(model.trashCandidates.count, privacy: .public) files to Trash") }
        }
        .alert("Something went wrong", isPresented: $model.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog(
            "Remove this folder from the library?",
            isPresented: Binding(
                get: { model.pendingRemoval != nil },
                set: { if !$0 { model.pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Folder", role: .destructive) {
                if let folder = model.pendingRemoval {
                    Task { await model.removeFolder(folder) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The files stay where they are. Ersatz only forgets the folder.")
        }
        .onChange(of: model.filter) { _, location in
            model.recordNavigation(location)
            // Sets the library scope first, so the reload below shows only that library.
            model.filterDidChange()
            Task {
                await model.reloadItems()
            }
        }
        .onChange(of: model.sortKey) { _, _ in model.resort() }
        .onChange(of: model.sortDirection) { _, _ in model.resort() }
        .onChange(of: model.thumbnailSide) { _, _ in model.persistChrome() }
        .onChange(of: model.viewMode) { _, _ in model.persistChrome() }
        .onChange(of: model.showInfo) { _, _ in model.persistChrome() }
        .sheet(isPresented: $model.showHistory) {
            HistoryView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 480)
        }
        .confirmationDialog(
            "Write corrected Gregorian dates into these files?",
            isPresented: $model.showBuddhistConfirm,
            titleVisibility: .visible
        ) {
            Button("Write \(model.buddhistDateCount) Dates", role: .destructive) {
                Task { await model.writeCorrectedDates() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Ersatz will store the original date in History first. Files whose metadata cannot be updated in place get an XMP sidecar. Nothing is changed until you confirm.")
        }
        .confirmationDialog(
            model.trashTitle,
            isPresented: $model.showTrashConfirm,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await model.trashConfirmed() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The files go to the macOS Trash, not a permanent delete. A checkpoint records each one so you can restore it from History.")
        }
    }
}

struct SidebarView: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.filter) {
            Section("Library") {
                Label("All Media", systemImage: "rectangle.stack")
                    .badge(model.totalCount)
                    .tag(LibraryFilter.all)
                ForEach(model.folders) { folder in
                    FolderBlock(folder: folder)
                }
            }
            Section(model.sectionTitle("Date Taken")) {
                ForEach(model.yearGroups) { year in
                    DisclosureGroup {
                        ForEach(year.months, id: \.self) { bucket in
                            Text(model.monthTitle(bucket.month))
                                .badge(bucket.count)
                                .tag(LibraryFilter.month(year.year, bucket.month))
                        }
                    } label: {
                        Text(String(year.year))
                            .badge(year.count)
                            .tag(LibraryFilter.year(year.year))
                    }
                }
                if model.unknownDateCount > 0 {
                    Text("Unknown")
                        .badge(model.unknownDateCount)
                        .tag(LibraryFilter.unknownDate)
                }
            }
            Section(model.sectionTitle("Type")) {
                ForEach(MediaType.allCases, id: \.self) { kind in
                    Label(kind.pluralTitle, systemImage: kind.symbolName)
                        .badge(model.kindCounts[kind] ?? 0)
                        .tag(LibraryFilter.kind(kind))
                }
            }
            Section(model.sectionTitle("Smart")) {
                Label("Duplicates", systemImage: "square.on.square")
                    .badge(model.duplicateCount)
                    .tag(LibraryFilter.duplicates)
                Label("Blurry", systemImage: "camera.metering.unknown")
                    .tag(LibraryFilter.blurry)
                Label("Screenshots", systemImage: "macwindow")
                    .badge(model.screenshotCount)
                    .tag(LibraryFilter.screenshots)
                Label("QR Codes", systemImage: "qrcode")
                    .badge(model.qrCount)
                    .tag(LibraryFilter.qrCodes)
                Label("Bank Slips", systemImage: "banknote")
                    .badge(model.bankSlipCount)
                    .tag(LibraryFilter.bankSlips)
                Label("Buddhist-Era Dates", systemImage: "calendar.badge.exclamationmark")
                    .badge(model.buddhistDateCount)
                    .tag(LibraryFilter.buddhistDates)
            }
        }
        .listStyle(.sidebar)
    }
}

private struct FolderBlock: View {
    @Environment(LibraryModel.self) private var model
    let folder: LibraryFolder

    var body: some View {
        let nodes = model.trees[folder.id] ?? []
        if nodes.isEmpty {
            folderLabel
                .tag(LibraryFilter.folder(folder.id, directory: nil))
        } else {
            DisclosureGroup {
                FolderBranch(folderID: folder.id, nodes: nodes)
            } label: {
                folderLabel
            }
            .tag(LibraryFilter.folder(folder.id, directory: nil))
        }
    }

    private var folderLabel: some View {
        HStack(spacing: 6) {
            Label(folder.displayName, systemImage: "folder")
            if model.offlineFolderIDs.contains(folder.id) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help("Ersatz can't read this folder. Add it again to refresh access.")
            }
        }
        .badge(model.folderCounts[folder.id] ?? 0)
    }
}

private struct FolderBranch: View {
    let folderID: Int64
    let nodes: [FolderNode]

    var body: some View {
        ForEach(nodes) { node in
            if node.children.isEmpty {
                Label(node.name, systemImage: "folder")
                    .badge(node.fileCount)
                    .tag(LibraryFilter.folder(folderID, directory: node.relativePath))
            } else {
                DisclosureGroup {
                    FolderBranch(folderID: folderID, nodes: node.children)
                } label: {
                    Label(node.name, systemImage: "folder")
                        .badge(node.fileCount)
                }
                .tag(LibraryFilter.folder(folderID, directory: node.relativePath))
            }
        }
    }
}
#endif
