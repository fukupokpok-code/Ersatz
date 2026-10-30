#if os(macOS)
import AppKit
import ErsatzCore
import Foundation

extension LibraryModel {
    func adjustThumbnail(by delta: Double) {
        thumbnailSide = min(512, max(48, thumbnailSide + delta))
        persistChrome()
    }

    func prepareBuddhistFix() {
        filter = .buddhistDates
        Task {
            await reloadItems()
            if !items.isEmpty {
                showBuddhistConfirm = true
            } else {
                present(message: "No Buddhist-era dates were corrected in the catalog.")
            }
        }
    }

    func writeCorrectedDates() async {
        let targets = items.filter(\.dateCorrected)
        guard !targets.isEmpty else { return }
        let drafts = targets.map { item in
            CheckpointFileDraft(
                path: item.path,
                kind: .metadata,
                originalMetadata: item.dateTaken.map { "dateTaken=\(EXIFDateParser.format($0))" }
            )
        }
        guard let checkpoint = try? await database?.createCheckpoint(action: "fix-buddhist-era-dates", note: "Metadata only", files: drafts) else {
            present(message: "Couldn't create a checkpoint.")
            return
        }
        for item in targets {
            guard let date = item.dateTaken else { continue }
            let old = EXIFDateParser.format(date)
            let result = MetadataWriter.writeDate(url: URL(fileURLWithPath: item.path), date: date)
            let entry = ActivityEntry(
                id: 0,
                createdAt: Date(),
                action: "fix-buddhist-era-dates",
                path: item.path,
                oldValue: old,
                newValue: result.written,
                checkpointID: checkpoint.id,
                success: result.success,
                restorable: true
            )
            if let stored = try? await database?.appendActivity(entry) {
                try? ActivityLog.shared?.append(stored)
            }
        }
        await reloadItems()
    }

    /// Right-click > Move to Trash… in the grid, the list and the viewer. Asks first.
    func confirmTrash(_ targets: [MediaItem]) {
        guard !targets.isEmpty else { return }
        trashCandidates = targets
        trashReason = .delete
        showTrashConfirm = true
    }

    /// Duplicates > Keep Original, Trash the Rest. Asks first.
    func confirmTrashCopies(of set: DuplicateSet) {
        guard !set.copies.isEmpty else { return }
        trashCandidates = set.copies
        trashReason = .duplicates
        showTrashConfirm = true
    }

    /// Duplicates > Keep This One: the rest of its set goes to the Trash. Asks first.
    func confirmKeepOnly(_ keep: MediaItem, in set: DuplicateSet) {
        let others = set.members.filter { $0.id != keep.id }
        guard !others.isEmpty else { return }
        trashCandidates = others
        trashReason = .duplicates
        showTrashConfirm = true
    }

    var trashTitle: String {
        if trashCandidates.count == 1, let only = trashCandidates.first {
            return "Move \u{201C}\(only.filename)\u{201D} to the Trash?"
        }
        return "Move \(trashCandidates.count) files to the Trash?"
    }

    /// The confirmation dialog's Move to Trash button.
    func trashConfirmed() async {
        let targets = trashCandidates
        let reason = trashReason
        trashCandidates = []
        await moveToTrash(targets, action: reason.action)
    }

    /// Moves files to the Finder Trash (never a permanent delete), records a checkpoint
    /// so History can put them back, and drops them from the catalog and the screen.
    /// The viewer moves on to the next item, or closes when nothing is left.
    func moveToTrash(_ targets: [MediaItem], action: String) async {
        guard !targets.isEmpty, let database else { return }
        let drafts = targets.map { CheckpointFileDraft(path: $0.path, kind: .deletion) }
        guard let checkpoint = try? await database.createCheckpoint(action: action, note: nil, files: drafts) else {
            present(message: "Couldn't create a checkpoint.")
            return
        }
        let urls = targets.map { URL(fileURLWithPath: $0.path) }
        let trashed: [URL: URL] = await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { mapping, error in
                if let error {
                    AppLog.ui.error("trash: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: mapping)
            }
        }
        var removed: [Int64] = []
        for item in targets {
            let source = URL(fileURLWithPath: item.path)
            let trash = trashed[source] ?? trashed[source.standardizedFileURL]
            if let trash {
                removed.append(item.id)
                try? await database.recordTrashURL(checkpointID: checkpoint.id, path: item.path, trashURL: trash.path)
            }
            let entry = ActivityEntry(
                id: 0,
                createdAt: Date(),
                action: action,
                path: item.path,
                oldValue: item.path,
                newValue: trash?.path,
                checkpointID: checkpoint.id,
                success: trash != nil,
                restorable: trash != nil
            )
            if let stored = try? await database.appendActivity(entry) {
                try? ActivityLog.shared?.append(stored)
            }
        }
        AppLog.ui.info("trash: \(action, privacy: .public) moved \(removed.count, privacy: .public) of \(targets.count, privacy: .public)")
        if removed.count < targets.count {
            present(message: "\(targets.count - removed.count) of \(targets.count) files couldn't be moved to the Trash.")
        }
        guard !removed.isEmpty else { return }
        let gone = Set(removed)
        if viewerPresented, let selectedID, gone.contains(selectedID) {
            let next = ViewerSequence.successor(viewerSequenceIDs, removing: gone, current: selectedID)
            if let next {
                self.selectedID = next
                viewerScope = viewerScope?.filter { !gone.contains($0) }
            } else {
                self.selectedID = nil
                closeViewer()
            }
        } else if let selectedID, gone.contains(selectedID) {
            self.selectedID = ViewerSequence.successor(browserSequenceIDs, removing: gone, current: selectedID)
        }
        do {
            try await database.removeMedia(ids: removed)
        } catch {
            present(error)
        }
        items.removeAll { gone.contains($0.id) }
        await reloadItems()
        await refreshAfterTrash()
    }

    func restore(checkpoint: Checkpoint) async {
        guard let files = try? await database?.checkpointFiles(checkpointID: checkpoint.id) else { return }
        for file in files {
            await restore(file: file, checkpoint: checkpoint)
        }
    }

    func restore(file: CheckpointFile, checkpoint: Checkpoint) async {
        var success = false
        var newValue = ""
        switch file.kind {
        case .metadata:
            if let original = file.originalMetadata, let date = date(fromCheckpoint: original) {
                let result = MetadataWriter.writeDate(url: URL(fileURLWithPath: file.path), date: date)
                success = result.success
                newValue = result.written
            }
        case .content:
            if let backup = file.backupPath {
                let source = URL(fileURLWithPath: backup)
                let destination = URL(fileURLWithPath: file.path)
                do {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.copyItem(at: source, to: destination)
                    success = true
                    newValue = destination.path
                } catch {
                    success = false
                    newValue = error.localizedDescription
                }
            }
        case .deletion:
            if let trash = file.trashURL {
                let source = URL(fileURLWithPath: trash)
                let destination = URL(fileURLWithPath: file.path)
                do {
                    try FileManager.default.moveItem(at: source, to: destination)
                    success = true
                    newValue = destination.path
                } catch {
                    success = false
                    newValue = error.localizedDescription
                }
            }
        }
        let entry = ActivityEntry(
            id: 0,
            createdAt: Date(),
            action: "restore",
            path: file.path,
            oldValue: file.originalMetadata ?? file.trashURL ?? file.backupPath,
            newValue: newValue,
            checkpointID: checkpoint.id,
            success: success,
            restorable: false
        )
        if let stored = try? await database?.appendActivity(entry) {
            try? ActivityLog.shared?.append(stored)
        }
    }

    func pruneCheckpoints() async {
        let days = max(1, checkpointDays)
        let maxBytes = Int64(checkpointMaxGigabytes * 1_073_741_824)
        let cutoff = Date().addingTimeInterval(-days * 24 * 60 * 60)
        _ = try? await database?.pruneCheckpoints(olderThan: cutoff, maxBytes: maxBytes)
        UserDefaults.standard.set(checkpointDays, forKey: "checkpointDays")
        UserDefaults.standard.set(checkpointMaxGigabytes, forKey: "checkpointMaxGigabytes")
    }

    private func date(fromCheckpoint metadata: String) -> Date? {
        guard let range = metadata.range(of: "dateTaken=") else { return nil }
        return EXIFDateParser.parse(String(metadata[range.upperBound...]))
    }
}

enum ActivityLog {
    static let shared: ActivityLogFile? = {
        let directory = AppPaths.logsDirectory()
        do {
            return try ActivityLogFile(directory: directory)
        } catch {
            AppLog.app.error("activity log unavailable at \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()
}
#endif
