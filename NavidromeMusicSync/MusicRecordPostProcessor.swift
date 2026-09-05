import Foundation
import SQLite3

enum MusicRecordPostProcessorError: LocalizedError {
    case openFailed
    case sqlFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed: return "Could not open the Music database for final record cleanup."
        case .sqlFailed(let detail): return "Music record cleanup failed: \(detail)"
        }
    }
}

/// Lightweight finalization for a locally inserted track.
/// The main builder already checkpoints and quick-checks the database, so this
/// pass only performs targeted row updates/de-duplication in one transaction.
final class MusicRecordPostProcessor {
    func finalize(databaseURL: URL, currentItemPID: Int64, remoteFilename: String) throws {
        var dbPointer: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &dbPointer, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db = dbPointer else {
            if let dbPointer { sqlite3_close(dbPointer) }
            throw MusicRecordPostProcessorError.openFailed
        }

        do {
            try exec(db, "BEGIN IMMEDIATE")
            let duplicates = try itemPIDs(db, location: remoteFilename).filter { $0 != currentItemPID }
            for pid in duplicates {
                for table in ["lyrics", "chapter", "item_video", "item_search", "item_store", "item_stats", "item_playback", "item_extra", "item"] {
                    if try tableExists(db, table) {
                        try exec(db, "DELETE FROM \(table) WHERE item_pid = \(pid)")
                    }
                }
            }

            if let genre = InjectionMetadataRegistry.takeGenre(for: remoteFilename),
               try tableExists(db, "genre"), try tableExists(db, "sort_map") {
                let genreRef = try ensureGenre(db, name: genre, representativeItemPID: currentItemPID)
                try exec(db, "UPDATE item SET genre_id = \(genreRef.id), genre_order = \(genreRef.order), genre_order_section = \(genreRef.section) WHERE item_pid = \(currentItemPID)")
            }

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

            if try tableExists(db, "item_video") {
                if try columnExists(db, table: "item_video", column: "hls_asset_traits") {
                    try exec(db, "INSERT OR REPLACE INTO item_video (item_pid, hls_asset_traits) VALUES (\(currentItemPID), 0)")
                } else {
                    try exec(db, "INSERT OR REPLACE INTO item_video (item_pid) VALUES (\(currentItemPID))")
                }
            }

            try exec(db, "COMMIT")
            sqlite3_close(db)
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            sqlite3_close(db)
            throw error
        }

        try MusicSortRepair().repair(databaseURL: databaseURL)
    }

    private func ensureGenre(_ db: OpaquePointer, name: String, representativeItemPID: Int64) throws -> (id: Int64, order: Int64, section: Int64) {
        let escaped = sqlLiteral(name)
        let existingID = try scalarInt64(db, "SELECT genre_id FROM genre WHERE genre = \(escaped) LIMIT 1")
        let genreID: Int64
        if let existingID {
            genreID = existingID
        } else {
            genreID = (try scalarInt64(db, "SELECT COALESCE(MAX(genre_id), 0) + 1 FROM genre")) ?? 1
            try exec(db, "INSERT INTO genre (genre_id, genre, representative_item_pid) VALUES (\(genreID), \(escaped), \(representativeItemPID))")
        }

        if let order = try scalarInt64(db, "SELECT name_order FROM sort_map WHERE name = \(escaped) LIMIT 1"),
           let section = try scalarInt64(db, "SELECT name_section FROM sort_map WHERE name = \(escaped) LIMIT 1") {
            return (genreID, order, section)
        }

        let nextOrder = (try scalarInt64(db, "SELECT COALESCE(MAX(name_order), 0) + 1 FROM sort_map")) ?? 1
        let section = Int64(sectionForName(name))
        let sortKey = sqlLiteral(name.uppercased())
        try exec(db, "INSERT INTO sort_map (name, sort_key, name_order, name_section) VALUES (\(escaped), \(sortKey), \(nextOrder), \(section))")
        return (genreID, nextOrder, section)
    }

    private func sectionForName(_ name: String) -> Int {
        guard let first = name.uppercased().unicodeScalars.first else { return 26 }
        let value = Int(first.value)
        return (65...90).contains(value) ? value - 65 : 26
    }

    private func sqlLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func scalarInt64(_ db: OpaquePointer, _ sql: String) throws -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
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
