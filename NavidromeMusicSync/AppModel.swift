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

    private var client: NavidromeClient?
    private let injector: SystemMusicInjecting = SystemMusicInjector()

    init() {
        let saved = NavidromeSettingsStore.load()
        self.server = saved.server
        self.username = saved.username
        self.password = saved.password
    }

    func connect() async {
        loading = true
        defer { loading = false }
        do {
            let client = try NavidromeClient(server: server, username: username, password: password)
            try await client.ping()
            self.client = client
            connected = true
            NavidromeSettingsStore.save(server: server, username: username, password: password)
            async let albums = client.newestAlbums()
            async let starred = client.starredSongs()
            self.albums = try await albums
            self.starred = try await starred
            message = "Connected to Navidrome. Settings saved on this iPhone."
        } catch {
            connected = false
            message = error.localizedDescription
        }
    }

    func refresh() async {
        guard let client else { return }
        loading = true
        defer { loading = false }
        do {
            async let albums = client.newestAlbums()
            async let starred = client.starredSongs()
            self.albums = try await albums
            self.starred = try await starred
        } catch {
            message = error.localizedDescription
        }
    }

    func downloadAndImport(_ song: Song) async {
        guard let client else { return }
        loading = true
        defer { loading = false }
        do {
            let file = try await client.download(song)
            do {
                try await injector.importTrack(fileURL: file, song: song)
                message = "Imported \(song.title) into Music."
            } catch {
                message = "Downloaded \(song.title). \(error.localizedDescription)"
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func simulateLocalInjection(
        _ song: Song,
        pairingFileURL: URL,
        requiresRemotePairing: Bool
    ) async {
        guard let client else { return }
        loading = true
        defer { loading = false }

        do {
            let localFile = try await client.download(song)
            let metadata = try InjectionSongMetadata(song: song, localURL: localFile)

            let snapshot = try DeviceBridge().stageSystemMusicDatabase(
                pairingFileURL: pairingFileURL,
                requiresRemotePairing: requiresRemotePairing
            )
            defer { try? FileManager.default.removeItem(at: snapshot.directoryURL) }

            let stage = try MusicLibraryStager().prepareWorkingCopy(from: snapshot.databaseURL)
            let result = try LocalMusicDatabaseBuilder().addSingleTrack(metadata, to: stage.databaseURL)
            try MusicRecordPostProcessor().finalize(
                databaseURL: result.databaseURL,
                currentItemPID: result.itemPID,
                remoteFilename: result.remoteFilename
            )
            message = "\(result.summary) iOS 26 local/store flags and duplicate records were normalized."
        } catch {
            message = error.localizedDescription
        }
    }

    func commitInjection(
        _ song: Song,
        pairingFileURL: URL,
        requiresRemotePairing: Bool
    ) async {
        guard let client else { return }
        loading = true
        defer { loading = false }

        do {
            let localFile = try await client.download(song)
            let metadata = try InjectionSongMetadata(song: song, localURL: localFile)

            let snapshot = try DeviceBridge().stageSystemMusicDatabase(
                pairingFileURL: pairingFileURL,
                requiresRemotePairing: requiresRemotePairing
            )
            defer { try? FileManager.default.removeItem(at: snapshot.directoryURL) }

            let backupURL = try persistLocalDatabaseBackup(from: snapshot.databaseURL)

            let stage = try MusicLibraryStager().prepareWorkingCopy(from: snapshot.databaseURL)
            let mutation = try LocalMusicDatabaseBuilder().addSingleTrack(metadata, to: stage.databaseURL)
            try MusicRecordPostProcessor().finalize(
                databaseURL: mutation.databaseURL,
                currentItemPID: mutation.itemPID,
                remoteFilename: mutation.remoteFilename
            )

            let result = try DeviceWriteBackService().commit(
                metadata: metadata,
                modifiedDatabaseURL: mutation.databaseURL,
                pairingFileURL: pairingFileURL,
                requiresRemotePairing: requiresRemotePairing
            )

            message = "\(result.summary) Local backup: \(backupURL.lastPathComponent). Existing records for this Navidrome track were replaced, not duplicated. Close and reopen Music before checking it."
        } catch {
            message = error.localizedDescription
        }
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
