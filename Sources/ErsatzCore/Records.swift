import Foundation

extension MediaDatabase {
    public func updateMetadata(_ updates: [MetadataUpdate]) throws {
        guard !updates.isEmpty else { return }
        let sql = """
        UPDATE media SET
            date_taken = ?,
            taken_year = ?,
            taken_month = ?,
            pixel_width = ?,
            pixel_height = ?,
            duration = ?,
            video_codec = ?,
            audio_codec = ?,
            camera_model = ?,
            format_name = COALESCE(?, format_name),
            date_corrected = ?,
            metadata_ready = 1
        WHERE path = ?
        """
        try connection.transaction {
            for update in updates {
                let metadata = update.metadata
                let parts = metadata.dateTaken.flatMap { CalendarParts.yearMonth(of: $0) }
                try connection.run(sql, [
                    metadata.dateTaken.map { .int(Timestamp.milliseconds($0)) } ?? .null,
                    parts.map { .int(Int64($0.year)) } ?? .null,
                    parts.map { .int(Int64($0.month)) } ?? .null,
                    metadata.pixelWidth.map { .int(Int64($0)) } ?? .null,
                    metadata.pixelHeight.map { .int(Int64($0)) } ?? .null,
                    metadata.duration.map(SQLValue.real) ?? .null,
                    metadata.videoCodec.map(SQLValue.text) ?? .null,
                    metadata.audioCodec.map(SQLValue.text) ?? .null,
                    metadata.cameraModel.map(SQLValue.text) ?? .null,
                    metadata.formatName.map(SQLValue.text) ?? .null,
                    .int(update.dateCorrected ? 1 : 0),
                    .text(update.path)
                ])
            }
        }
    }

    public func pendingAnalysis(limit: Int = 50_000) throws -> [PendingAnalysis] {
        var rows: [PendingAnalysis] = []
        try connection.query(
            """
            SELECT media.id, media.path, media.filename, media.kind, media.file_size, media.modified_at,
                   media.format_name, media.pixel_width, media.pixel_height, media.camera_model
            FROM media
            LEFT JOIN analysis ON analysis.media_id = media.id
            WHERE analysis.media_id IS NULL OR analysis.analyzed_mtime != media.modified_at
            LIMIT ?
            """,
            [.int(Int64(limit))]
        ) { statement in
            guard let kind = MediaType(rawValue: statement.text(3)) else { return }
            rows.append(PendingAnalysis(
                id: statement.int(0),
                path: statement.text(1),
                filename: statement.text(2),
                kind: kind,
                fileSize: statement.int(4),
                modifiedAtMS: statement.int(5),
                formatName: statement.textOrNil(6),
                pixelWidth: statement.intOrNil(7).map(Int.init),
                pixelHeight: statement.intOrNil(8).map(Int.init),
                hasCameraModel: statement.textOrNil(9) != nil
            ))
        }
        return rows
    }

    public func saveAnalysis(_ updates: [AnalysisUpdate]) throws {
        guard !updates.isEmpty else { return }
        let sql = """
        INSERT INTO analysis (
            media_id, partial_hash, content_hash, perceptual_hash, sharpness,
            is_screenshot, has_qr, is_bank_slip, analyzed_mtime
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(media_id) DO UPDATE SET
            partial_hash = excluded.partial_hash,
            content_hash = excluded.content_hash,
            perceptual_hash = excluded.perceptual_hash,
            sharpness = excluded.sharpness,
            is_screenshot = excluded.is_screenshot,
            has_qr = excluded.has_qr,
            is_bank_slip = excluded.is_bank_slip,
            analyzed_mtime = excluded.analyzed_mtime
        """
        try connection.transaction {
            for update in updates {
                try connection.run(sql, [
                    .int(update.mediaID),
                    update.partialHash.map(SQLValue.text) ?? .null,
                    update.contentHash.map(SQLValue.text) ?? .null,
                    update.perceptualHash.map { .int(Int64(bitPattern: $0)) } ?? .null,
                    update.sharpness.map(SQLValue.real) ?? .null,
                    .int(update.isScreenshot ? 1 : 0),
                    .int(update.hasQR ? 1 : 0),
                    .int(update.isBankSlip ? 1 : 0),
                    .int(update.analyzedMTime)
                ])
            }
        }
    }

    public func hashRecords() throws -> [HashRecord] {
        var rows: [HashRecord] = []
        try connection.query(
            """
            SELECT media.id, media.file_size, analysis.content_hash, analysis.perceptual_hash
            FROM media JOIN analysis ON analysis.media_id = media.id
            """
        ) { statement in
            rows.append(HashRecord(
                id: statement.int(0),
                fileSize: statement.int(1),
                contentHash: statement.textOrNil(2),
                perceptualHash: statement.intOrNil(3).map { UInt64(bitPattern: $0) }
            ))
        }
        return rows
    }

    public func imagePaths(folderID: Int64) throws -> [(parent: String, path: String)] {
        var rows: [(String, String)] = []
        try connection.query(
            """
            SELECT parent_relative, path FROM media
            WHERE folder_id = ? AND kind IN ('photo', 'raw')
            ORDER BY filename
            """,
            [.int(folderID)]
        ) { statement in
            rows.append((statement.text(0), statement.text(1)))
        }
        return rows
    }

    public func createCheckpoint(action: String, note: String?, files: [CheckpointFileDraft], at date: Date = Date()) throws -> Checkpoint {
        var id: Int64 = 0
        try connection.transaction {
            try connection.run(
                "INSERT INTO checkpoints (created_at, action, file_count, note) VALUES (?, ?, ?, ?)",
                [.int(Timestamp.milliseconds(date)), .text(action), .int(Int64(files.count)), note.map(SQLValue.text) ?? .null]
            )
            id = connection.lastInsertID
            for file in files {
                try connection.run(
                    """
                    INSERT INTO checkpoint_files (
                        checkpoint_id, path, kind, original_metadata, backup_path, backup_bytes, trash_url
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .int(id),
                        .text(file.path),
                        .text(file.kind.rawValue),
                        file.originalMetadata.map(SQLValue.text) ?? .null,
                        file.backupPath.map(SQLValue.text) ?? .null,
                        .int(file.backupBytes),
                        file.trashURL.map(SQLValue.text) ?? .null
                    ]
                )
            }
        }
        return Checkpoint(id: id, createdAt: date, action: action, fileCount: files.count, note: note)
    }

    public func checkpoints() throws -> [Checkpoint] {
        var rows: [Checkpoint] = []
        try connection.query(
            "SELECT id, created_at, action, file_count, note FROM checkpoints ORDER BY created_at DESC, id DESC"
        ) { statement in
            rows.append(Checkpoint(
                id: statement.int(0),
                createdAt: Timestamp.date(milliseconds: statement.int(1)),
                action: statement.text(2),
                fileCount: Int(statement.int(3)),
                note: statement.textOrNil(4)
            ))
        }
        return rows
    }

    public func checkpointFiles(checkpointID: Int64) throws -> [CheckpointFile] {
        var rows: [CheckpointFile] = []
        try connection.query(
            """
            SELECT id, checkpoint_id, path, kind, original_metadata, backup_path, backup_bytes, trash_url
            FROM checkpoint_files WHERE checkpoint_id = ? ORDER BY id
            """,
            [.int(checkpointID)]
        ) { statement in
            rows.append(CheckpointFile(
                id: statement.int(0),
                checkpointID: statement.int(1),
                path: statement.text(2),
                kind: CheckpointFileKind(rawValue: statement.text(3)) ?? .metadata,
                originalMetadata: statement.textOrNil(4),
                backupPath: statement.textOrNil(5),
                backupBytes: statement.int(6),
                trashURL: statement.textOrNil(7)
            ))
        }
        return rows
    }

    /// Deletes checkpoints older than `olderThan` and, if still over `maxBytes`, the oldest remaining.
    /// Returns backup paths the caller should delete if they were not removed here.
    @discardableResult
    public func pruneCheckpoints(olderThan: Date, maxBytes: Int64) throws -> [String] {
        var removed: [String] = []
        let cutoff = Timestamp.milliseconds(olderThan)
        var staleIDs: [Int64] = []
        try connection.query("SELECT id FROM checkpoints WHERE created_at < ?", [.int(cutoff)]) { statement in
            staleIDs.append(statement.int(0))
        }
        for id in staleIDs {
            removed.append(contentsOf: try deleteCheckpoint(id: id))
        }
        while try backupByteCount() > maxBytes {
            var oldest: Int64?
            try connection.query("SELECT id FROM checkpoints ORDER BY created_at ASC, id ASC LIMIT 1") { statement in
                oldest = statement.int(0)
            }
            guard let oldest else { break }
            removed.append(contentsOf: try deleteCheckpoint(id: oldest))
        }
        return removed
    }

    public func backupByteCount() throws -> Int64 {
        var total: Int64 = 0
        try connection.query("SELECT COALESCE(SUM(backup_bytes), 0) FROM checkpoint_files") { statement in
            total = statement.int(0)
        }
        return total
    }

    @discardableResult
    public func deleteCheckpoint(id: Int64) throws -> [String] {
        var paths: [String] = []
        try connection.query(
            "SELECT backup_path FROM checkpoint_files WHERE checkpoint_id = ? AND backup_path IS NOT NULL",
            [.int(id)]
        ) { statement in
            if let path = statement.textOrNil(0) { paths.append(path) }
        }
        for path in paths {
            try? FileManager.default.removeItem(atPath: path)
        }
        try connection.run("DELETE FROM checkpoints WHERE id = ?", [.int(id)])
        return paths
    }

    public func appendActivity(_ entry: ActivityEntry) throws -> ActivityEntry {
        try connection.run(
            """
            INSERT INTO activity_log (
                created_at, action, path, old_value, new_value, checkpoint_id, success, restorable
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .int(Timestamp.milliseconds(entry.createdAt)),
                .text(entry.action),
                .text(entry.path),
                entry.oldValue.map(SQLValue.text) ?? .null,
                entry.newValue.map(SQLValue.text) ?? .null,
                entry.checkpointID.map { .int($0) } ?? .null,
                .int(entry.success ? 1 : 0),
                .int(entry.restorable ? 1 : 0)
            ]
        )
        let id = connection.lastInsertID
        return ActivityEntry(
            id: id,
            createdAt: entry.createdAt,
            action: entry.action,
            path: entry.path,
            oldValue: entry.oldValue,
            newValue: entry.newValue,
            checkpointID: entry.checkpointID,
            success: entry.success,
            restorable: entry.restorable
        )
    }

    public func activity(matching text: String? = nil, limit: Int = 500) throws -> [ActivityEntry] {
        var sql = """
        SELECT id, created_at, action, path, old_value, new_value, checkpoint_id, success, restorable
        FROM activity_log
        """
        var binds: [SQLValue] = []
        if let text, !text.isEmpty {
            sql += " WHERE path LIKE ? ESCAPE '\\' OR action LIKE ? ESCAPE '\\' OR IFNULL(old_value,'') LIKE ? ESCAPE '\\' OR IFNULL(new_value,'') LIKE ? ESCAPE '\\'"
            let pattern = "%\(Self.likeLiteral(text))%"
            binds.append(contentsOf: [.text(pattern), .text(pattern), .text(pattern), .text(pattern)])
        }
        sql += " ORDER BY created_at DESC, id DESC LIMIT ?"
        binds.append(.int(Int64(limit)))
        var rows: [ActivityEntry] = []
        try connection.query(sql, binds) { statement in
            rows.append(ActivityEntry(
                id: statement.int(0),
                createdAt: Timestamp.date(milliseconds: statement.int(1)),
                action: statement.text(2),
                path: statement.text(3),
                oldValue: statement.textOrNil(4),
                newValue: statement.textOrNil(5),
                checkpointID: statement.intOrNil(6),
                success: statement.int(7) != 0,
                restorable: statement.int(8) != 0
            ))
        }
        return rows
    }

    private static func likeLiteral(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if character == "\\" || character == "%" || character == "_" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }
}
