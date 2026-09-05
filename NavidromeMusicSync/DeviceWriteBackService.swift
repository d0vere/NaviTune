import Foundation
import Darwin

enum DeviceWriteBackError: LocalizedError {
    case pairingFileMissing
    case remotePairingRequired
    case pairingReadFailed
    case providerCreationFailed
    case afcConnectionFailed
    case localFileReadFailed(String)
    case remoteDirectoryFailed(String)
    case remoteOpenFailed(String)
    case remoteWriteFailed(String)
    case remoteVerificationFailed(String)
    case remoteRenameFailed(String)
    case databaseBackupFailed
    case databaseCommitFailed
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .pairingFileMissing: return "Import the pairing file first."
        case .remotePairingRequired: return "RP pairing write-back is not enabled yet on iOS 26.4+."
        case .pairingReadFailed: return "Could not read the pairing record."
        case .providerCreationFailed: return "Could not open the local lockdown provider."
        case .afcConnectionFailed: return "Could not connect to AFC."
        case .localFileReadFailed(let name): return "Could not read local file: \(name)."
        case .remoteDirectoryFailed(let path): return "Could not prepare remote directory: \(path)."
        case .remoteOpenFailed(let path): return "Could not open remote file for writing: \(path)."
        case .remoteWriteFailed(let path): return "AFC write failed for: \(path)."
        case .remoteVerificationFailed(let path): return "Uploaded file verification failed for: \(path)."
        case .remoteRenameFailed(let path): return "AFC rename failed while committing: \(path)."
        case .databaseBackupFailed: return "Could not move the original Music database to the rollback backup path."
        case .databaseCommitFailed: return "Could not promote the staged Music database to the live path."
        case .rollbackFailed: return "The database commit failed and automatic rollback could not restore the original database. Do not open Music until the backup is restored."
        }
    }
}

struct DeviceWriteBackResult {
    let audioRemotePath: String
    let databaseBackupPath: String

    var summary: String {
        "Device write-back completed. Audio: \(audioRemotePath). The previous Music database is retained at \(databaseBackupPath) for rollback."
    }
}

/// Performs the destructive portion of injection only after the database has
/// already been modified and quick-checked locally.
///
/// Commit protocol:
/// 1. upload audio to a temporary AFC path and verify size;
/// 2. atomically rename it into F00;
/// 3. upload the quick-checked DB to a temporary path and verify size;
/// 4. rename the live DB to a persistent rollback backup;
/// 5. rename the temporary DB into the live path;
/// 6. remove stale WAL/SHM files.
///
/// If step 5 fails, the original DB is renamed back automatically.
final class DeviceWriteBackService {
    private static let deviceHost = "10.7.0.1"
    private static let musicDirectory = "/iTunes_Control/Music/F00"
    private static let databasePath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb"
    private static let databaseTempPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb.navsync-new"
    private static let databaseBackupPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb.navsync-backup"

    func commit(
        metadata: InjectionSongMetadata,
        modifiedDatabaseURL: URL,
        pairingFileURL: URL,
        requiresRemotePairing: Bool
    ) throws -> DeviceWriteBackResult {
        let audioData: Data
        let databaseData: Data
        do { audioData = try Data(contentsOf: metadata.localURL, options: [.mappedIfSafe]) }
        catch { throw DeviceWriteBackError.localFileReadFailed(metadata.localURL.lastPathComponent) }
        do { databaseData = try Data(contentsOf: modifiedDatabaseURL, options: [.mappedIfSafe]) }
        catch { throw DeviceWriteBackError.localFileReadFailed(modifiedDatabaseURL.lastPathComponent) }

        guard databaseData.starts(with: Data("SQLite format 3\0".utf8)) else {
            throw DeviceWriteBackError.localFileReadFailed("invalid SQLite database")
        }

        return try withAfc(pairingFileURL: pairingFileURL, requiresRemotePairing: requiresRemotePairing) { afc in
            _ = Self.musicDirectory.withCString { afc_make_directory(afc, $0) }

            let finalAudioPath = "\(Self.musicDirectory)/\(metadata.remoteFilename)"
            let temporaryAudioPath = "\(finalAudioPath).navsync-new"

            // Clean stale temporary files from an interrupted previous attempt.
            _ = temporaryAudioPath.withCString { afc_remove_path(afc, $0) }
            _ = Self.databaseTempPath.withCString { afc_remove_path(afc, $0) }

            try write(data: audioData, to: temporaryAudioPath, afc: afc)
            try verifyRemoteSize(path: temporaryAudioPath, expected: audioData.count, afc: afc)

            // Replace only this deterministic Navidrome-owned filename.
            _ = finalAudioPath.withCString { afc_remove_path(afc, $0) }
            guard rename(source: temporaryAudioPath, destination: finalAudioPath, afc: afc) else {
                _ = temporaryAudioPath.withCString { afc_remove_path(afc, $0) }
                throw DeviceWriteBackError.remoteRenameFailed(finalAudioPath)
            }

            do {
                try write(data: databaseData, to: Self.databaseTempPath, afc: afc)
                try verifyRemoteSize(path: Self.databaseTempPath, expected: databaseData.count, afc: afc)
            } catch {
                _ = finalAudioPath.withCString { afc_remove_path(afc, $0) }
                throw error
            }

            // Keep one remote rollback copy. It is intentionally not deleted
            // after a successful commit.
            _ = Self.databaseBackupPath.withCString { afc_remove_path(afc, $0) }
            guard rename(source: Self.databasePath, destination: Self.databaseBackupPath, afc: afc) else {
                _ = Self.databaseTempPath.withCString { afc_remove_path(afc, $0) }
                _ = finalAudioPath.withCString { afc_remove_path(afc, $0) }
                throw DeviceWriteBackError.databaseBackupFailed
            }

            guard rename(source: Self.databaseTempPath, destination: Self.databasePath, afc: afc) else {
                let restored = rename(source: Self.databaseBackupPath, destination: Self.databasePath, afc: afc)
                _ = Self.databaseTempPath.withCString { afc_remove_path(afc, $0) }
                _ = finalAudioPath.withCString { afc_remove_path(afc, $0) }
                if !restored { throw DeviceWriteBackError.rollbackFailed }
                throw DeviceWriteBackError.databaseCommitFailed
            }

            // A checkpointed local database is being installed; stale sidecars
            // from the previous live database must not be replayed over it.
            let wal = Self.databasePath + "-wal"
            let shm = Self.databasePath + "-shm"
            _ = wal.withCString { afc_remove_path(afc, $0) }
            _ = shm.withCString { afc_remove_path(afc, $0) }

            return DeviceWriteBackResult(
                audioRemotePath: finalAudioPath,
                databaseBackupPath: Self.databaseBackupPath
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
        source.withCString { src in
            destination.withCString { dst in
                afc_rename_path(afc, src, dst) == nil
            }
        }
    }

    private func withAfc<T>(
        pairingFileURL: URL,
        requiresRemotePairing: Bool,
        _ body: (AfcClientHandle) throws -> T
    ) throws -> T {
        guard FileManager.default.fileExists(atPath: pairingFileURL.path) else { throw DeviceWriteBackError.pairingFileMissing }
        if requiresRemotePairing { throw DeviceWriteBackError.remotePairingRequired }

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
                idevice_tcp_provider_new(socketAddress, pairing, "NavidromeMusicSync", &provider)
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
