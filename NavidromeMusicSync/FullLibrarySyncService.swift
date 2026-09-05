import Foundation
import SQLite3

struct FullLibrarySyncResult: Sendable {
    let serverSongs: Int
    let alreadyPresent: Int
    let imported: Int
    let batches: Int

    var summary: String {
        if imported == 0 {
            return "Navidrome and Music are already in sync. \(serverSongs) server tracks checked; nothing downloaded."
        }
        return "Library sync complete. Imported \(imported) missing track(s) in \(batches) batch(es); \(alreadyPresent) were already present."
    }
}

enum FullLibrarySyncError: LocalizedError {
    case missingSettings
    case missingPairingFile(String)
    case databaseValidationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingSettings:
            return "Navidrome settings are incomplete. Open Navi Music Sync and connect once before running full sync."
        case .missingPairingFile(let filename):
            return "Missing \(filename). Import the pairing file in Navi Music Sync before running sync."
        case .databaseValidationFailed(let detail):
            return "The prepared Music database failed validation: \(detail)"
        }
    }
}

struct DevicePairingConfiguration: Sendable {
    let fileURL: URL
    let requiresRemotePairing: Bool

    static func current() throws -> DevicePairingConfiguration {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let requiresRP = version.majorVersion > 26 || (version.majorVersion == 26 && version.minorVersion >= 4)
        let filename = requiresRP ? "rpPairingFile.plist" : "pairingFile.plist"
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = root.appendingPathComponent("pairing", isDirectory: true).appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FullLibrarySyncError.missingPairingFile(filename)
        }
        return DevicePairingConfiguration(fileURL: url, requiresRemotePairing: requiresRP)
    }
}

final class FullLibrarySyncService {
    typealias ProgressHandler = @MainActor @Sendable (_ text: String, _ progress: Double) -> Void

    private let batchSize = 25

    func syncUsingSavedConfiguration(progress: ProgressHandler? = nil) async throws -> FullLibrarySyncResult {
        let settings = NavidromeSettingsStore.load()
        guard !settings.server.isEmpty, !settings.username.isEmpty, !settings.password.isEmpty else {
            throw FullLibrarySyncError.missingSettings
        }
        let pairing = try DevicePairingConfiguration.current()
        let client = try NavidromeClient(server: settings.server, username: settings.username, password: settings.password)
        return try await sync(
            client: client,
            pairingFileURL: pairing.fileURL,
            requiresRemotePairing: pairing.requiresRemotePairing,
            progress: progress
        )
    }

    func sync(
        client: NavidromeClient,
        pairingFileURL: URL,
        requiresRemotePairing: Bool,
        progress: ProgressHandler? = nil
    ) async throws -> FullLibrarySyncResult {
        await report(progress, "Reading Music library", 0.02)
        let snapshot = try DeviceBridge().stageSystemMusicDatabase(
            pairingFileURL: pairingFileURL,
            requiresRemotePairing: requiresRemotePairing
        )
        defer { try? FileManager.default.removeItem(at: snapshot.directoryURL) }

        try persistPreSyncBackup(from: snapshot.databaseURL)
        let stage = try MusicLibraryStager().prepareWorkingCopy(from: snapshot.databaseURL)
        let existing = try NaviLibraryIndex.existingLocations(databaseURL: stage.databaseURL)

        await report(progress, "Scanning complete Navidrome catalog", 0.08)
        let rawSongs = try await client.allSongs()
        var seenIDs = Set<String>()
        let serverSongs = rawSongs.filter { seenIDs.insert($0.id).inserted }

        let missing = serverSongs.filter { song in
            !existing.contains(NaviLibraryIndex.expectedRemoteFilename(for: song))
        }
        let alreadyPresent = serverSongs.count - missing.count

        if missing.isEmpty {
            await report(progress, "Already in sync", 1.0)
            return FullLibrarySyncResult(
                serverSongs: serverSongs.count,
                alreadyPresent: alreadyPresent,
                imported: 0,
                batches: 0
            )
        }

        let totalBatches = Int(ceil(Double(missing.count) / Double(batchSize)))
        var imported = 0
        var coverCache: [String: Data] = [:]
        var unavailableCovers = Set<String>()

        for batchIndex in 0..<totalBatches {
            let lower = batchIndex * batchSize
            let upper = min(lower + batchSize, missing.count)
            let batch = Array(missing[lower..<upper])
            var payloads: [FullLibraryTrackPayload] = []
            payloads.reserveCapacity(batch.count)

            for (offset, song) in batch.enumerated() {
                let globalIndex = lower + offset
                let baseProgress = 0.10 + (Double(globalIndex) / Double(max(missing.count, 1))) * 0.72
                await report(progress, "Downloading \(globalIndex + 1)/\(missing.count): \(song.title)", baseProgress)

                let localURL = try await client.downloadForMusicInjection(song)
                let metadata = try InjectionSongMetadata(song: song, localURL: localURL)
                let mutation = try LocalMusicDatabaseBuilder().addSingleTrack(metadata, to: stage.databaseURL)
                try MusicRecordPostProcessor().finalize(
                    databaseURL: mutation.databaseURL,
                    currentItemPID: mutation.itemPID,
                    remoteFilename: mutation.remoteFilename,
                    repairSort: false
                )

                var artwork: InjectionArtwork?
                if let coverID = song.coverArt, !coverID.isEmpty, !unavailableCovers.contains(coverID) {
                    let imageData: Data?
                    if let cached = coverCache[coverID] {
                        imageData = cached
                    } else {
                        do {
                            let fetched = try await client.coverArt(id: coverID)
                            coverCache[coverID] = fetched
                            imageData = fetched
                        } catch {
                            unavailableCovers.insert(coverID)
                            imageData = nil
                        }
                    }

                    if let imageData, let made = InjectionArtwork.make(from: imageData, itemPID: mutation.itemPID) {
                        try MusicArtworkDatabaseWriter().attachAlbumArtwork(
                            databaseURL: mutation.databaseURL,
                            itemPID: mutation.itemPID,
                            artwork: made
                        )
                        artwork = made
                    }
                }

                payloads.append(FullLibraryTrackPayload(metadata: metadata, artwork: artwork))
            }

            await report(progress, "Finalizing batch \(batchIndex + 1)/\(totalBatches)", 0.83 + Double(batchIndex) / Double(max(totalBatches, 1)) * 0.08)
            try MusicSortRepair().repair(databaseURL: stage.databaseURL)
            try validate(databaseURL: stage.databaseURL)

            await report(progress, "Writing batch \(batchIndex + 1)/\(totalBatches) to Music", 0.91 + Double(batchIndex) / Double(max(totalBatches, 1)) * 0.08)
            try FullLibraryDeviceWriter().commit(
                tracks: payloads,
                modifiedDatabaseURL: stage.databaseURL,
                pairingFileURL: pairingFileURL,
                requiresRemotePairing: requiresRemotePairing
            )

            for payload in payloads {
                try? FileManager.default.removeItem(at: payload.metadata.localURL)
            }
            imported += payloads.count
        }

        await client.cleanupOldInjectionStaging()
        await report(progress, "Library sync complete", 1.0)
        return FullLibrarySyncResult(
            serverSongs: serverSongs.count,
            alreadyPresent: alreadyPresent,
            imported: imported,
            batches: totalBatches
        )
    }

    private func persistPreSyncBackup(from databaseURL: URL) throws {
        let fm = FileManager.default
        let directory = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicLibraryBackups", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let destination = directory.appendingPathComponent("MediaLibrary-pre-full-sync-\(formatter.string(from: Date())).sqlitedb")
        if !fm.fileExists(atPath: destination.path) {
            try fm.copyItem(at: databaseURL, to: destination)
        }
    }

    private func validate(databaseURL: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw FullLibrarySyncError.databaseValidationFailed("could not open SQLite database")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw FullLibrarySyncError.databaseValidationFailed("quick_check could not start")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            throw FullLibrarySyncError.databaseValidationFailed("quick_check returned no result")
        }
        let result = String(cString: text)
        guard result == "ok" else { throw FullLibrarySyncError.databaseValidationFailed(result) }
    }

    private func report(_ handler: ProgressHandler?, _ text: String, _ value: Double) async {
        guard let handler else { return }
        await handler(text, min(max(value, 0), 1))
    }
}
