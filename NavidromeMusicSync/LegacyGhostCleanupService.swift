import Foundation
import SQLite3
import Darwin

struct LegacyGhostCleanupResult {
    let removedItems: Int
    let removedFiles: [String]
    let databaseURL: URL

    var summary: String {
        if removedItems == 0 { return "No legacy Navi Music Sync ghost tracks were found." }
        return "Removed \(removedItems) legacy ghost track record(s) and \(removedFiles.count) legacy audio file(s)."
    }
}

enum LegacyGhostCleanupError: LocalizedError {
    case openFailed
    case sqlFailed(String)
    case integrityFailed(String)
    case invalidDatabase

    var errorDescription: String? {
        switch self {
        case .openFailed: return "Could not open the Music database for ghost cleanup."
        case .sqlFailed(let detail): return "Ghost cleanup database error: \(detail)"
        case .integrityFailed(let result): return "Music database failed quick_check after ghost cleanup: \(result)"
        case .invalidDatabase: return "The staged Music database is not a valid SQLite database."
        }
    }
}

/// Removes only records created by legacy versions of this app:
/// - old 12-character deterministic filenames;
/// - 16-hex hash filenames using a pre-MP3 extension.
/// Current normalized 16-hex .mp3 imports are deliberately preserved.
final class LegacyGhostCleanupService {
    func clean(databaseURL: URL) throws -> LegacyGhostCleanupResult {
        guard let header = try? Data(contentsOf: databaseURL, options: [.mappedIfSafe]),
              header.starts(with: Data("SQLite format 3\0".utf8)) else {
            throw LegacyGhostCleanupError.invalidDatabase
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            if db != nil { sqlite3_close(db) }
            throw LegacyGhostCleanupError.openFailed
        }
        defer { sqlite3_close(db) }

        let candidates = try legacyCandidates(db)
        guard !candidates.isEmpty else {
            return LegacyGhostCleanupResult(removedItems: 0, removedFiles: [], databaseURL: databaseURL)
        }

        try exec(db, "BEGIN IMMEDIATE")
        do {
            let childTables = ["lyrics", "chapter", "item_video", "item_search", "item_store", "item_stats", "item_playback", "item_extra"]
            for candidate in candidates {
                for table in childTables where try tableExists(db, table) {
                    try exec(db, "DELETE FROM \(table) WHERE item_pid = \(candidate.pid)")
                }
                try exec(db, "DELETE FROM item WHERE item_pid = \(candidate.pid)")
            }

            // Remove only entity rows that no remaining item references. This
            // prevents empty artist/album shells after the broken songs vanish.
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
            guard check == "ok" else { throw LegacyGhostCleanupError.integrityFailed(check) }

            return LegacyGhostCleanupResult(
                removedItems: candidates.count,
                removedFiles: Array(Set(candidates.map(\.filename))).sorted(),
                databaseURL: databaseURL
            )
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func legacyCandidates(_ db: OpaquePointer) throws -> [(pid: Int64, filename: String)] {
        let sql = """
        SELECT item.item_pid, item_extra.location
        FROM item
        JOIN item_extra ON item.item_pid = item_extra.item_pid
        WHERE item.base_location_id = 3840
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqlError(db) }
        defer { sqlite3_finalize(statement) }

        var result: [(Int64, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 1) else { continue }
            let filename = String(cString: raw)
            if isLegacyOwnedFilename(filename) {
                result.append((sqlite3_column_int64(statement, 0), filename))
            }
        }
        return result
    }

    private func isLegacyOwnedFilename(_ filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()
        let supported = Set(["mp3", "m4a", "aac", "flac", "opus", "wav", "wave", "alac", "m4r"])
        guard supported.contains(ext) else { return false }

        let old12 = stem.count == 12 && stem.allSatisfy { $0.isUppercase || $0.isNumber }
        let hash16 = stem.count == 16 && stem.allSatisfy { $0.isNumber || ("A"..."F").contains(String($0)) }
        return old12 || (hash16 && ext != "mp3")
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
            throw LegacyGhostCleanupError.sqlFailed(detail)
        }
    }

    private func sqlError(_ db: OpaquePointer) -> LegacyGhostCleanupError {
        .sqlFailed(String(cString: sqlite3_errmsg(db)))
    }
}

struct LegacyGhostDeviceCommitResult {
    let databaseBackupPath: String
    let removedRemoteFiles: Int
}

/// Database-only write-back used by ghost cleanup. It follows the same staged
/// upload, remote backup, atomic promote and rollback protocol as injection.
final class LegacyGhostDeviceWriter {
    private static let deviceHost = "10.7.0.1"
    private static let remotePairingPort: UInt16 = 49152
    private static let hostName = "NavidromeMusicSync"
    private static let musicDirectory = "/iTunes_Control/Music/F00"
    private static let databasePath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb"
    private static let databaseTempPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb.navsync-clean"
    private static let databaseBackupPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb.navsync-backup"

    func commit(
        modifiedDatabaseURL: URL,
        legacyFilenames: [String],
        pairingFileURL: URL,
        requiresRemotePairing: Bool
    ) throws -> LegacyGhostDeviceCommitResult {
        let databaseData: Data
        do { databaseData = try Data(contentsOf: modifiedDatabaseURL, options: [.mappedIfSafe]) }
        catch { throw DeviceWriteBackError.localFileReadFailed(modifiedDatabaseURL.lastPathComponent) }
        guard databaseData.starts(with: Data("SQLite format 3\0".utf8)) else {
            throw DeviceWriteBackError.localFileReadFailed("invalid SQLite database")
        }

        return try withAfc(pairingFileURL: pairingFileURL, requiresRemotePairing: requiresRemotePairing) { afc in
            _ = Self.databaseTempPath.withCString { afc_remove_path(afc, $0) }
            try write(data: databaseData, to: Self.databaseTempPath, afc: afc)
            try verifyRemoteSize(path: Self.databaseTempPath, expected: databaseData.count, afc: afc)

            _ = Self.databaseBackupPath.withCString { afc_remove_path(afc, $0) }
            guard rename(source: Self.databasePath, destination: Self.databaseBackupPath, afc: afc) else {
                _ = Self.databaseTempPath.withCString { afc_remove_path(afc, $0) }
                throw DeviceWriteBackError.databaseBackupFailed
            }

            guard rename(source: Self.databaseTempPath, destination: Self.databasePath, afc: afc) else {
                let restored = rename(source: Self.databaseBackupPath, destination: Self.databasePath, afc: afc)
                _ = Self.databaseTempPath.withCString { afc_remove_path(afc, $0) }
                if !restored { throw DeviceWriteBackError.rollbackFailed }
                throw DeviceWriteBackError.databaseCommitFailed
            }

            let wal = Self.databasePath + "-wal"
            let shm = Self.databasePath + "-shm"
            _ = wal.withCString { afc_remove_path(afc, $0) }
            _ = shm.withCString { afc_remove_path(afc, $0) }

            var removed = 0
            for filename in legacyFilenames {
                let remote = "\(Self.musicDirectory)/\(filename)"
                if remote.withCString({ afc_remove_path(afc, $0) }) == nil { removed += 1 }
            }

            return LegacyGhostDeviceCommitResult(
                databaseBackupPath: Self.databaseBackupPath,
                removedRemoteFiles: removed
            )
        }
    }

    private func write(data: Data, to path: String, afc: AfcClientHandle) throws {
        var file: AfcFileHandle?
        let openError = path.withCString { afc_file_open(afc, $0, AfcWrOnly, &file) }
        guard openError == nil, let file else { throw DeviceWriteBackError.remoteOpenFailed(path) }
        defer { afc_file_close(file) }
        let writeError = data.withUnsafeBytes { raw -> UnsafeMutablePointer<IdeviceFfiError>? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            return afc_file_write(file, base, data.count)
        }
        guard writeError == nil else { throw DeviceWriteBackError.remoteWriteFailed(path) }
    }

    private func verifyRemoteSize(path: String, expected: Int, afc: AfcClientHandle) throws {
        var info = AfcFileInfo(size: 0, blocks: 0, creation: 0, modified: 0, st_nlink: nil, st_ifmt: nil, st_link_target: nil)
        let error = path.withCString { afc_get_file_info(afc, $0, &info) }
        guard error == nil else {
            afc_file_info_free(&info)
            throw DeviceWriteBackError.remoteVerificationFailed(path)
        }
        defer { afc_file_info_free(&info) }
        guard Int(info.size) == expected else { throw DeviceWriteBackError.remoteVerificationFailed(path) }
    }

    private func rename(source: String, destination: String, afc: AfcClientHandle) -> Bool {
        source.withCString { src in destination.withCString { dst in afc_rename_path(afc, src, dst) == nil } }
    }

    private func withAfc<T>(pairingFileURL: URL, requiresRemotePairing: Bool, _ body: (AfcClientHandle) throws -> T) throws -> T {
        guard FileManager.default.fileExists(atPath: pairingFileURL.path) else { throw DeviceWriteBackError.pairingFileMissing }

        if requiresRemotePairing {
            var pairing: RpPairingFileHandle?
            let pairingError = rp_pairing_file_read(pairingFileURL.path, &pairing)
            guard pairingError == nil, let pairing else { throw DeviceWriteBackError.rpPairingReadFailed }
            defer { rp_pairing_file_free(pairing) }

            var addr = sockaddr_in()
            memset(&addr, 0, MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = CFSwapInt16HostToBig(Self.remotePairingPort)
            guard inet_pton(AF_INET, Self.deviceHost, &addr.sin_addr) == 1 else { throw DeviceWriteBackError.rpTunnelFailed }

            var adapter: AdapterHandle?
            var handshake: RsdHandshakeHandle?
            let tunnelError = Self.hostName.withCString { hostname in
                withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                        tunnel_create_rppairing(socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size), hostname, pairing, nil, nil, &adapter, &handshake)
                    }
                }
            }
            guard tunnelError == nil, let adapter, let handshake else {
                if let handshake { rsd_handshake_free(handshake) }
                if let adapter { _ = adapter_close(adapter); adapter_free(adapter) }
                throw DeviceWriteBackError.rpTunnelFailed
            }
            _ = rp_pairing_file_write(pairing, pairingFileURL.path)
            defer { rsd_handshake_free(handshake); _ = adapter_close(adapter); adapter_free(adapter) }

            var afc: AfcClientHandle?
            let afcError = afc_client_connect_rsd(adapter, handshake, &afc)
            guard afcError == nil, let afc else { throw DeviceWriteBackError.afcConnectionFailed }
            defer { afc_client_free(afc) }
            return try body(afc)
        }

        var pairing: IdevicePairingFileHandle?
        let pairingError = idevice_pairing_file_read(pairingFileURL.path, &pairing)
        guard pairingError == nil, let pairing else { throw DeviceWriteBackError.pairingReadFailed }
        defer { idevice_pairing_file_free(pairing) }

        var addr = sockaddr_in()
        memset(&addr, 0, MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(UInt16(LOCKDOWN_PORT))
        inet_pton(AF_INET, Self.deviceHost, &addr.sin_addr)

        var provider: IdeviceProviderHandle?
        let providerError = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                idevice_tcp_provider_new(socketAddress, pairing, Self.hostName, &provider)
            }
        }
        guard providerError == nil, let provider else { throw DeviceWriteBackError.providerCreationFailed }
        defer { idevice_provider_free(provider) }

        var afc: AfcClientHandle?
        let afcError = afc_client_connect(provider, &afc)
        guard afcError == nil, let afc else { throw DeviceWriteBackError.afcConnectionFailed }
        defer { afc_client_free(afc) }
        return try body(afc)
    }
}
