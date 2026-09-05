import Foundation
import SQLite3

struct MusicLibraryStageReport {
    let databaseURL: URL
    let userVersion: Int32
    let tableNames: [String]

    var summary: String {
        "Local staging OK. SQLite user_version=\(userVersion), tables=\(tableNames.count)."
    }
}

enum MusicLibraryStageError: LocalizedError {
    case openFailed
    case integrityFailed(String)
    case requiredSchemaMissing([String])
    case copyFailed

    var errorDescription: String? {
        switch self {
        case .openFailed:
            return "Could not open the staged Music database."
        case .integrityFailed(let result):
            return "The staged Music database failed PRAGMA quick_check: \(result)."
        case .requiredSchemaMissing(let names):
            return "The Music database schema is not compatible yet. Missing tables: \(names.joined(separator: ", "))."
        case .copyFailed:
            return "Could not create a protected working copy of MediaLibrary.sqlitedb."
        }
    }
}

final class MusicLibraryStager {
    private static let requiredTables: Set<String> = [
        "item",
        "item_artist",
        "album",
        "genre",
        "base_location",
        "sort_map"
    ]

    func prepareWorkingCopy(from snapshotURL: URL) throws -> MusicLibraryStageReport {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("music-library-stage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        let workURL = workDir.appendingPathComponent("MediaLibrary.sqlitedb")
        do {
            try fm.copyItem(at: snapshotURL, to: workURL)
        } catch {
            throw MusicLibraryStageError.copyFailed
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(workURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            if db != nil { sqlite3_close(db) }
            throw MusicLibraryStageError.openFailed
        }
        defer { sqlite3_close(db) }

        let integrity = try scalarText(db: db, sql: "PRAGMA quick_check") ?? "unknown"
        guard integrity == "ok" else {
            throw MusicLibraryStageError.integrityFailed(integrity)
        }

        _ = sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
        _ = sqlite3_exec(db, "PRAGMA journal_mode=DELETE", nil, nil, nil)

        let tables = try allTables(db: db)
        let tableSet = Set(tables)
        let missing = Self.requiredTables.subtracting(tableSet).sorted()
        guard missing.isEmpty else {
            throw MusicLibraryStageError.requiredSchemaMissing(missing)
        }

        let userVersion = try scalarInt32(db: db, sql: "PRAGMA user_version")

        // Verify that a transaction can be opened and rolled back on the local copy.
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw MusicLibraryStageError.openFailed
        }
        _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)

        return MusicLibraryStageReport(databaseURL: workURL, userVersion: userVersion, tableNames: tables)
    }

    private func allTables(db: OpaquePointer) throws -> [String] {
        var statement: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MusicLibraryStageError.openFailed
        }
        defer { sqlite3_finalize(statement) }

        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) {
                result.append(String(cString: value))
            }
        }
        return result
    }

    private func scalarText(db: OpaquePointer, sql: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MusicLibraryStageError.openFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    private func scalarInt32(db: OpaquePointer, sql: String) throws -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MusicLibraryStageError.openFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(statement, 0)
    }
}
