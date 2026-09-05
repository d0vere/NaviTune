import Foundation
import SQLite3

enum MusicSortRepairError: LocalizedError {
    case openFailed
    case sqlFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed: return "Could not open the Music database for sort repair."
        case .sqlFailed(let detail): return "Music sort repair failed: \(detail)"
        }
    }
}

/// Rebuilds sort_map ordering and propagates the new numeric order values into
/// item/item_search/album_artist. The visible title in item_extra can be fully
/// correct while Music still sorts by stale title_order values.
///
/// IMPORTANT: sort_map.name_order is UNIQUE on current Music schemas. Updating
/// rows directly from old -> new order can collide mid-statement. The repair
/// therefore moves every name_order into a temporary high range first, then
/// applies the final dense ordering. This makes the operation idempotent and
/// safe even after a previous failed import.
final class MusicSortRepair {
    func repair(databaseURL: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            if handle != nil { sqlite3_close(handle) }
            throw MusicSortRepairError.openFailed
        }
        defer { sqlite3_close(db) }

        try exec(db, "BEGIN IMMEDIATE")
        do {
            try exec(db, """
            UPDATE sort_map SET name_section =
                CASE
                    WHEN UNICODE(UPPER(SUBSTR(name, 1, 1))) BETWEEN 65 AND 90
                    THEN UNICODE(UPPER(SUBSTR(name, 1, 1))) - 65
                    WHEN UNICODE(UPPER(SUBSTR(name, 1, 1))) BETWEEN 192 AND 197 THEN 0
                    WHEN UNICODE(UPPER(SUBSTR(name, 1, 1))) = 199 THEN 2
                    WHEN UNICODE(UPPER(SUBSTR(name, 1, 1))) BETWEEN 200 AND 203 THEN 4
                    WHEN UNICODE(UPPER(SUBSTR(name, 1, 1))) BETWEEN 204 AND 207 THEN 8
                    WHEN UNICODE(UPPER(SUBSTR(name, 1, 1))) = 209 THEN 13
                    WHEN UNICODE(UPPER(SUBSTR(name, 1, 1))) BETWEEN 210 AND 214 THEN 14
                    WHEN UNICODE(UPPER(SUBSTR(name, 1, 1))) BETWEEN 217 AND 220 THEN 20
                    WHEN UNICODE(UPPER(SUBSTR(name, 1, 1))) = 221 THEN 24
                    ELSE 26
                END
            """)

            try exec(db, "DROP TABLE IF EXISTS _sort_reorder")
            try exec(db, """
            CREATE TEMP TABLE _sort_reorder AS
            SELECT name,
                   name_order AS old_order,
                   name_section,
                   ROW_NUMBER() OVER (
                       ORDER BY
                           CASE name_section WHEN 26 THEN 999 ELSE name_section END ASC,
                           sort_key COLLATE NOCASE ASC,
                           name COLLATE NOCASE ASC,
                           name_order ASC
                   ) AS new_order
            FROM sort_map
            """)

            try exec(db, """
            UPDATE item SET
                title_order = COALESCE((SELECT new_order FROM _sort_reorder WHERE old_order = item.title_order), title_order),
                title_order_section = COALESCE((SELECT name_section FROM _sort_reorder WHERE old_order = item.title_order), title_order_section),
                item_artist_order = COALESCE((SELECT new_order FROM _sort_reorder WHERE old_order = item.item_artist_order), item_artist_order),
                item_artist_order_section = COALESCE((SELECT name_section FROM _sort_reorder WHERE old_order = item.item_artist_order), item_artist_order_section),
                album_order = COALESCE((SELECT new_order FROM _sort_reorder WHERE old_order = item.album_order), album_order),
                album_order_section = COALESCE((SELECT name_section FROM _sort_reorder WHERE old_order = item.album_order), album_order_section),
                album_artist_order = COALESCE((SELECT new_order FROM _sort_reorder WHERE old_order = item.album_artist_order), album_artist_order),
                album_artist_order_section = COALESCE((SELECT name_section FROM _sort_reorder WHERE old_order = item.album_artist_order), album_artist_order_section),
                genre_order = COALESCE((SELECT new_order FROM _sort_reorder WHERE old_order = item.genre_order), genre_order),
                genre_order_section = COALESCE((SELECT name_section FROM _sort_reorder WHERE old_order = item.genre_order), genre_order_section)
            """)

            if try tableExists(db, "item_search") {
                try exec(db, """
                UPDATE item_search SET
                    search_title = COALESCE((SELECT new_order FROM _sort_reorder WHERE old_order = item_search.search_title), search_title),
                    search_album = COALESCE((SELECT new_order FROM _sort_reorder WHERE old_order = item_search.search_album), search_album),
                    search_artist = COALESCE((SELECT new_order FROM _sort_reorder WHERE old_order = item_search.search_artist), search_artist),
                    search_album_artist = COALESCE((SELECT new_order FROM _sort_reorder WHERE old_order = item_search.search_album_artist), search_album_artist)
                """)
            }

            if try tableExists(db, "album_artist") {
                let columns = try tableColumns(db, "album_artist")
                if columns.contains("sort_order") {
                    try exec(db, """
                    UPDATE album_artist SET
                        sort_order = COALESCE((SELECT new_order FROM _sort_reorder WHERE old_order = album_artist.sort_order), sort_order),
                        sort_order_section = COALESCE((SELECT name_section FROM _sort_reorder WHERE old_order = album_artist.sort_order), sort_order_section),
                        name_order = COALESCE((SELECT new_order FROM _sort_reorder WHERE old_order = album_artist.name_order), name_order)
                    """)
                }
            }

            // Avoid UNIQUE(name_order) collisions by first moving all rows to a
            // disjoint high range, then assigning the final compact order.
            let maxOrder = try scalarInt64(db, "SELECT COALESCE(MAX(name_order), 0) FROM sort_map")
            let count = try scalarInt64(db, "SELECT COUNT(*) FROM sort_map")
            let offset = maxOrder + count + 10000
            try exec(db, "UPDATE sort_map SET name_order = name_order + \(offset)")
            try exec(db, """
            UPDATE sort_map SET name_order = COALESCE(
                (SELECT new_order FROM _sort_reorder WHERE old_order = sort_map.name_order - \(offset)),
                sort_map.name_order - \(offset)
            )
            """)

            try exec(db, "DROP TABLE IF EXISTS _sort_reorder")
            try exec(db, "COMMIT")
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func scalarInt64(_ db: OpaquePointer, _ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqlError(db) }
        return sqlite3_column_int64(statement, 0)
    }

    private func tableExists(_ db: OpaquePointer, _ table: String) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?", -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, table, -1, SQLITE_TRANSIENT)
        return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int64(statement, 0) > 0
    }

    private func tableColumns(_ db: OpaquePointer, _ table: String) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        var result = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 1) {
            result.insert(String(cString: raw))
        }
        return result
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let detail = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let error { sqlite3_free(error) }
            throw MusicSortRepairError.sqlFailed(detail)
        }
    }

    private func sqlError(_ db: OpaquePointer) -> MusicSortRepairError {
        .sqlFailed(String(cString: sqlite3_errmsg(db)))
    }
}
