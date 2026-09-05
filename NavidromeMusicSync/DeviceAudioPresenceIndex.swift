import Foundation
import Darwin

/// Verifies that tracks referenced by the Music database still have a real,
/// non-empty audio file in iTunes_Control/Music/F00. Music can leave database
/// rows behind after a user deletes a download/library item, so DB presence
/// alone is not sufficient for incremental sync.
final class DeviceAudioPresenceIndex {
    private static let deviceHost = "10.7.0.1"
    private static let remotePairingPort: UInt16 = 49152
    private static let hostName = "NaviTune"
    private static let musicDirectory = "/iTunes_Control/Music/F00"

    func existingFilenames(
        candidates: Set<String>,
        pairingFileURL: URL,
        requiresRemotePairing: Bool
    ) throws -> Set<String> {
        guard !candidates.isEmpty else { return [] }

        return try withAfc(pairingFileURL: pairingFileURL, requiresRemotePairing: requiresRemotePairing) { afc in
            var existing = Set<String>()
            existing.reserveCapacity(candidates.count)

            for filename in candidates {
                let path = "\(Self.musicDirectory)/\(filename)"
                var info = AfcFileInfo(size: 0, blocks: 0, creation: 0, modified: 0, st_nlink: nil, st_ifmt: nil, st_link_target: nil)
                let error = path.withCString { afc_get_file_info(afc, $0, &info) }
                if error == nil {
                    if info.size > 0 {
                        existing.insert(filename)
                    }
                    afc_file_info_free(&info)
                }
            }
            return existing
        }
    }

    private func withAfc<T>(
        pairingFileURL: URL,
        requiresRemotePairing: Bool,
        _ body: (AfcClientHandle) throws -> T
    ) throws -> T {
        guard FileManager.default.fileExists(atPath: pairingFileURL.path) else {
            throw DeviceWriteBackError.pairingFileMissing
        }

        if requiresRemotePairing {
            var pairing: RpPairingFileHandle?
            let pairingError = rp_pairing_file_read(pairingFileURL.path, &pairing)
            guard pairingError == nil, let pairing else { throw DeviceWriteBackError.rpPairingReadFailed }
            defer { rp_pairing_file_free(pairing) }

            var addr = sockaddr_in()
            memset(&addr, 0, MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = CFSwapInt16HostToBig(Self.remotePairingPort)
            guard inet_pton(AF_INET, Self.deviceHost, &addr.sin_addr) == 1 else {
                throw DeviceWriteBackError.rpTunnelFailed
            }

            var adapter: AdapterHandle?
            var handshake: RsdHandshakeHandle?
            let tunnelError = Self.hostName.withCString { hostname in
                withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                        tunnel_create_rppairing(
                            socketAddress,
                            socklen_t(MemoryLayout<sockaddr_in>.size),
                            hostname,
                            pairing,
                            nil,
                            nil,
                            &adapter,
                            &handshake
                        )
                    }
                }
            }
            guard tunnelError == nil, let adapter, let handshake else {
                if let handshake { rsd_handshake_free(handshake) }
                if let adapter { _ = adapter_close(adapter); adapter_free(adapter) }
                throw DeviceWriteBackError.rpTunnelFailed
            }
            _ = rp_pairing_file_write(pairing, pairingFileURL.path)
            defer {
                rsd_handshake_free(handshake)
                _ = adapter_close(adapter)
                adapter_free(adapter)
            }

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
