import Foundation
import SQLite3

/// Read/write VS Code-style `state.vscdb` ItemTable rows (Cursor, Copilot, Antigravity, Kiro).
enum VscdbStore {
    static func readString(dbURL: URL, key: String) -> String? {
        let path = dbURL.path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        if let cstr = sqlite3_column_text(stmt, 0) {
            let value = String(cString: cstr).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        let bytes = sqlite3_column_bytes(stmt, 0)
        if bytes > 0, let blob = sqlite3_column_blob(stmt, 0) {
            let data = Data(bytes: blob, count: Int(bytes))
            let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty == false) ? value : nil
        }
        return nil
    }

    static func writeString(dbURL: URL, key: String, value: String) throws {
        try FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let path = dbURL.path
        if !FileManager.default.fileExists(atPath: path) {
            var createDB: OpaquePointer?
            guard sqlite3_open(path, &createDB) == SQLITE_OK else {
                sqlite3_close(createDB)
                throw VscdbError.openFailed(path)
            }
            defer { sqlite3_close(createDB) }
            let createSQL = "CREATE TABLE IF NOT EXISTS ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)"
            if sqlite3_exec(createDB, createSQL, nil, nil, nil) != SQLITE_OK {
                throw VscdbError.initFailed(path)
            }
        }

        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw VscdbError.openFailed(path)
        }
        defer { sqlite3_close(db) }

        let sql = "INSERT INTO ItemTable (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VscdbError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        let valueData = Data(value.utf8)
        valueData.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self).baseAddress
            sqlite3_bind_blob(stmt, 2, ptr, Int32(valueData.count), SQLITE_TRANSIENT)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            throw VscdbError.writeFailed(msg)
        }
    }

    enum VscdbError: LocalizedError {
        case openFailed(String)
        case initFailed(String)
        case prepareFailed
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let path): return "Could not open state database at \(path)"
            case .initFailed(let path): return "Could not initialize state database at \(path)"
            case .prepareFailed: return "Could not prepare state database write"
            case .writeFailed(let msg): return "State database write failed: \(msg)"
            }
        }
    }
}
