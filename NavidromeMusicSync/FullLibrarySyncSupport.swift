import Foundation
import CryptoKit
import SQLite3
import Darwin

struct FullLibraryTrackPayload {
    let metadata: InjectionSongMetadata
    let artwork: InjectionArtwork?
}

enum FullLibrarySyncSupportError: LocalizedError {
    case databaseOpenFailed
    case invalidDatabase

    var errorDescription: String? {
        switch self {
        case .databaseOpenFailed: return "Could not inspect the Music database for full-library sync."
        case .invalidDatabase: return "The staged Music database is not valid SQLite."
        }
    }
}

enum NaviLibraryIndex {
    static func existingLocations(databaseURL: URL) throws -> Set<String> {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw FullLibrarySyncSupportError.databaseOpenFailed
        }
        defer { sqlite3_close(db) }

        // Music may leave item_extra rows behind after a user removes a track.
        // A location therefore only counts as synchronized when the owning item
        // is still an active member of the Music library and is not disabled.
        let sql = """
        SELECT ie.location
        FROM item_extra AS ie
        INNER JOIN item AS i ON i.item_pid = ie.item_pid
        WHERE ie.location IS NOT NULL
          AND COALESCE(i.in_my_library, 0) = 1
          AND COALESCE(ie.is_user_disabled, 0) = 0
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw FullLibrarySyncSupportError.databaseOpenFailed
        }
        defer { sqlite3_finalize(statement) }

        var result = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                result.insert(String(cString: text))
            }
        }
        return result
    }

    static func expectedRemoteFilename(for song: Song) -> String {
        let digest = SHA256.hash(data: Data(song.id.utf8))
        let stem = digest.prefix(8).map { String(format: "%02X", $0) }.joined()
        let ext = (song.suffix?.isEmpty == false ? song.suffix! : "m4a").lowercased()
        return "\(stem).\(ext)"
    }
}

/// Uploads many audio/artwork files through one AFC session, then commits the
/// already-prepared Music database once. This is the key performance path for
/// complete-library synchronization.
final class FullLibraryDeviceWriter {
    private static let deviceHost = "10.7.0.1"
    private static let remotePairingPort: UInt16 = 49152
    private static let hostName = "NavidromeMusicSync"
    private static let musicDirectory = "/iTunes_Control/Music/F00"
    private static let databasePath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb"
    private static let databaseTempPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb.navsync-batch"
    private static let databaseBackupPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb.navsync-backup"

    func commit(
        tracks: [FullLibraryTrackPayload],
        modifiedDatabaseURL: URL,
        pairingFileURL: URL,
        requiresRemotePairing: Bool
    ) throws {
        let databaseData = try Data(contentsOf: modifiedDatabaseURL, options: [.mappedIfSafe])
        guard databaseData.starts(with: Data("SQLite format 3\0".utf8)) else {
            throw FullLibrarySyncSupportError.invalidDatabase
        }

        try withAfc(pairingFileURL: pairingFileURL, requiresRemotePairing: requiresRemotePairing) { afc in
            _ = Self.musicDirectory.withCString { afc_make_directory(afc, $0) }

            for track in tracks {
                let audioData = try Data(contentsOf: track.metadata.localURL, options: [.mappedIfSafe])
                let finalAudio = "\(Self.musicDirectory)/\(track.metadata.remoteFilename)"
                let tempAudio = finalAudio + ".navsync-new"
                _ = tempAudio.withCString { afc_remove_path(afc, $0) }
                try write(data: audioData, to: tempAudio, afc: afc)
                try verifyRemoteSize(path: tempAudio, expected: audioData.count, afc: afc)
                _ = finalAudio.withCString { afc_remove_path(afc, $0) }
                guard rename(source: tempAudio, destination: finalAudio, afc: afc) else {
                    throw DeviceWriteBackError.remoteRenameFailed(finalAudio)
                }

                if let artwork = track.artwork {
                    try ensureArtworkDirectory(for: artwork.remotePath, afc: afc)
                    let tempArtwork = artwork.remotePath + ".navsync-new"
                    _ = tempArtwork.withCString { afc_remove_path(afc, $0) }
                    try write(data: artwork.data, to: tempArtwork, afc: afc)
                    try verifyRemoteSize(path: tempArtwork, expected: artwork.data.count, afc: afc)
                    _ = artwork.remotePath.withCString { afc_remove_path(afc, $0) }
                    guard rename(source: tempArtwork, destination: artwork.remotePath, afc: afc) else {
                        throw DeviceWriteBackError.remoteRenameFailed(artwork.remotePath)
                    }
                }
            }

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
        }
    }

    private func ensureArtworkDirectory(for remotePath: String, afc: AfcClientHandle) throws {
        let parts = remotePath.split(separator: "/").dropLast()
        var current = ""
        for part in parts {
            current += "/" + part
            _ = current.withCString { afc_make_directory(afc, $0) }
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
        source.withCString { src in
            destination.withCString { dst in
                afc_rename_path(afc, src, dst) == nil
            }
        }
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
