import Foundation
import SQLite3

enum MusicRecordPostProcessorError: LocalizedError {
    case openFailed
    case sqlFailed(String)
    case integrityFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed: return "Could not open the Music database for final record cleanup."
        case .sqlFailed(let detail): return "Music record cleanup failed: \(detail)"
        case .integrityFailed(let result): return "Music database failed quick_check after cleanup: \(result)"
        }
    }
}

/// Finalizes a locally inserted track for iOS 26 and removes older records that
/// point at the same deterministic Navidrome-owned file.
final class MusicRecordPostProcessor {
    func finalize(databaseURL: URL, currentItemPID: Int64, remoteFilename: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            if db != nil { sqlite3_close(db) }
            throw MusicRecordPostProcessorError.openFailed
        }
        defer { sqlite3_close(db) }

        try exec(db, "BEGIN IMMEDIATE")
        do {
            let duplicates = try itemPIDs(db, location: remoteFilename).filter { $0 != currentItemPID }
            for pid in duplicates {
                for table in ["lyrics", "chapter", "item_video", "item_search", "item_store", "item_stats", "item_playback", "item_extra", "item"] {
                    if try tableExists(db, table) {
                        try exec(db, "DELETE FROM \(table) WHERE item_pid = \(pid)")
                    }
                }
            }

            // Ensure this is treated strictly as a local synced asset, not an
            // Apple catalog/subscription item. Only touch columns present on the
            // device's schema.
            if try tableExists(db, "item_store") {
                let values: [String: Int64] = [
                    "sync_in_my_library": 1,
                    "is_subscription": 0,
                    "store_saga_id": 0,
                    "cloud_status": 0,
                    "store_item_id": 0,
                    "storefront_id": 0,
                    "store_composer_id": 0,
                    "store_genre_id": 0,
                    "store_playlist_id": 0,
                    "date_released": 0,
                    "subscription_store_item_id": 0,
                    "is_mastered_for_itunes": 0,
                    "cloud_asset_available": 0,
                    "cloud_in_my_library": 0,
                    "playback_endpoint_type": 0,
                    "cloud_playback_endpoint_type": 0
                ]
                for (column, value) in values where try columnExists(db, table: "item_store", column: column) {
                    try exec(db, "UPDATE item_store SET \(column) = \(value) WHERE item_pid = \(currentItemPID)")
                }
                for column in ["match_redownload_params", "store_xid", "store_flavor"] where try columnExists(db, table: "item_store", column: column) {
                    try exec(db, "UPDATE item_store SET \(column) = '' WHERE item_pid = \(currentItemPID)")
                }
            }

            // ByeTunes creates item_video even for normal audio on modern iOS.
            if try tableExists(db, "item_video") {
                let hasTraits = try columnExists(db, table: "item_video", column: "hls_asset_traits")
                if hasTraits {
                    try exec(db, "INSERT OR REPLACE INTO item_video (item_pid, hls_asset_traits) VALUES (\(currentItemPID), 0)")
                } else {
                    try exec(db, "INSERT OR REPLACE INTO item_video (item_pid) VALUES (\(currentItemPID))")
                }
            }

            try exec(db, "COMMIT")
            _ = sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
            _ = sqlite3_exec(db, "PRAGMA journal_mode=DELETE", nil, nil, nil)

            let check = try scalarText(db, "PRAGMA quick_check") ?? "unknown"
            guard check == "ok" else { throw MusicRecordPostProcessorError.integrityFailed(check) }
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func itemPIDs(_ db: OpaquePointer, location: String) throws -> [Int64] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT item_pid FROM item_extra WHERE location = ?", -1, &statement, nil) == SQLITE_OK else {
            throw sqlError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, location, -1, SQLITE_TRANSIENT)
        var result: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(sqlite3_column_int64(statement, 0))
        }
        return result
    }

    private func tableExists(_ db: OpaquePointer, _ table: String) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?", -1, &statement, nil) == SQLITE_OK else {
            throw sqlError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, table, -1, SQLITE_TRANSIENT)
        return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int64(statement, 0) > 0
    }

    private func columnExists(_ db: OpaquePointer, table: String, column: String) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1), String(cString: name) == column { return true }
        }
        return false
    }

    private func scalarText(_ db: OpaquePointer, _ sql: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let error { sqlite3_free(error) }
            throw MusicRecordPostProcessorError.sqlFailed(message)
        }
    }

    private func sqlError(_ db: OpaquePointer) -> MusicRecordPostProcessorError {
        .sqlFailed(String(cString: sqlite3_errmsg(db)))
    }
}
