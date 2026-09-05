import Foundation

@MainActor
final class PairingFileStore: ObservableObject {
    @Published private(set) var pairingFileURL: URL?
    @Published private(set) var status: String = "No pairing file imported"

    private let fileManager = FileManager.default

    init() {
        refresh()
    }

    var expectedFilename: String {
        requiresRPPairingFile ? "rpPairingFile.plist" : "pairingFile.plist"
    }

    var requiresRPPairingFile: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        if version.majorVersion > 26 { return true }
        return version.majorVersion == 26 && version.minorVersion >= 4
    }

    private var destinationDirectory: URL {
        let base = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("pairing", isDirectory: true)
    }

    var destinationURL: URL {
        destinationDirectory.appendingPathComponent(expectedFilename)
    }

    func refresh() {
        if validatePairingFile(at: destinationURL) {
            pairingFileURL = destinationURL
            status = "Pairing file ready"
        } else {
            pairingFileURL = nil
            status = "No valid \(expectedFilename) imported"
        }
    }

    func importPairingFile(from sourceURL: URL) throws {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let data = try Data(contentsOf: sourceURL)
        guard isValidPlist(data) else {
            throw PairingError.invalidPlist
        }

        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try data.write(to: destinationURL, options: .atomic)
        refresh()
    }

    func removePairingFile() throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        refresh()
    }

    private func validatePairingFile(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return isValidPlist(data)
    }

    private func isValidPlist(_ data: Data) -> Bool {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = object as? [String: Any],
              !dict.isEmpty else {
            return false
        }

        // Lockdown pairing records usually contain HostID/SystemBUID while
        // remote-pairing records use a different schema on newer iOS releases.
        // We intentionally avoid over-validating here; the idevice bridge will
        // perform transport-level validation when it opens the record.
        return true
    }
}

enum PairingError: LocalizedError {
    case invalidPlist

    var errorDescription: String? {
        switch self {
        case .invalidPlist:
            return "The selected file is not a valid property-list pairing record."
        }
    }
}
