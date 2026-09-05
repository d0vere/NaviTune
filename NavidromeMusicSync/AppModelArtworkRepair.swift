import Foundation

extension AppModel {
    func repairExistingSongArtwork(pairingFileURL: URL, requiresRemotePairing: Bool) async {
        loading = true
        activityTitle = "Repairing existing Music metadata"
        activityProgress = 0
        activityLog.removeAll(keepingCapacity: true)
        appendArtworkRepairLog("Repairing existing Music metadata")

        do {
            artworkRepairProgress("Reading live Music database over RP/AFC", 0.14)
            let snapshot = try DeviceBridge().stageSystemMusicDatabase(
                pairingFileURL: pairingFileURL,
                requiresRemotePairing: requiresRemotePairing
            )
            defer { try? FileManager.default.removeItem(at: snapshot.directoryURL) }

            artworkRepairProgress("Saving local rollback backup", 0.26)
            let backupURL = try persistArtworkRepairBackup(from: snapshot.databaseURL)
            appendArtworkRepairLog("Backup: \(backupURL.lastPathComponent)")

            artworkRepairProgress("Preparing safe working database", 0.38)
            let stage = try MusicLibraryStager().prepareWorkingCopy(from: snapshot.databaseURL)

            artworkRepairProgress("Repairing old Navi artwork mappings", 0.52)
            let artworkRepair = try ExistingArtworkRepairService().repair(databaseURL: stage.databaseURL)
            appendArtworkRepairLog("Artwork mappings repaired: \(artworkRepair.repairedTracks)")

            artworkRepairProgress("Matching existing tracks to Navidrome genres", 0.66)
            let genreRepair = try ExistingGenreRepairService().repair(databaseURL: stage.databaseURL)
            appendArtworkRepairLog("Genres repaired: \(genreRepair.repairedTracks)")
            appendArtworkRepairLog("Genre matches skipped: \(genreRepair.skippedTracks)")

            guard artworkRepair.repairedTracks > 0 || genreRepair.repairedTracks > 0 else {
                activityTitle = "Metadata repair complete"
                activityProgress = 1
                loading = false
                appendArtworkRepairLog("Done")
                message = "No existing Navi metadata needed repair. \(genreRepair.skippedTracks) track(s) had no matching Navidrome genre."
                return
            }

            artworkRepairProgress("Repairing Music sort indexes", 0.76)
            try MusicSortRepair().repair(databaseURL: stage.databaseURL)

            artworkRepairProgress("Writing repaired database with rollback protection", 0.86)
            _ = try LegacyGhostDeviceWriter().commit(
                modifiedDatabaseURL: stage.databaseURL,
                legacyFilenames: [],
                pairingFileURL: pairingFileURL,
                requiresRemotePairing: requiresRemotePairing
            )

            activityTitle = "Metadata repair complete"
            activityProgress = 1
            loading = false
            appendArtworkRepairLog("Done")
            message = "Repaired artwork mapping for \(artworkRepair.repairedTracks) track(s) and Navidrome genre for \(genreRepair.repairedTracks) track(s). No audio was re-downloaded or duplicated. Local backup: \(backupURL.lastPathComponent). Close and reopen Music before checking Songs, Genres and artwork."
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
            "MediaLibrary-metadata-repair-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).sqlitedb"
        )
        try fm.copyItem(at: sourceURL, to: destination)
        return destination
    }
}
