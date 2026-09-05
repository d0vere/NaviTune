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

    func albumSongs(_ album: Album) async -> [Song] {
        guard let client else { return [] }
        do { return try await client.songs(in: album.id) }
        catch {
            message = error.localizedDescription
            return []
        }
    }
}
