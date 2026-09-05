import Foundation
import SwiftUI
import SQLite3

struct MusicLibraryWipeResult {
    let removedItems: Int
    let removedFiles: [String]
}

enum MusicLibraryWipeError: LocalizedError {
    case invalidDatabase
    case openFailed
    case sqlFailed(String)
    case integrityFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidDatabase: return "The staged Music database is not valid SQLite."
        case .openFailed: return "Could not open the Music database for wipe."
        case .sqlFailed(let detail): return "Music library wipe failed: \(detail)"
        case .integrityFailed(let detail): return "Music database failed quick_check after wipe: \(detail)"
        }
    }
}

/// Removes the local Music-library contents while preserving Apple's database
/// schema and required base rows. Ringtones and non-Music base locations are
/// deliberately left alone. The caller keeps a byte-for-byte pre-wipe backup.
final class MusicLibraryWipeService {
    func wipe(databaseURL: URL) throws -> MusicLibraryWipeResult {
        let header = try Data(contentsOf: databaseURL, options: [.mappedIfSafe])
        guard header.starts(with: Data("SQLite format 3\0".utf8)) else { throw MusicLibraryWipeError.invalidDatabase }

        var pointer: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &pointer, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw MusicLibraryWipeError.openFailed
        }
        defer { sqlite3_close(db) }

        let files = try localMusicFiles(db)
        let itemCount = try scalarInt(db, "SELECT COUNT(*) FROM item WHERE base_location_id = 3840")

        try exec(db, "BEGIN IMMEDIATE")
        do {
            // Remove artwork links while the entity relationships still exist.
            if try tableExists(db, "best_artwork_token") {
                try exec(db, "DELETE FROM best_artwork_token WHERE (entity_type = 0 AND entity_pid IN (SELECT item_pid FROM item WHERE base_location_id = 3840)) OR (entity_type = 4 AND entity_pid IN (SELECT album_pid FROM item WHERE base_location_id = 3840)) OR (entity_type = 2 AND entity_pid IN (SELECT item_artist_pid FROM item WHERE base_location_id = 3840))")
            }
            if try tableExists(db, "artwork_token") {
                try exec(db, "DELETE FROM artwork_token WHERE (entity_type = 0 AND entity_pid IN (SELECT item_pid FROM item WHERE base_location_id = 3840)) OR (entity_type = 4 AND entity_pid IN (SELECT album_pid FROM item WHERE base_location_id = 3840)) OR (entity_type = 2 AND entity_pid IN (SELECT item_artist_pid FROM item WHERE base_location_id = 3840))")
            }

            // Schema versions differ. Delete from every child table that exposes
            // item_pid instead of maintaining a brittle hard-coded list.
            for table in try allTables(db) where table != "item" {
                if try columnExists(db, table: table, column: "item_pid") {
                    try exec(db, "DELETE FROM \(quotedIdentifier(table)) WHERE item_pid IN (SELECT item_pid FROM item WHERE base_location_id = 3840)")
                }
            }
            try exec(db, "DELETE FROM item WHERE base_location_id = 3840")

            // Remove now-unreferenced library entities, but keep schema/base rows.
            if try tableExists(db, "album") { try exec(db, "DELETE FROM album WHERE NOT EXISTS (SELECT 1 FROM item WHERE item.album_pid = album.album_pid)") }
            if try tableExists(db, "item_artist") { try exec(db, "DELETE FROM item_artist WHERE NOT EXISTS (SELECT 1 FROM item WHERE item.item_artist_pid = item_artist.item_artist_pid)") }
            if try tableExists(db, "album_artist") { try exec(db, "DELETE FROM album_artist WHERE NOT EXISTS (SELECT 1 FROM item WHERE item.album_artist_pid = album_artist.album_artist_pid)") }
            if try tableExists(db, "genre") { try exec(db, "DELETE FROM genre WHERE NOT EXISTS (SELECT 1 FROM item WHERE item.genre_id = genre.genre_id)") }

            try exec(db, "COMMIT")
            _ = sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
            _ = sqlite3_exec(db, "PRAGMA journal_mode=DELETE", nil, nil, nil)
            let check = try scalarText(db, "PRAGMA quick_check") ?? "unknown"
            guard check == "ok" else { throw MusicLibraryWipeError.integrityFailed(check) }
            return MusicLibraryWipeResult(removedItems: itemCount, removedFiles: files)
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func localMusicFiles(_ db: OpaquePointer) throws -> [String] {
        guard try tableExists(db, "item_extra") else { return [] }
        var statement: OpaquePointer?
        let sql = "SELECT DISTINCT item_extra.location FROM item JOIN item_extra ON item.item_pid=item_extra.item_pid WHERE item.base_location_id=3840 AND item_extra.location IS NOT NULL"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) {
            let value = String(cString: raw)
            // The device writer deletes only basenames inside F00.
            let name = URL(fileURLWithPath: value).lastPathComponent
            if !name.isEmpty { result.append(name) }
        }
        return Array(Set(result)).sorted()
    }

    private func allTables(_ db: OpaquePointer) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'", -1, &statement, nil) == SQLITE_OK, let statement else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) { result.append(String(cString: raw)) }
        return result
    }

    private func tableExists(_ db: OpaquePointer, _ table: String) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?", -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, table, -1, SQLITE_TRANSIENT)
        return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int64(statement, 0) > 0
    }

    private func columnExists(_ db: OpaquePointer, table: String, column: String) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(quotedIdentifier(table)))", -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 1), String(cString: raw) == column { return true }
        }
        return false
    }

    private func scalarInt(_ db: OpaquePointer, _ sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    private func scalarText(_ db: OpaquePointer, _ sql: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: raw)
    }

    private func quotedIdentifier(_ value: String) -> String { "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\"" }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let detail = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let error { sqlite3_free(error) }
            throw MusicLibraryWipeError.sqlFailed(detail)
        }
    }

    private func sqlError(_ db: OpaquePointer) -> MusicLibraryWipeError { .sqlFailed(String(cString: sqlite3_errmsg(db))) }
}

@MainActor
extension AppModel {
    func wipeMusicLibrary(pairingFileURL: URL, requiresRemotePairing: Bool) async {
        loading = true
        activityTitle = "Wiping Music library"
        activityProgress = 0
        activityLog.removeAll(keepingCapacity: true)
        do {
            activityLog.append("Music must remain force-closed during this operation")
            activityProgress = 0.12
            let snapshot = try DeviceBridge().stageSystemMusicDatabase(pairingFileURL: pairingFileURL, requiresRemotePairing: requiresRemotePairing)
            defer { try? FileManager.default.removeItem(at: snapshot.directoryURL) }

            activityProgress = 0.25
            let backupDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("MusicLibraryBackups", isDirectory: true)
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
            let backup = backupDir.appendingPathComponent("MediaLibrary-pre-wipe-\(formatter.string(from: Date())).sqlitedb")
            try FileManager.default.copyItem(at: snapshot.databaseURL, to: backup)
            activityLog.append("Safety backup: \(backup.lastPathComponent)")

            activityProgress = 0.38
            let stage = try MusicLibraryStager().prepareWorkingCopy(from: snapshot.databaseURL)
            let result = try MusicLibraryWipeService().wipe(databaseURL: stage.databaseURL)
            activityLog.append("Removed \(result.removedItems) Music database item(s)")

            activityProgress = 0.68
            let device = try LegacyGhostDeviceWriter().commit(modifiedDatabaseURL: stage.databaseURL, legacyFilenames: result.removedFiles, pairingFileURL: pairingFileURL, requiresRemotePairing: requiresRemotePairing)
            activityLog.append("Removed \(device.removedRemoteFiles) referenced audio file(s) from F00")
            activityLog.append("Previous live DB retained at \(device.databaseBackupPath)")

            activityProgress = 1
            activityTitle = "Music library wiped"
            loading = false
            message = "Music library wipe completed. Keep Music closed for a few seconds, then reopen it. Once it opens with an empty library, run Sync all Navidrome. Safety backup: \(backup.lastPathComponent)."
        } catch {
            activityProgress = nil
            activityTitle = "Music library wipe failed"
            activityLog.append("ERROR: \(error.localizedDescription)")
            loading = false
            message = error.localizedDescription
        }
    }
}

struct MusicLibraryWipeButton: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var pairingStore: PairingFileStore
    @State private var firstConfirm = false
    @State private var secondConfirm = false

    var body: some View {
        if let pairingURL = pairingStore.pairingFileURL {
            Button(role: .destructive) { firstConfirm = true } label: {
                Label("Wipe Music Library", systemImage: "trash.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.loading)
            .confirmationDialog("Wipe the local Music library?", isPresented: $firstConfirm, titleVisibility: .visible) {
                Button("Continue", role: .destructive) { secondConfirm = true }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("A safety backup is created first. Music must be force-closed. This removes local Music tracks and their referenced F00 audio files, while preserving the database schema.")
            }
            .confirmationDialog("Final confirmation", isPresented: $secondConfirm, titleVisibility: .visible) {
                Button("WIPE MUSIC LIBRARY", role: .destructive) {
                    Task { await model.wipeMusicLibrary(pairingFileURL: pairingURL, requiresRemotePairing: pairingStore.requiresRPPairingFile) }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This is destructive. The pre-wipe database backup will remain available for emergency restore.")
            }
        }
    }
}
