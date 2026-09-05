import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var server = ""
    @Published var username = ""
    @Published var password = ""
    @Published var connected = false
    @Published var loading = false
    @Published var albums: [Album] = []
    @Published var starred: [Song] = []
    @Published var message: String?

    private var client: NavidromeClient?
    private let injector: SystemMusicInjecting = SystemMusicInjector()

    func connect() async {
        loading = true
        defer { loading = false }
        do {
            let client = try NavidromeClient(server: server, username: username, password: password)
            try await client.ping()
            self.client = client
            connected = true
            password = ""
            async let albums = client.newestAlbums()
            async let starred = client.starredSongs()
            self.albums = try await albums
            self.starred = try await starred
            message = "Connected to Navidrome."
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

    /// Full pre-write pipeline: Navidrome download -> read-only device snapshot ->
    /// protected working copy -> schema-aware single-track mutation -> quick_check.
    /// No AFC upload or device database replacement happens here.
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
            message = result.summary
        } catch {
            message = error.localizedDescription
        }
    }

    /// Destructive device write path. The original DB is saved locally before
    /// network writes and a second rollback copy is retained on the device.
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

            // 1. Snapshot the live database before any write.
            let snapshot = try DeviceBridge().stageSystemMusicDatabase(
                pairingFileURL: pairingFileURL,
                requiresRemotePairing: requiresRemotePairing
            )
            defer { try? FileManager.default.removeItem(at: snapshot.directoryURL) }

            // 2. Persist a user-recoverable local backup in Documents.
            let backupURL = try persistLocalDatabaseBackup(from: snapshot.databaseURL)

            // 3. Create and validate the local working copy.
            let stage = try MusicLibraryStager().prepareWorkingCopy(from: snapshot.databaseURL)
            let mutation = try LocalMusicDatabaseBuilder().addSingleTrack(metadata, to: stage.databaseURL)

            // 4. Commit with remote temp files + remote rollback DB.
            let result = try DeviceWriteBackService().commit(
                metadata: metadata,
                modifiedDatabaseURL: mutation.databaseURL,
                pairingFileURL: pairingFileURL,
                requiresRemotePairing: requiresRemotePairing
            )

            message = "\(result.summary) Local backup: \(backupURL.lastPathComponent). Close and reopen Music before checking the new track."
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
        let destination = directory.appendingPathComponent("MediaLibrary-\(formatter.string(from: Date())).sqlitedb")
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
