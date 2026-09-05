import Foundation
import Darwin

typealias IdevicePairingFileHandle = OpaquePointer
typealias IdeviceProviderHandle = OpaquePointer
typealias HeartbeatClientHandle = OpaquePointer

final class DeviceBridge {
    enum BridgeError: LocalizedError {
        case pairingFileMissing
        case remotePairingRequired
        case pairingReadFailed
        case providerCreationFailed
        case heartbeatFailed

        var errorDescription: String? {
            switch self {
            case .pairingFileMissing:
                return "Import the pairing file first."
            case .remotePairingRequired:
                return "This iOS version requires the RP pairing tunnel. RP transport support is the next integration step."
            case .pairingReadFailed:
                return "idevice could not read the pairing record."
            case .providerCreationFailed:
                return "Could not create the idevice lockdown provider. Make sure the local-device VPN/tunnel is active."
            case .heartbeatFailed:
                return "The pairing record was accepted, but the iPhone heartbeat service could not be reached."
            }
        }
    }

    private static let deviceHost = "10.7.0.1"

    func testConnection(pairingFileURL: URL, requiresRemotePairing: Bool) throws {
        guard FileManager.default.fileExists(atPath: pairingFileURL.path) else {
            throw BridgeError.pairingFileMissing
        }

        if requiresRemotePairing {
            throw BridgeError.remotePairingRequired
        }

        var pairing: IdevicePairingFileHandle?
        let pairingError = idevice_pairing_file_read(pairingFileURL.path, &pairing)
        guard pairingError == nil, pairing != nil else {
            throw BridgeError.pairingReadFailed
        }

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
            if let pairing { idevice_pairing_file_free(pairing) }
            throw BridgeError.providerCreationFailed
        }
        defer { idevice_provider_free(provider) }

        var heartbeat: HeartbeatClientHandle?
        let heartbeatError = heartbeat_connect(provider, &heartbeat)
        guard heartbeatError == nil, let heartbeat else {
            throw BridgeError.heartbeatFailed
        }
        heartbeat_client_free(heartbeat)
    }
}
