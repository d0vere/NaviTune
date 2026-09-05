import Foundation
import SQLite3

struct ExistingGenreRepairResult {
    let databaseURL: URL
    let repairedTracks: Int
    let skippedTracks: Int

    var summary: String {
        if repairedTracks == 0 {
            return "No existing Navi track genres could be repaired. \(skippedTracks) track(s) had no matching Navidrome genre."
        }
        return "Repaired genres for \(repairedTracks) existing Navi track(s). \(skippedTracks) track(s) had no matching Navidrome genre."
    }
}

enum ExistingGenreRepairError: LocalizedError {
    case openFailed
    case unsupportedSchema
    case sqlFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed: return "Could not open the Music database for genre repair."
        case .unsupportedSchema: return "This Music database does not expose the genre tables required for repair."
        case .sqlFailed(let detail): return "Existing genre repair failed: \(detail)"
        }
    }
}

/// Looks up the original Navidrome genre for Navi-owned tracks and updates only
/// the Music metadata rows. Audio files are never read, rewritten, or copied.
final class ExistingGenreRepairService {
    func repair(databaseURL: URL) throws -> ExistingGenreRepairResult {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            if handle != nil { sqlite3_close(handle) }
            throw ExistingGenreRepairError.openFailed
        }

        guard try tableExists(db, "item"), try tableExists(db, "item_extra"),
              try tableExists(db, "item_artist"), try tableExists(db, "album"),
              try tableExists(db, "genre"), try tableExists(db, "sort_map") else {
            sqlite3_close(db)
            throw ExistingGenreRepairError.unsupportedSchema
        }

        let tracks = try naviTracks(db)
        sqlite3_close(db)

        // Network lookup happens with the database closed, so a slow Navidrome
        // response can never hold a Music SQLite write transaction open.
        var matches: [(Track, String)] = []
        var skipped = 0
        var cache: [String: NavidromeMatchedMetadata?] = [:]
        for track in tracks {
            let key = "\(track.title.lowercased())|\(track.artist.lowercased())|\(track.album.lowercased())"
            let metadata: NavidromeMatchedMetadata?
            if let cached = cache[key] {
                metadata = cached
            } else {
                let found = NavidromeMetadataLookup.lookup(title: track.title, artist: track.artist, album: track.album)
                cache[key] = found
                metadata = found
            }
            guard let metadata else {
                skipped += 1
                continue
            }
            matches.append((track, metadata.genre))
        }

        guard !matches.isEmpty else {
            return ExistingGenreRepairResult(databaseURL: databaseURL, repairedTracks: 0, skippedTracks: skipped)
        }

        var writeHandle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &writeHandle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let writeDB = writeHandle else {
            if writeHandle != nil { sqlite3_close(writeHandle) }
            throw ExistingGenreRepairError.openFailed
        }
        defer { sqlite3_close(writeDB) }

        try exec(writeDB, "BEGIN IMMEDIATE")
        do {
            for (track, genre) in matches {
                let ref = try ensureGenre(writeDB, name: genre, representativeItemPID: track.itemPID)
                try exec(writeDB, "UPDATE item SET genre_id = \(ref.id), genre_order = \(ref.order), genre_order_section = \(ref.section) WHERE item_pid = \(track.itemPID)")
            }
            try exec(writeDB, "COMMIT")
        } catch {
            _ = sqlite3_exec(writeDB, "ROLLBACK", nil, nil, nil)
            throw error
        }

        _ = sqlite3_exec(writeDB, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
        _ = sqlite3_exec(writeDB, "PRAGMA journal_mode=DELETE", nil, nil, nil)
        let check = try scalarText(writeDB, "PRAGMA quick_check") ?? "unknown"
        guard check == "ok" else { throw ExistingGenreRepairError.sqlFailed("PRAGMA quick_check returned \(check)") }

        return ExistingGenreRepairResult(databaseURL: databaseURL, repairedTracks: matches.count, skippedTracks: skipped)
    }

    private struct Track {
        let itemPID: Int64
        let title: String
        let artist: String
        let album: String
    }

    private func naviTracks(_ db: OpaquePointer) throws -> [Track] {
        let sql = """
        SELECT i.item_pid, e.title, COALESCE(ia.item_artist,''), COALESCE(a.album,''), e.location
        FROM item i
        JOIN item_extra e ON e.item_pid = i.item_pid
        LEFT JOIN item_artist ia ON ia.item_artist_pid = i.item_artist_pid
        LEFT JOIN album a ON a.album_pid = i.album_pid
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        var result: [Track] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let titleRaw = sqlite3_column_text(statement, 1),
                  let artistRaw = sqlite3_column_text(statement, 2),
                  let albumRaw = sqlite3_column_text(statement, 3),
                  let locationRaw = sqlite3_column_text(statement, 4) else { continue }
            let location = String(cString: locationRaw)
            let stem = URL(fileURLWithPath: location).deletingPathExtension().lastPathComponent
            guard stem.count == 16, stem.allSatisfy({ "0123456789ABCDEF".contains($0) }) else { continue }
            result.append(Track(
                itemPID: sqlite3_column_int64(statement, 0),
                title: String(cString: titleRaw),
                artist: String(cString: artistRaw),
                album: String(cString: albumRaw)
            ))
        }
        return result
    }

    private func ensureGenre(_ db: OpaquePointer, name: String, representativeItemPID: Int64) throws -> (id: Int64, order: Int64, section: Int64) {
        let escaped = sqlLiteral(name)
        let id = try scalarInt64(db, "SELECT genre_id FROM genre WHERE genre = \(escaped) LIMIT 1")
            ?? ((try scalarInt64(db, "SELECT COALESCE(MAX(genre_id),0)+1 FROM genre")) ?? 1)
        if try scalarInt64(db, "SELECT COUNT(*) FROM genre WHERE genre_id = \(id)") == 0 {
            try exec(db, "INSERT INTO genre (genre_id, genre, representative_item_pid) VALUES (\(id), \(escaped), \(representativeItemPID))")
        }

        if let order = try scalarInt64(db, "SELECT name_order FROM sort_map WHERE name = \(escaped) LIMIT 1"),
           let section = try scalarInt64(db, "SELECT name_section FROM sort_map WHERE name = \(escaped) LIMIT 1") {
            return (id, order, section)
        }
        let order = (try scalarInt64(db, "SELECT COALESCE(MAX(name_order),0)+1 FROM sort_map")) ?? 1
        let section = Int64(sectionForName(name))
        try exec(db, "INSERT INTO sort_map (name, sort_key, name_order, name_section) VALUES (\(escaped), \(sqlLiteral(name.uppercased())), \(order), \(section))")
        return (id, order, section)
    }

    private func sectionForName(_ name: String) -> Int {
        guard let first = name.uppercased().unicodeScalars.first else { return 26 }
        let value = Int(first.value)
        return (65...90).contains(value) ? value - 65 : 26
    }

    private func sqlLiteral(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "''"))'" }

    private func tableExists(_ db: OpaquePointer, _ table: String) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?", -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, table, -1, SQLITE_TRANSIENT)
        return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int64(statement, 0) > 0
    }

    private func scalarInt64(_ db: OpaquePointer, _ sql: String) throws -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func scalarText(_ db: OpaquePointer, _ sql: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: raw)
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let detail = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let error { sqlite3_free(error) }
            throw ExistingGenreRepairError.sqlFailed(detail)
        }
    }

    private func sqlError(_ db: OpaquePointer) -> ExistingGenreRepairError {
        .sqlFailed(String(cString: sqlite3_errmsg(db)))
    }
}
