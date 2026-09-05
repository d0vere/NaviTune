import Foundation
import Darwin

final class ArtworkDeviceUploader {
    private static let deviceHost = "10.7.0.1"
    private static let remotePairingPort: UInt16 = 49152
    private static let hostName = "NavidromeMusicSync"
    private static let originals = "/iTunes_Control/iTunes/Artwork/Originals"

    func upload(_ artwork: InjectionArtwork, pairingFileURL: URL, requiresRemotePairing: Bool) throws {
        let artistArtwork = InjectionMetadataRegistry.takePendingArtistArtwork(forAlbumToken: artwork.token)
        try withAfc(pairingFileURL: pairingFileURL, requiresRemotePairing: requiresRemotePairing) { afc in
            _ = "/iTunes_Control/iTunes/Artwork".withCString { afc_make_directory(afc, $0) }
            _ = Self.originals.withCString { afc_make_directory(afc, $0) }
            try writeArtwork(artwork, afc: afc)

            // Artist artwork is enrichment only: never fail a valid song/album
            // import if the secondary image cannot be written for any reason.
            if let artistArtwork {
                try? writeArtwork(artistArtwork, afc: afc)
            }
        }
    }

    private func writeArtwork(_ artwork: InjectionArtwork, afc: AfcClientHandle) throws {
        let folder = artwork.relativePath.components(separatedBy: "/").first ?? "00"
        let folderPath = "\(Self.originals)/\(folder)"
        _ = folderPath.withCString { afc_make_directory(afc, $0) }

        let path = artwork.remotePath
        var file: AfcFileHandle?
        let openError = path.withCString { afc_file_open(afc, $0, AfcWrOnly, &file) }
        guard openError == nil, let file else { throw DeviceWriteBackError.remoteOpenFailed(path) }
        defer { afc_file_close(file) }
        let writeError = artwork.data.withUnsafeBytes { raw -> UnsafeMutablePointer<IdeviceFfiError>? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            return afc_file_write(file, base, artwork.data.count)
        }
        guard writeError == nil else { throw DeviceWriteBackError.remoteWriteFailed(path) }

        var info = AfcFileInfo(size: 0, blocks: 0, creation: 0, modified: 0, st_nlink: nil, st_ifmt: nil, st_link_target: nil)
        let verifyError = path.withCString { afc_get_file_info(afc, $0, &info) }
        guard verifyError == nil else {
            afc_file_info_free(&info)
            throw DeviceWriteBackError.remoteVerificationFailed(path)
        }
        defer { afc_file_info_free(&info) }
        guard Int(info.size) == artwork.data.count else { throw DeviceWriteBackError.remoteVerificationFailed(path) }
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
