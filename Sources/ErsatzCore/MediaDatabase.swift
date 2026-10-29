import Foundation

private enum MediaSQL {
    static let selectList = """
    SELECT id, folder_id, path, relative_path, filename, parent_relative, kind,
           file_size, created_at, modified_at, date_taken, taken_year, taken_month,
           pixel_width, pixel_height, duration, video_codec, audio_codec, camera_model,
           format_name, indexed_at, date_corrected, metadata_ready
    FROM media
    """
}

public actor MediaDatabase {
    let connection: SQLiteConnection

    public init(path: String) throws {
        connection = try SQLiteConnection(path: path)
    }

    public func addFolder(path: String, bookmark: Data?, displayName: String, addedAt: Date = Date()) throws -> LibraryFolder {
        do {
            try connection.run(
                "INSERT INTO folders (path, bookmark, display_name, added_at) VALUES (?, ?, ?, ?)",
                [
                    .text(path),
                    bookmark.map(SQLValue.blob) ?? .null,
                    .text(displayName),
                    .int(Timestamp.milliseconds(addedAt))
                ]
            )
        } catch let error as DatabaseError {
            if case .duplicate = error {
                throw DatabaseError.duplicate("That folder is already in the library.")
            }
            throw error
        }
        let id = connection.lastInsertID
        return LibraryFolder(id: id, path: path, bookmark: bookmark, displayName: displayName, addedAt: addedAt)
    }

    public func updateFolder(id: Int64, path: String, bookmark: Data?, displayName: String) throws {
        try connection.run(
            "UPDATE folders SET path = ?, bookmark = ?, display_name = ? WHERE id = ?",
            [
                .text(path),
                bookmark.map(SQLValue.blob) ?? .null,
                .text(displayName),
                .int(id)
            ]
        )
    }

    public func removeFolder(id: Int64) throws {
        try connection.run("DELETE FROM folders WHERE id = ?", [.int(id)])
    }

    public func folders() throws -> [LibraryFolder] {
        var result: [LibraryFolder] = []
        try connection.query(
            "SELECT id, path, bookmark, display_name, added_at FROM folders ORDER BY display_name COLLATE NOCASE, id"
        ) { statement in
            result.append(
                LibraryFolder(
                    id: statement.int(0),
                    path: statement.text(1),
                    bookmark: statement.blobOrNil(2),
                    displayName: statement.text(3),
                    addedAt: Timestamp.date(milliseconds: statement.int(4))
                )
            )
        }
        return result
    }

    public func snapshots(folderID: Int64) throws -> [String: FileSnapshot] {
        var result: [String: FileSnapshot] = [:]
        try connection.query(
            "SELECT path, file_size, modified_at, metadata_ready FROM media WHERE folder_id = ?",
            [.int(folderID)]
        ) { statement in
            result[statement.text(0)] = FileSnapshot(
                fileSize: statement.int(1),
                modifiedAtMS: statement.int(2),
                metadataReady: statement.int(3) != 0
            )
        }
        return result
    }

    public func upsert(_ items: [NewMedia]) throws {
        guard !items.isEmpty else { return }
        let sql = """
        INSERT INTO media (
            folder_id, path, relative_path, filename, parent_relative, kind,
            file_size, created_at, modified_at, date_taken, taken_year, taken_month,
            pixel_width, pixel_height, duration, video_codec, audio_codec, camera_model,
            format_name, indexed_at, date_corrected, metadata_ready
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
            folder_id = excluded.folder_id,
            relative_path = excluded.relative_path,
            filename = excluded.filename,
            parent_relative = excluded.parent_relative,
            kind = excluded.kind,
            file_size = excluded.file_size,
            created_at = excluded.created_at,
            modified_at = excluded.modified_at,
            date_taken = excluded.date_taken,
            taken_year = excluded.taken_year,
            taken_month = excluded.taken_month,
            pixel_width = excluded.pixel_width,
            pixel_height = excluded.pixel_height,
            duration = excluded.duration,
            video_codec = excluded.video_codec,
            audio_codec = excluded.audio_codec,
            camera_model = excluded.camera_model,
            format_name = excluded.format_name,
            indexed_at = excluded.indexed_at,
            date_corrected = excluded.date_corrected,
            metadata_ready = excluded.metadata_ready
        """
        let indexedAt = Timestamp.milliseconds(Date())
        try connection.transaction {
            for item in items {
                let taken = item.dateTaken
                let parts = taken.flatMap { CalendarParts.yearMonth(of: $0) }
                try connection.run(sql, [
                    .int(item.folderID),
                    .text(item.path),
                    .text(item.relativePath),
                    .text(item.filename),
                    .text(item.parentRelative),
                    .text(item.kind.rawValue),
                    .int(item.fileSize),
                    item.createdAt.map { .int(Timestamp.milliseconds($0)) } ?? .null,
                    .int(Timestamp.milliseconds(item.modifiedAt)),
                    taken.map { .int(Timestamp.milliseconds($0)) } ?? .null,
                    parts.map { .int(Int64($0.year)) } ?? .null,
                    parts.map { .int(Int64($0.month)) } ?? .null,
                    item.pixelWidth.map { .int(Int64($0)) } ?? .null,
                    item.pixelHeight.map { .int(Int64($0)) } ?? .null,
                    item.duration.map(SQLValue.real) ?? .null,
                    item.videoCodec.map(SQLValue.text) ?? .null,
                    item.audioCodec.map(SQLValue.text) ?? .null,
                    item.cameraModel.map(SQLValue.text) ?? .null,
                    item.formatName.map(SQLValue.text) ?? .null,
                    .int(indexedAt),
                    .int(item.dateCorrected ? 1 : 0),
                    .int(item.metadataReady ? 1 : 0)
                ])
            }
        }
    }

    public func deleteUnseen(folderID: Int64, seen: Set<String>) throws -> Int {
        var removed = 0
        try connection.transaction {
            try connection.execute("CREATE TEMP TABLE IF NOT EXISTS seen_paths (path TEXT PRIMARY KEY)")
            try connection.execute("DELETE FROM seen_paths")
            let insert = "INSERT OR IGNORE INTO seen_paths (path) VALUES (?)"
            for path in seen {
                try connection.run(insert, [.text(path)])
            }
            removed = try connection.run(
                "DELETE FROM media WHERE folder_id = ? AND path NOT IN (SELECT path FROM seen_paths)",
                [.int(folderID)]
            )
        }
        return removed
    }

    public func media(matching query: MediaQuery) throws -> [MediaItem] {
        var sql = MediaSQL.selectList + " WHERE 1 = 1"
        var binds: [SQLValue] = []
        if let folderID = query.folderID {
            sql += " AND folder_id = ?"
            binds.append(.int(folderID))
        }
        if let prefix = query.directoryPrefix {
            sql += " AND (parent_relative = ? OR parent_relative LIKE ? ESCAPE '\\')"
            binds.append(.text(prefix))
            binds.append(.text(Self.likePrefix(prefix)))
        }
        if let kind = query.kind {
            sql += " AND kind = ?"
            binds.append(.text(kind.rawValue))
        }
        if query.screenshotsOnly {
            sql += " AND id IN (SELECT media_id FROM analysis WHERE is_screenshot = 1)"
        }
        if query.qrOnly {
            sql += " AND id IN (SELECT media_id FROM analysis WHERE has_qr = 1)"
        }
        if query.bankSlipsOnly {
            sql += " AND id IN (SELECT media_id FROM analysis WHERE is_bank_slip = 1)"
        }
        if query.correctedDatesOnly {
            sql += " AND date_corrected = 1"
        }
        if query.blurryOnly {
            sql += " AND id IN (SELECT media_id FROM analysis WHERE sharpness IS NOT NULL AND sharpness < ?)"
            binds.append(.real(query.blurryThreshold))
        }
        if query.unknownDateOnly {
            sql += " AND taken_year IS NULL"
        } else {
            if let year = query.year {
                sql += " AND taken_year = ?"
                binds.append(.int(Int64(year)))
            }
            if let month = query.month {
                sql += " AND taken_month = ?"
                binds.append(.int(Int64(month)))
            }
        }
        sql += " ORDER BY id ASC"
        var items: [MediaItem] = []
        try connection.query(sql, binds) { statement in
            if let item = Self.decode(statement) {
                items.append(item)
            }
        }
        return items
    }

    public func summary() throws -> LibrarySummary {
        let total = try count("SELECT COUNT(*) FROM media")
        let unknown = try count("SELECT COUNT(*) FROM media WHERE taken_year IS NULL")
        var kinds: [MediaType: Int] = [:]
        try connection.query("SELECT kind, COUNT(*) FROM media GROUP BY kind") { statement in
            if let kind = MediaType(rawValue: statement.text(0)) {
                kinds[kind] = Int(statement.int(1))
            }
        }
        var dates: [DateBucket] = []
        try connection.query(
            """
            SELECT taken_year, taken_month, COUNT(*)
            FROM media
            WHERE taken_year IS NOT NULL AND taken_month IS NOT NULL
            GROUP BY taken_year, taken_month
            """
        ) { statement in
            dates.append(DateBucket(year: Int(statement.int(0)), month: Int(statement.int(1)), count: Int(statement.int(2))))
        }
        let screenshots = try count("SELECT COUNT(*) FROM analysis WHERE is_screenshot = 1")
        let qr = try count("SELECT COUNT(*) FROM analysis WHERE has_qr = 1")
        let slips = try count("SELECT COUNT(*) FROM analysis WHERE is_bank_slip = 1")
        let buddhist = try count("SELECT COUNT(*) FROM media WHERE date_corrected = 1")
        let folders = try folders()
        var folderCounts: [Int64: Int] = [:]
        try connection.query("SELECT folder_id, COUNT(*) FROM media GROUP BY folder_id") { statement in
            folderCounts[statement.int(0)] = Int(statement.int(1))
        }
        var directories: [Int64: [DirectoryCount]] = [:]
        try connection.query(
            "SELECT folder_id, parent_relative, COUNT(*) FROM media GROUP BY folder_id, parent_relative"
        ) { statement in
            let folderID = statement.int(0)
            let entry = DirectoryCount(parentRelative: statement.text(1), count: Int(statement.int(2)))
            directories[folderID, default: []].append(entry)
        }
        return LibrarySummary(
            totalCount: total,
            unknownDateCount: unknown,
            kindCounts: kinds,
            dateBuckets: dates,
            folders: folders,
            folderCounts: folderCounts,
            directoryCounts: directories,
            screenshotCount: screenshots,
            qrCount: qr,
            bankSlipCount: slips,
            buddhistDateCount: buddhist
        )
    }

    private func count(_ sql: String) throws -> Int {
        var value = 0
        try connection.query(sql) { statement in
            value = Int(statement.int(0))
        }
        return value
    }

    private static func likePrefix(_ prefix: String) -> String {
        var escaped = ""
        for character in prefix {
            if character == "\\" || character == "%" || character == "_" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        escaped.append("/%")
        return escaped
    }

    private static func decode(_ statement: Statement) -> MediaItem? {
        guard let kind = MediaType(rawValue: statement.text(6)) else { return nil }
        return MediaItem(
            id: statement.int(0),
            folderID: statement.int(1),
            path: statement.text(2),
            relativePath: statement.text(3),
            filename: statement.text(4),
            parentRelative: statement.text(5),
            kind: kind,
            fileSize: statement.int(7),
            createdAt: statement.intOrNil(8).map(Timestamp.date(milliseconds:)),
            modifiedAt: Timestamp.date(milliseconds: statement.int(9)),
            dateTaken: statement.intOrNil(10).map(Timestamp.date(milliseconds:)),
            takenYear: statement.intOrNil(11).map(Int.init),
            takenMonth: statement.intOrNil(12).map(Int.init),
            pixelWidth: statement.intOrNil(13).map(Int.init),
            pixelHeight: statement.intOrNil(14).map(Int.init),
            duration: statement.doubleOrNil(15),
            videoCodec: statement.textOrNil(16),
            audioCodec: statement.textOrNil(17),
            cameraModel: statement.textOrNil(18),
            formatName: statement.textOrNil(19),
            indexedAt: Timestamp.date(milliseconds: statement.int(20)),
            dateCorrected: statement.int(21) != 0,
            metadataReady: statement.int(22) != 0
        )
    }
}
