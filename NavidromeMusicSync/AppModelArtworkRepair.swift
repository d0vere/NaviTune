import Foundation

extension AppModel {
    func repairExistingSongArtwork(pairingFileURL: URL, requiresRemotePairing: Bool) async {
        loading = true
        activityTitle = "Repairing existing song artwork"
        activityProgress = 0
        activityLog.removeAll(keepingCapacity: true)
        appendArtworkRepairLog("Repairing existing song artwork")

        do {
            artworkRepairProgress("Reading live Music database over RP/AFC", 0.18)
            let snapshot = try DeviceBridge().stageSystemMusicDatabase(
                pairingFileURL: pairingFileURL,
                requiresRemotePairing: requiresRemotePairing
            )
            defer { try? FileManager.default.removeItem(at: snapshot.directoryURL) }

            artworkRepairProgress("Saving local rollback backup", 0.32)
            let backupURL = try persistArtworkRepairBackup(from: snapshot.databaseURL)
            appendArtworkRepairLog("Backup: \(backupURL.lastPathComponent)")

            artworkRepairProgress("Preparing safe working database", 0.46)
            let stage = try MusicLibraryStager().prepareWorkingCopy(from: snapshot.databaseURL)

            artworkRepairProgress("Repairing old Navi item artwork mappings", 0.64)
            let repair = try ExistingArtworkRepairService().repair(databaseURL: stage.databaseURL)
            appendArtworkRepairLog("Repaired tracks: \(repair.repairedTracks)")
            appendArtworkRepairLog("Skipped tracks: \(repair.skippedTracks)")

            guard repair.repairedTracks > 0 else {
                activityTitle = "Artwork repair complete"
                activityProgress = 1
                loading = false
                appendArtworkRepairLog("Done")
                message = repair.summary
                return
            }

            artworkRepairProgress("Writing repaired database with rollback protection", 0.82)
            _ = try LegacyGhostDeviceWriter().commit(
                modifiedDatabaseURL: repair.databaseURL,
                legacyFilenames: [],
                pairingFileURL: pairingFileURL,
                requiresRemotePairing: requiresRemotePairing
            )

            activityTitle = "Artwork repair complete"
            activityProgress = 1
            loading = false
            appendArtworkRepairLog("Done")
            message = "\(repair.summary) No audio or artwork image files were duplicated. Local backup: \(backupURL.lastPathComponent). Close and reopen Music before checking the old tracks."
        } catch {
            activityTitle = "Operation failed"
            activityProgress = nil
            loading = false
            appendArtworkRepairLog("ERROR: \(error.localizedDescription)")
            message = error.localizedDescription
        }
    }

    private func artworkRepairProgress(_ text: String, _ value: Double) {
        activityTitle = text
        activityProgress = min(max(value, 0), 1)
        appendArtworkRepairLog(text)
    }

    private func appendArtworkRepairLog(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        activityLog.append("[\(formatter.string(from: Date()))] \(text)")
        if activityLog.count > 80 { activityLog.removeFirst(activityLog.count - 80) }
    }

    private func persistArtworkRepairBackup(from sourceURL: URL) throws -> URL {
        let fm = FileManager.default
        let directory = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicLibraryBackups", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let destination = directory.appendingPathComponent(
            "MediaLibrary-artwork-repair-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).sqlitedb"
        )
        try fm.copyItem(at: sourceURL, to: destination)
        return destination
    }
}
