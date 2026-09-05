import Foundation
import SQLite3

struct NaviDuplicateCleanupResult {
    let removedItems: Int
    let removedFiles: [String]
    let databaseURL: URL

    var summary: String {
        removedItems == 0
            ? "No duplicate, ghost, or obsolete low-quality Navi Music Sync tracks were found."
            : "Removed \(removedItems) duplicate/legacy/obsolete track record(s) and \(removedFiles.count) obsolete audio file(s)."
    }
}

enum NaviDuplicateCleanupError: LocalizedError {
    case openFailed
    case sqlFailed(String)
    case integrityFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed: return "Could not open the Music database for duplicate cleanup."
        case .sqlFailed(let detail): return "Duplicate cleanup database error: \(detail)"
        case .integrityFailed(let result): return "Music database failed quick_check after duplicate cleanup: \(result)"
        }
    }
}

/// Consolidates only records that can be identified as Navi Music Sync-owned.
///
/// There are three generations we can identify safely:
/// - legacy 12-character filenames: broken early test imports, always removed;
/// - 16-hex MP3 imports created before the source-preserving build shipped:
///   these were produced by the temporary forced-transcode pipeline and are
///   removed even when they are the only copy, so they can be re-imported from
///   Navidrome at original quality;
/// - current 16-hex imports: grouped by Navidrome hash and deduplicated, keeping
///   the newest/best original-format row.
final class NaviDuplicateCleanupService {
    /// Commit 7a364a1 switched injection from forced MP3 transcoding to original
    /// source bytes. Imports before this moment are test-generation assets.
    /// 2026-09-05 08:11:49 UTC.
    private let sourcePreservingCutoff: Int64 = 1_788_595_909

    private struct Candidate {
        let pid: Int64
        let filename: String
        let stem: String
        let ext: String
        let dateAdded: Int64
        let legacy12: Bool

        var obsoleteForcedMP3: Bool {
            !legacy12 && ext == "mp3" && dateAdded > 0 && dateAdded < 1_788_595_909
        }
    }

    func clean(databaseURL: URL) throws -> NaviDuplicateCleanupResult {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            if db != nil { sqlite3_close(db) }
            throw NaviDuplicateCleanupError.openFailed
        }
        defer { sqlite3_close(db) }

        let candidates = try ownedCandidates(db)
        var remove = [Candidate]()

        remove.append(contentsOf: candidates.filter { $0.legacy12 || isObsoleteForcedMP3($0) })
        var removePIDs = Set(remove.map(\.pid))

        // Deduplicate only among current-generation survivors. Newest record is
        // the primary signal because the source-preserving import is now our
        // validated path. Format quality is a tie-breaker, not the other way
        // around; this avoids preserving an old test row just because its file
        // extension happens to look "better".
        let modern = candidates.filter { !$0.legacy12 && !removePIDs.contains($0.pid) }
        let groups = Dictionary(grouping: modern, by: \.stem)
        for (_, group) in groups where group.count > 1 {
            let sorted = group.sorted {
                if $0.dateAdded != $1.dateAdded { return $0.dateAdded > $1.dateAdded }
                let lhs = qualityRank($0.ext)
                let rhs = qualityRank($1.ext)
                if lhs != rhs { return lhs > rhs }
                return $0.pid > $1.pid
            }
            for candidate in sorted.dropFirst() where !removePIDs.contains(candidate.pid) {
                remove.append(candidate)
                removePIDs.insert(candidate.pid)
            }
        }

        let survivingFilenames = Set(candidates.filter { !removePIDs.contains($0.pid) }.map(\.filename))
        let removableFiles = Array(Set(remove.map(\.filename)).subtracting(survivingFilenames)).sorted()

        guard !remove.isEmpty else {
            return NaviDuplicateCleanupResult(removedItems: 0, removedFiles: [], databaseURL: databaseURL)
        }

        try exec(db, "BEGIN IMMEDIATE")
        do {
            let childTables = ["lyrics", "chapter", "item_video", "item_search", "item_store", "item_stats", "item_playback", "item_extra"]
            for candidate in remove {
                // Artwork is album-level on current iOS and is intentionally not
                // deleted here; a surviving track from the album may still use it.
                for table in childTables where try tableExists(db, table) {
                    try exec(db, "DELETE FROM \(table) WHERE item_pid = \(candidate.pid)")
                }
                try exec(db, "DELETE FROM item WHERE item_pid = \(candidate.pid)")
            }

            if try tableExists(db, "album") {
                try exec(db, "DELETE FROM album WHERE NOT EXISTS (SELECT 1 FROM item WHERE item.album_pid = album.album_pid)")
            }
            if try tableExists(db, "item_artist") {
                try exec(db, "DELETE FROM item_artist WHERE NOT EXISTS (SELECT 1 FROM item WHERE item.item_artist_pid = item_artist.item_artist_pid)")
            }
            if try tableExists(db, "album_artist") {
                try exec(db, "DELETE FROM album_artist WHERE NOT EXISTS (SELECT 1 FROM item WHERE item.album_artist_pid = album_artist.album_artist_pid)")
            }
            if try tableExists(db, "genre") {
                try exec(db, "DELETE FROM genre WHERE NOT EXISTS (SELECT 1 FROM item WHERE item.genre_id = genre.genre_id)")
            }

            try exec(db, "COMMIT")
            _ = sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
            _ = sqlite3_exec(db, "PRAGMA journal_mode=DELETE", nil, nil, nil)
            let check = try scalarText(db, "PRAGMA quick_check") ?? "unknown"
            guard check == "ok" else { throw NaviDuplicateCleanupError.integrityFailed(check) }
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }

        return NaviDuplicateCleanupResult(removedItems: remove.count, removedFiles: removableFiles, databaseURL: databaseURL)
    }

    private func isObsoleteForcedMP3(_ candidate: Candidate) -> Bool {
        !candidate.legacy12 && candidate.ext == "mp3" && candidate.dateAdded > 0 && candidate.dateAdded < sourcePreservingCutoff
    }

    private func ownedCandidates(_ db: OpaquePointer) throws -> [Candidate] {
        let sql = """
        SELECT item.item_pid, item_extra.location, COALESCE(item.date_added, 0)
        FROM item JOIN item_extra ON item.item_pid = item_extra.item_pid
        WHERE item.base_location_id = 3840
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        var result = [Candidate]()
        let supported = Set(["mp3", "m4a", "aac", "flac", "opus", "wav", "wave", "alac", "m4r"])
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 1) else { continue }
            let filename = String(cString: raw)
            let url = URL(fileURLWithPath: filename)
            let stem = url.deletingPathExtension().lastPathComponent.uppercased()
            let ext = url.pathExtension.lowercased()
            guard supported.contains(ext) else { continue }
            let old12 = stem.count == 12 && stem.allSatisfy { $0.isNumber || ($0 >= "A" && $0 <= "Z") }
            let hash16 = stem.count == 16 && stem.allSatisfy { $0.isNumber || ($0 >= "A" && $0 <= "F") }
            guard old12 || hash16 else { continue }
            result.append(Candidate(
                pid: sqlite3_column_int64(statement, 0), filename: filename, stem: stem, ext: ext,
                dateAdded: sqlite3_column_int64(statement, 2), legacy12: old12
            ))
        }
        return result
    }

    private func qualityRank(_ ext: String) -> Int {
        switch ext.lowercased() {
        case "flac", "alac", "wav", "wave": return 4
        case "m4a", "aac": return 3
        case "mp3": return 2
        case "opus": return 1
        default: return 0
        }
    }

    private func tableExists(_ db: OpaquePointer, _ table: String) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?", -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, table, -1, SQLITE_TRANSIENT)
        return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int64(statement, 0) > 0
    }

    private func scalarText(_ db: OpaquePointer, _ sql: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let detail = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let error { sqlite3_free(error) }
            throw NaviDuplicateCleanupError.sqlFailed(detail)
        }
    }

    private func sqlError(_ db: OpaquePointer) -> NaviDuplicateCleanupError {
        .sqlFailed(String(cString: sqlite3_errmsg(db)))
    }
}
