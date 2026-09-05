import Foundation
import Darwin

typealias IdevicePairingFileHandle = OpaquePointer
typealias IdeviceProviderHandle = OpaquePointer
typealias HeartbeatClientHandle = OpaquePointer
typealias AfcClientHandle = OpaquePointer

struct DeviceLibraryProbeResult {
    let databaseSize: Int
    let databaseModified: Date?

    var summary: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(databaseSize), countStyle: .file)
        if let databaseModified {
            return "AFC access OK. MediaLibrary.sqlitedb is \(size), modified \(databaseModified.formatted(date: .abbreviated, time: .shortened))."
        }
        return "AFC access OK. MediaLibrary.sqlitedb is \(size)."
    }
}

final class DeviceBridge {
    enum BridgeError: LocalizedError {
        case pairingFileMissing
        case remotePairingRequired
        case pairingReadFailed
        case providerCreationFailed
        case heartbeatFailed
        case afcConnectionFailed
        case musicDatabaseUnavailable

        var errorDescription: String? {
            switch self {
            case .pairingFileMissing:
                return "Import the pairing file first."
            case .remotePairingRequired:
                return "This iOS version requires the RP pairing tunnel. RP transport support is not enabled in this build yet."
            case .pairingReadFailed:
                return "idevice could not read the pairing record."
            case .providerCreationFailed:
                return "Could not create the idevice lockdown provider. Make sure the local-device VPN/tunnel is active."
            case .heartbeatFailed:
                return "The pairing record was accepted, but the iPhone heartbeat service could not be reached."
            case .afcConnectionFailed:
                return "Heartbeat works, but the AFC file service could not be opened."
            case .musicDatabaseUnavailable:
                return "AFC is connected, but /iTunes_Control/iTunes/MediaLibrary.sqlitedb could not be read."
            }
        }
    }

    private static let deviceHost = "10.7.0.1"
    private static let mediaDatabasePath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb"

    func testConnection(pairingFileURL: URL, requiresRemotePairing: Bool) throws {
        try withClassicProvider(pairingFileURL: pairingFileURL, requiresRemotePairing: requiresRemotePairing) { provider in
            var heartbeat: HeartbeatClientHandle?
            let heartbeatError = heartbeat_connect(provider, &heartbeat)
            guard heartbeatError == nil, let heartbeat else {
                throw BridgeError.heartbeatFailed
            }
            heartbeat_client_free(heartbeat)
        }
    }

    /// Read-only probe. It opens AFC and asks only for metadata about the Music
    /// database; it does not download, alter, rename or upload anything.
    func inspectSystemMusicLibrary(pairingFileURL: URL, requiresRemotePairing: Bool) throws -> DeviceLibraryProbeResult {
        try withClassicProvider(pairingFileURL: pairingFileURL, requiresRemotePairing: requiresRemotePairing) { provider in
            var afc: AfcClientHandle?
            let afcError = afc_client_connect(provider, &afc)
            guard afcError == nil, let afc else {
                throw BridgeError.afcConnectionFailed
            }
            defer { afc_client_free(afc) }

            var info = AfcFileInfo(
                size: 0,
                blocks: 0,
                creation: 0,
                modified: 0,
                st_nlink: nil,
                st_ifmt: nil,
                st_link_target: nil
            )

            let infoError = Self.mediaDatabasePath.withCString { path in
                afc_get_file_info(afc, path, &info)
            }
            guard infoError == nil else {
                afc_file_info_free(&info)
                throw BridgeError.musicDatabaseUnavailable
            }
            defer { afc_file_info_free(&info) }

            let modified: Date? = info.modified > 0 ? Date(timeIntervalSince1970: TimeInterval(info.modified)) : nil
            return DeviceLibraryProbeResult(databaseSize: Int(info.size), databaseModified: modified)
        }
    }

    private func withClassicProvider<T>(
        pairingFileURL: URL,
        requiresRemotePairing: Bool,
        _ body: (IdeviceProviderHandle) throws -> T
    ) throws -> T {
        guard FileManager.default.fileExists(atPath: pairingFileURL.path) else {
            throw BridgeError.pairingFileMissing
        }
        if requiresRemotePairing {
            throw BridgeError.remotePairingRequired
        }

        var pairing: IdevicePairingFileHandle?
        let pairingError = idevice_pairing_file_read(pairingFileURL.path, &pairing)
        guard pairingError == nil, let pairing else {
            throw BridgeError.pairingReadFailed
        }
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
        guard providerError == nil, let provider else {
            throw BridgeError.providerCreationFailed
        }
        defer { idevice_provider_free(provider) }

        return try body(provider)
    }
}
