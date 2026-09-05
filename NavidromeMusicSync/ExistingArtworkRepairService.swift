import Foundation
import SQLite3

enum ExistingArtworkRepairError: LocalizedError {
    case openFailed
    case unsupportedSchema
    case sqlFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed: return "Could not open the Music database for artwork repair."
        case .unsupportedSchema: return "This Music database does not expose the artwork mapping tables required for repair."
        case .sqlFailed(let detail): return "Existing artwork repair failed: \(detail)"
        }
    }
}

struct ExistingArtworkRepairResult {
    let databaseURL: URL
    let repairedTracks: Int
    let skippedTracks: Int

    var summary: String {
        if repairedTracks == 0 {
            return "No existing Navi tracks needed an artwork repair. \(skippedTracks) Navi tracks had no usable album artwork token."
        }
        return "Repaired song and artist artwork mappings for \(repairedTracks) existing Navi track(s). \(skippedTracks) track(s) were skipped because no album artwork token was available."
    }
}

final class ExistingArtworkRepairService {
    func repair(databaseURL: URL) throws -> ExistingArtworkRepairResult {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            if handle != nil { sqlite3_close(handle) }
            throw ExistingArtworkRepairError.openFailed
        }
        defer { sqlite3_close(db) }

        guard try tableExists(db, "item"), try tableExists(db, "item_extra"), try tableExists(db, "best_artwork_token") else {
            throw ExistingArtworkRepairError.unsupportedSchema
        }

        let tracks = try naviTracks(db)
        var repaired = 0
        var skipped = 0

        try exec(db, "BEGIN IMMEDIATE")
        do {
            for track in tracks {
                guard let albumToken = try albumArtworkToken(db, albumPID: track.albumPID), !albumToken.isEmpty else {
                    skipped += 1
                    continue
                }

                try exec(db, "DELETE FROM best_artwork_token WHERE entity_pid = \(track.itemPID) AND entity_type = 1 AND artwork_type = 5")
                try upsertArtwork(db, entityPID: track.itemPID, entityType: 0, artworkType: 1, token: albumToken)
                if track.artistPID > 0 {
                    try upsertArtwork(db, entityPID: track.artistPID, entityType: 2, artworkType: 1, token: albumToken)
                }
                repaired += 1
            }
            try exec(db, "COMMIT")
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }

        _ = sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
        _ = sqlite3_exec(db, "PRAGMA journal_mode=DELETE", nil, nil, nil)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0),
              String(cString: raw) == "ok" else {
            throw ExistingArtworkRepairError.sqlFailed("PRAGMA quick_check did not return ok")
        }

        return ExistingArtworkRepairResult(databaseURL: databaseURL, repairedTracks: repaired, skippedTracks: skipped)
    }

    private struct Track {
        let itemPID: Int64
        let albumPID: Int64
        let artistPID: Int64
    }

    private func naviTracks(_ db: OpaquePointer) throws -> [Track] {
        let sql = "SELECT i.item_pid, i.album_pid, i.item_artist_pid, e.location FROM item i JOIN item_extra e ON e.item_pid = i.item_pid"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }

        var result: [Track] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let itemPID = sqlite3_column_int64(statement, 0)
            let albumPID = sqlite3_column_int64(statement, 1)
            let artistPID = sqlite3_column_int64(statement, 2)
            guard let raw = sqlite3_column_text(statement, 3) else { continue }
            let location = String(cString: raw)
            let filename = URL(fileURLWithPath: location).lastPathComponent
            let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            guard stem.count == 16, stem.allSatisfy({ "0123456789ABCDEF".contains($0) }) else { continue }
            result.append(Track(itemPID: itemPID, albumPID: albumPID, artistPID: artistPID))
        }
        return result
    }

    private func albumArtworkToken(_ db: OpaquePointer, albumPID: Int64) throws -> String? {
        var statement: OpaquePointer?
        let sql = "SELECT available_artwork_token FROM best_artwork_token WHERE entity_pid = ? AND entity_type = 4 AND artwork_type = 6 ORDER BY artwork_variant_type LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, albumPID)
        guard sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: raw)
    }

    private func upsertArtwork(_ db: OpaquePointer, entityPID: Int64, entityType: Int64, artworkType: Int64, token: String) throws {
        let columns = try tableColumns(db, "best_artwork_token")
        let hasVariant = columns.contains("artwork_variant_type")
        let sql: String
        if hasVariant {
            sql = "INSERT OR REPLACE INTO best_artwork_token (entity_pid, entity_type, artwork_type, available_artwork_token, fetchable_artwork_token, fetchable_artwork_source_type, artwork_variant_type) VALUES (?, ?, ?, ?, '', 0, 0)"
        } else {
            sql = "INSERT OR REPLACE INTO best_artwork_token (entity_pid, entity_type, artwork_type, available_artwork_token, fetchable_artwork_token, fetchable_artwork_source_type) VALUES (?, ?, ?, ?, '', 0)"
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, entityPID)
        sqlite3_bind_int64(statement, 2, entityType)
        sqlite3_bind_int64(statement, 3, artworkType)
        sqlite3_bind_text(statement, 4, token, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqlError(db) }
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
        while sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 1) { result.insert(String(cString: raw)) }
        return result
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let detail = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let error { sqlite3_free(error) }
            throw ExistingArtworkRepairError.sqlFailed(detail)
        }
    }

    private func sqlError(_ db: OpaquePointer) -> ExistingArtworkRepairError {
        .sqlFailed(String(cString: sqlite3_errmsg(db)))
    }
}
