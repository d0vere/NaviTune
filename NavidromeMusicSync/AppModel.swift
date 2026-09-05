import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var server: String
    @Published var username: String
    @Published var password: String
    @Published var connected = false
    @Published var loading = false
    @Published var albums: [Album] = []
    @Published var starred: [Song] = []
    @Published var message: String?
    @Published var activityTitle = "Idle"
    @Published var activityProgress: Double? = nil
    @Published var activityLog: [String] = []

    private var client: NavidromeClient?
    private let injector: SystemMusicInjecting = SystemMusicInjector()

    init() {
        let saved = NavidromeSettingsStore.load()
        self.server = saved.server
        self.username = saved.username
        self.password = saved.password
    }

    func connect() async {
        beginActivity("Connecting to Navidrome")
        NavidromeSettingsStore.save(server: server, username: username, password: password)
        log("Settings saved locally")
        do {
            let client = try NavidromeClient(server: server, username: username, password: password)
            progress("Pinging server", 0.35)
            try await client.ping()
            self.client = client
            connected = true
            progress("Loading library", 0.65)
            async let albums = client.newestAlbums()
            async let starred = client.starredSongs()
            self.albums = try await albums
            self.starred = try await starred
            progress("Connected", 1.0)
            message = "Connected to Navidrome. Settings saved on this iPhone."
            finishActivity()
        } catch {
            failActivity(error)
            connected = false
            message = error.localizedDescription
        }
    }

    func refresh() async {
        guard let client else { return }
        beginActivity("Refreshing Navidrome")
        do {
            progress("Fetching albums and starred tracks", 0.4)
            async let albums = client.newestAlbums()
            async let starred = client.starredSongs()
            self.albums = try await albums
            self.starred = try await starred
            progress("Refresh complete", 1.0)
            finishActivity()
        } catch {
            failActivity(error)
            message = error.localizedDescription
        }
    }

    func downloadAndImport(_ song: Song) async {
        guard let client else { return }
        beginActivity("Downloading \(song.title)")
        do {
            progress("Downloading original audio", 0.35)
            let file = try await client.download(song)
            progress("Calling placeholder importer", 0.7)
            do {
                try await injector.importTrack(fileURL: file, song: song)
                message = "Imported \(song.title) into Music."
                progress("Done", 1.0)
                finishActivity()
            } catch {
                failActivity(error)
                message = "Downloaded \(song.title). \(error.localizedDescription)"
            }
        } catch {
            failActivity(error)
            message = error.localizedDescription
        }
    }

    func simulateLocalInjection(
        _ song: Song,
        pairingFileURL: URL,
        requiresRemotePairing: Bool
    ) async {
        guard let client else { return }
        beginActivity("Simulating injection: \(song.title)")

        do {
            progress("Transcoding/downloading MP3 from Navidrome", 0.12)
            let localFile = try await client.downloadForMusicInjection(song)
            log("MP3 ready: \(localFile.lastPathComponent)")

            progress("Reading Music database over RP/AFC", 0.30)
            let metadata = try InjectionSongMetadata(song: song, localURL: localFile)
            let snapshot = try DeviceBridge().stageSystemMusicDatabase(
                pairingFileURL: pairingFileURL,
                requiresRemotePairing: requiresRemotePairing
            )
            defer { try? FileManager.default.removeItem(at: snapshot.directoryURL) }
            log("Music database snapshot: \(snapshot.byteCount) bytes")

            progress("Preparing safe working copy", 0.50)
            let stage = try MusicLibraryStager().prepareWorkingCopy(from: snapshot.databaseURL)

            progress("Creating local Music record", 0.68)
            let result = try LocalMusicDatabaseBuilder().addSingleTrack(metadata, to: stage.databaseURL)

            progress("Normalizing local-only flags and duplicates", 0.86)
            try MusicRecordPostProcessor().finalize(
                databaseURL: result.databaseURL,
                currentItemPID: result.itemPID,
                remoteFilename: result.remoteFilename
            )
            progress("Simulation complete", 1.0)
            message = "\(result.summary) Injection test used a normalized MP3 asset."
            finishActivity()
        } catch {
            failActivity(error)
            message = error.localizedDescription
        }
    }

    func commitInjection(
        _ song: Song,
        pairingFileURL: URL,
        requiresRemotePairing: Bool
    ) async {
        guard let client else { return }
        beginActivity("Injecting into Music: \(song.title)")

        do {
            progress("Transcoding/downloading MP3 from Navidrome", 0.08)
            let localFile = try await client.downloadForMusicInjection(song)
            let metadata = try InjectionSongMetadata(song: song, localURL: localFile)
            log("Audio ready: \(metadata.remoteFilename), \(metadata.fileSize) bytes")

            progress("Reading live Music database over RP/AFC", 0.22)
            let snapshot = try DeviceBridge().stageSystemMusicDatabase(
                pairingFileURL: pairingFileURL,
                requiresRemotePairing: requiresRemotePairing
            )
            defer { try? FileManager.default.removeItem(at: snapshot.directoryURL) }
            log("Downloaded MediaLibrary.sqlitedb")

            progress("Saving local rollback backup", 0.35)
            let backupURL = try persistLocalDatabaseBackup(from: snapshot.databaseURL)
            log("Backup: \(backupURL.lastPathComponent)")

            progress("Preparing and validating working database", 0.48)
            let stage = try MusicLibraryStager().prepareWorkingCopy(from: snapshot.databaseURL)

            progress("Writing song metadata into database", 0.62)
            let mutation = try LocalMusicDatabaseBuilder().addSingleTrack(metadata, to: stage.databaseURL)

            progress("Removing duplicates and normalizing local flags", 0.73)
            try MusicRecordPostProcessor().finalize(
                databaseURL: mutation.databaseURL,
                currentItemPID: mutation.itemPID,
                remoteFilename: mutation.remoteFilename
            )

            progress("Uploading audio and database over RP/AFC", 0.84)
            let result = try DeviceWriteBackService().commit(
                metadata: metadata,
                modifiedDatabaseURL: mutation.databaseURL,
                pairingFileURL: pairingFileURL,
                requiresRemotePairing: requiresRemotePairing
            )
            log("Remote write-back completed")

            progress("Injection complete", 1.0)
            message = "\(result.summary) Local backup: \(backupURL.lastPathComponent). Injected audio was normalized to MP3 for native Music compatibility. Close and reopen Music before checking it."
            finishActivity()
        } catch {
            failActivity(error)
            message = error.localizedDescription
        }
    }

    func cleanLegacyGhostTracks(pairingFileURL: URL, requiresRemotePairing: Bool) async {
        beginActivity("Cleaning legacy ghost tracks")
        do {
            progress("Reading live Music database over RP/AFC", 0.15)
            let snapshot = try DeviceBridge().stageSystemMusicDatabase(
                pairingFileURL: pairingFileURL,
                requiresRemotePairing: requiresRemotePairing
            )
            defer { try? FileManager.default.removeItem(at: snapshot.directoryURL) }

            progress("Saving local rollback backup", 0.28)
            let backupURL = try persistLocalDatabaseBackup(from: snapshot.databaseURL)
            log("Backup: \(backupURL.lastPathComponent)")

            progress("Preparing safe working copy", 0.42)
            let stage = try MusicLibraryStager().prepareWorkingCopy(from: snapshot.databaseURL)

            progress("Finding records created by old test builds", 0.58)
            let cleanup = try LegacyGhostCleanupService().clean(databaseURL: stage.databaseURL)
            log("Legacy candidates: \(cleanup.removedItems)")

            guard cleanup.removedItems > 0 else {
                progress("No ghost tracks found", 1.0)
                message = cleanup.summary
                finishActivity()
                return
            }

            progress("Writing cleaned database with rollback protection", 0.78)
            let deviceResult = try LegacyGhostDeviceWriter().commit(
                modifiedDatabaseURL: cleanup.databaseURL,
                legacyFilenames: cleanup.removedFiles,
                pairingFileURL: pairingFileURL,
                requiresRemotePairing: requiresRemotePairing
            )
            log("Removed remote legacy files: \(deviceResult.removedRemoteFiles)")

            progress("Ghost cleanup complete", 1.0)
            message = "\(cleanup.summary) Local backup: \(backupURL.lastPathComponent). Remote rollback DB: \(deviceResult.databaseBackupPath). Close and reopen Music."
            finishActivity()
        } catch {
            failActivity(error)
            message = error.localizedDescription
        }
    }

    func clearActivityLog() {
        activityLog.removeAll()
        if !loading { activityTitle = "Idle" }
    }

    private func beginActivity(_ title: String) {
        loading = true
        activityTitle = title
        activityProgress = 0
        activityLog.removeAll(keepingCapacity: true)
        log(title)
    }

    private func progress(_ text: String, _ value: Double) {
        activityTitle = text
        activityProgress = min(max(value, 0), 1)
        log(text)
    }

    private func log(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        activityLog.append("[\(formatter.string(from: Date()))] \(text)")
        if activityLog.count > 80 { activityLog.removeFirst(activityLog.count - 80) }
    }

    private func finishActivity() {
        loading = false
        activityProgress = 1
        log("Done")
    }

    private func failActivity(_ error: Error) {
        activityTitle = "Operation failed"
        activityProgress = nil
        log("ERROR: \(error.localizedDescription)")
        loading = false
    }

    private func persistLocalDatabaseBackup(from sourceURL: URL) throws -> URL {
        let fm = FileManager.default
        let directory = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicLibraryBackups", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let destination = directory.appendingPathComponent(
            "MediaLibrary-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).sqlitedb"
        )
        try fm.copyItem(at: sourceURL, to: destination)
        return destination
    }

    func albumSongs(_ album: Album) async -> [Song] {
        guard let client else { return [] }
        do { return try await client.songs(in: album.id) }
        catch {
            message = error.localizedDescription
            return []
        }
    }
}
