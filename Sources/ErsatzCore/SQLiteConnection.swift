import Foundation
import CSQLite

public enum DatabaseError: Error, LocalizedError, Equatable {
    case open(String)
    case sqlite(code: Int32, message: String)
    case duplicate(String)
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .open(let message):
            return "Couldn't open the library database. \(message)"
        case .sqlite(_, let message):
            return message
        case .duplicate(let message):
            return message
        case .unsupportedVersion(let version):
            return "This library was written by a newer version of Ersatz (schema \(version))."
        }
    }
}

enum SQLValue: Equatable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

final class SQLiteConnection {
    private var db: OpaquePointer?

    init(path: String) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let code = path.withCString { sqlite3_open_v2($0, &handle, flags, nil) }
        guard code == SQLITE_OK, let handle else {
            let message = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unable to open database"
            if let handle { sqlite3_close(handle) }
            throw DatabaseError.open(message)
        }
        db = handle
        sqlite3_extended_result_codes(handle, 1)
        do {
            try migrate()
        } catch {
            sqlite3_close_v2(handle)
            db = nil
            throw error
        }
    }

    deinit {
        if let db {
            sqlite3_close_v2(db)
        }
    }

    func migrate() throws {
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA busy_timeout = 5000")
        let version = try pragmaInt("user_version")
        if version > 2 {
            throw DatabaseError.unsupportedVersion(version)
        }
        if version == 0 {
            try transaction {
                try execute(Schema.create)
                try execute("PRAGMA user_version = 2")
            }
            return
        }
        if version == 1 {
            try transaction {
                try execute(Schema.upgradeToV2)
                try execute("PRAGMA user_version = 2")
            }
        }
    }

    func execute(_ sql: String) throws {
        guard let db else { throw DatabaseError.open("database is closed") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if code != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "SQLite error \(code)"
            sqlite3_free(errorMessage)
            throw failure(code, fallback: message)
        }
    }

    @discardableResult
    func run(_ sql: String, _ binds: [SQLValue] = []) throws -> Int {
        guard let db else { throw DatabaseError.open("database is closed") }
        let statement = try prepare(sql)
        defer { statement.finalize() }
        try bind(statement, binds)
        try stepDone(statement)
        return Int(sqlite3_changes(db))
    }

    func query(_ sql: String, _ binds: [SQLValue] = [], _ body: (Statement) throws -> Void) throws {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        try bind(statement, binds)
        while true {
            let code = sqlite3_step(statement.pointer)
            if code == SQLITE_ROW {
                try body(statement)
            } else if code == SQLITE_DONE {
                return
            } else {
                throw failure(code, fallback: "query failed")
            }
        }
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var lastInsertID: Int64 {
        guard let db else { return 0 }
        return sqlite3_last_insert_rowid(db)
    }

    private func pragmaInt(_ name: String) throws -> Int {
        var value = 0
        try query("PRAGMA \(name)") { statement in
            value = Int(statement.int(0))
        }
        return value
    }

    private func prepare(_ sql: String) throws -> Statement {
        guard let db else { throw DatabaseError.open("database is closed") }
        var pointer: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &pointer, nil)
        guard code == SQLITE_OK, let pointer else {
            throw failure(code, fallback: "couldn't prepare statement")
        }
        return Statement(pointer: pointer)
    }

    private func bind(_ statement: Statement, _ values: [SQLValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null:
                code = sqlite3_bind_null(statement.pointer, index)
            case .int(let value):
                code = sqlite3_bind_int64(statement.pointer, index, value)
            case .real(let value):
                code = sqlite3_bind_double(statement.pointer, index, value)
            case .text(let value):
                code = bindText(statement, index: index, value: value)
            case .blob(let data):
                code = bindBlob(statement, index: index, data: data)
            }
            if code != SQLITE_OK {
                throw failure(code, fallback: "couldn't bind parameter \(index)")
            }
        }
    }

    private func bindText(_ statement: Statement, index: Int32, value: String) -> Int32 {
        let bytes = Array(value.utf8)
        let allocated = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count + 1)
        bytes.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
                allocated.update(from: base, count: bytes.count)
            }
        }
        allocated[bytes.count] = 0
        return sqlite3_bind_text(
            statement.pointer,
            index,
            UnsafeRawPointer(allocated).assumingMemoryBound(to: CChar.self),
            Int32(bytes.count),
            { pointer in pointer?.deallocate() }
        )
    }

    private func bindBlob(_ statement: Statement, index: Int32, data: Data) -> Int32 {
        if data.isEmpty {
            return sqlite3_bind_blob(statement.pointer, index, nil, 0, nil)
        }
        let allocated = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: 1)
        data.copyBytes(to: allocated.assumingMemoryBound(to: UInt8.self), count: data.count)
        return sqlite3_bind_blob(statement.pointer, index, allocated, Int32(data.count), { pointer in
            pointer?.deallocate()
        })
    }

    private func stepDone(_ statement: Statement) throws {
        let code = sqlite3_step(statement.pointer)
        if code != SQLITE_DONE {
            throw failure(code, fallback: "statement did not complete")
        }
    }

    private func failure(_ code: Int32, fallback: String) -> DatabaseError {
        let extended = db.flatMap { sqlite3_extended_errcode($0) } ?? code
        let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? fallback
        let primary = extended & 0xFF
        if primary == SQLITE_CONSTRAINT {
            return .duplicate(message)
        }
        return .sqlite(code: extended, message: message)
    }
}

final class Statement {
    var pointer: OpaquePointer?
    private var finalized = false

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        finalize()
    }

    func finalize() {
        if let pointer, !finalized {
            sqlite3_finalize(pointer)
        }
        finalized = true
        pointer = nil
    }

    func int(_ index: Int32) -> Int64 {
        sqlite3_column_int64(pointer, index)
    }

    func intOrNil(_ index: Int32) -> Int64? {
        isNull(index) ? nil : int(index)
    }

    func doubleOrNil(_ index: Int32) -> Double? {
        isNull(index) ? nil : sqlite3_column_double(pointer, index)
    }

    func text(_ index: Int32) -> String {
        textOrNil(index) ?? ""
    }

    func textOrNil(_ index: Int32) -> String? {
        guard let pointer, !isNull(index), let value = sqlite3_column_text(pointer, index) else { return nil }
        return String(cString: value)
    }

    func blobOrNil(_ index: Int32) -> Data? {
        guard let pointer, !isNull(index) else { return nil }
        let count = Int(sqlite3_column_bytes(pointer, index))
        guard count > 0, let bytes = sqlite3_column_blob(pointer, index) else {
            return Data()
        }
        return Data(bytes: bytes, count: count)
    }

    private func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(pointer, index) == SQLITE_NULL
    }
}

enum Schema {
    static let create = """
    CREATE TABLE IF NOT EXISTS folders (
        id INTEGER PRIMARY KEY,
        path TEXT NOT NULL UNIQUE,
        bookmark BLOB,
        display_name TEXT NOT NULL,
        added_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS media (
        id INTEGER PRIMARY KEY,
        folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
        path TEXT NOT NULL UNIQUE,
        relative_path TEXT NOT NULL,
        filename TEXT NOT NULL,
        parent_relative TEXT NOT NULL,
        kind TEXT NOT NULL,
        file_size INTEGER NOT NULL,
        created_at INTEGER,
        modified_at INTEGER NOT NULL,
        date_taken INTEGER,
        taken_year INTEGER,
        taken_month INTEGER,
        pixel_width INTEGER,
        pixel_height INTEGER,
        duration REAL,
        video_codec TEXT,
        audio_codec TEXT,
        camera_model TEXT,
        format_name TEXT,
        indexed_at INTEGER NOT NULL,
        date_corrected INTEGER NOT NULL DEFAULT 0,
        metadata_ready INTEGER NOT NULL DEFAULT 0
    );

    CREATE INDEX IF NOT EXISTS idx_media_folder ON media(folder_id);
    CREATE INDEX IF NOT EXISTS idx_media_kind ON media(kind);
    CREATE INDEX IF NOT EXISTS idx_media_taken ON media(taken_year, taken_month);
    CREATE INDEX IF NOT EXISTS idx_media_parent ON media(folder_id, parent_relative);

    CREATE TABLE IF NOT EXISTS analysis (
        media_id INTEGER PRIMARY KEY REFERENCES media(id) ON DELETE CASCADE,
        partial_hash TEXT,
        content_hash TEXT,
        perceptual_hash INTEGER,
        sharpness REAL,
        is_screenshot INTEGER NOT NULL DEFAULT 0,
        has_qr INTEGER NOT NULL DEFAULT 0,
        is_bank_slip INTEGER NOT NULL DEFAULT 0,
        analyzed_mtime INTEGER
    );

    CREATE TABLE IF NOT EXISTS checkpoints (
        id INTEGER PRIMARY KEY,
        created_at INTEGER NOT NULL,
        action TEXT NOT NULL,
        file_count INTEGER NOT NULL,
        note TEXT
    );

    CREATE TABLE IF NOT EXISTS checkpoint_files (
        id INTEGER PRIMARY KEY,
        checkpoint_id INTEGER NOT NULL REFERENCES checkpoints(id) ON DELETE CASCADE,
        path TEXT NOT NULL,
        kind TEXT NOT NULL,
        original_metadata TEXT,
        backup_path TEXT,
        backup_bytes INTEGER NOT NULL DEFAULT 0,
        trash_url TEXT
    );

    CREATE TABLE IF NOT EXISTS activity_log (
        id INTEGER PRIMARY KEY,
        created_at INTEGER NOT NULL,
        action TEXT NOT NULL,
        path TEXT NOT NULL,
        old_value TEXT,
        new_value TEXT,
        checkpoint_id INTEGER,
        success INTEGER NOT NULL,
        restorable INTEGER NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_activity_created ON activity_log(created_at);
    """

    static let upgradeToV2 = """
    ALTER TABLE media ADD COLUMN date_corrected INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE media ADD COLUMN metadata_ready INTEGER NOT NULL DEFAULT 0;
    CREATE TABLE IF NOT EXISTS analysis (
        media_id INTEGER PRIMARY KEY REFERENCES media(id) ON DELETE CASCADE,
        partial_hash TEXT,
        content_hash TEXT,
        perceptual_hash INTEGER,
        sharpness REAL,
        is_screenshot INTEGER NOT NULL DEFAULT 0,
        has_qr INTEGER NOT NULL DEFAULT 0,
        is_bank_slip INTEGER NOT NULL DEFAULT 0,
        analyzed_mtime INTEGER
    );
    CREATE TABLE IF NOT EXISTS checkpoints (
        id INTEGER PRIMARY KEY,
        created_at INTEGER NOT NULL,
        action TEXT NOT NULL,
        file_count INTEGER NOT NULL,
        note TEXT
    );
    CREATE TABLE IF NOT EXISTS checkpoint_files (
        id INTEGER PRIMARY KEY,
        checkpoint_id INTEGER NOT NULL REFERENCES checkpoints(id) ON DELETE CASCADE,
        path TEXT NOT NULL,
        kind TEXT NOT NULL,
        original_metadata TEXT,
        backup_path TEXT,
        backup_bytes INTEGER NOT NULL DEFAULT 0,
        trash_url TEXT
    );
    CREATE TABLE IF NOT EXISTS activity_log (
        id INTEGER PRIMARY KEY,
        created_at INTEGER NOT NULL,
        action TEXT NOT NULL,
        path TEXT NOT NULL,
        old_value TEXT,
        new_value TEXT,
        checkpoint_id INTEGER,
        success INTEGER NOT NULL,
        restorable INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_activity_created ON activity_log(created_at);
    """
}
