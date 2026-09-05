import Foundation
import CryptoKit

actor NavidromeClient {
    enum ClientError: LocalizedError {
        case invalidServerURL
        case serverRejected(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidServerURL: return "Invalid Navidrome server URL."
            case .serverRejected(let status): return "Navidrome returned status: \(status)"
            case .invalidResponse: return "Invalid response from Navidrome."
            }
        }
    }

    private let baseURL: URL
    private let username: String
    private let token: String
    private let salt: String
    private let session: URLSession

    init(server: String, username: String, password: String, session: URLSession = .shared) throws {
        let normalized = server.hasSuffix("/") ? String(server.dropLast()) : server
        guard let url = URL(string: normalized), url.scheme != nil else { throw ClientError.invalidServerURL }
        self.baseURL = url
        self.username = username
        self.salt = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).description
        self.token = Self.md5(password + salt)
        self.session = session
    }

    func ping() async throws {
        let envelope: SubsonicEnvelope<PingResponse> = try await request("ping")
        guard envelope.response.status == "ok" else { throw ClientError.serverRejected(envelope.response.status) }
    }

    func newestAlbums(size: Int = 30) async throws -> [Album] {
        let envelope: SubsonicEnvelope<AlbumListResponse> = try await request("getAlbumList2", extra: [URLQueryItem(name: "type", value: "newest"), URLQueryItem(name: "size", value: String(size))])
        guard envelope.response.status == "ok" else { throw ClientError.serverRejected(envelope.response.status) }
        return envelope.response.albumList2?.album ?? []
    }

    /// Enumerates the complete Navidrome album catalog using Subsonic pagination.
    /// This is intentionally deterministic so a full-device sync can be resumed.
    func allAlbums(pageSize: Int = 500) async throws -> [Album] {
        var result: [Album] = []
        var offset = 0
        let safePageSize = min(max(pageSize, 1), 500)
        while true {
            let envelope: SubsonicEnvelope<AlbumListResponse> = try await request("getAlbumList2", extra: [
                URLQueryItem(name: "type", value: "alphabeticalByName"),
                URLQueryItem(name: "size", value: String(safePageSize)),
                URLQueryItem(name: "offset", value: String(offset))
            ])
            guard envelope.response.status == "ok" else { throw ClientError.serverRejected(envelope.response.status) }
            let page = envelope.response.albumList2?.album ?? []
            result.append(contentsOf: page)
            if page.count < safePageSize { break }
            offset += page.count
        }
        return result
    }

    /// Returns every song on the server. Album requests are made in small
    /// concurrent groups to reduce total catalog scan time without flooding Navidrome.
    func allSongs() async throws -> [Song] {
        let albums = try await allAlbums()
        var songsByAlbum = Array(repeating: [Song](), count: albums.count)
        let concurrency = 6
        var start = 0
        while start < albums.count {
            let end = min(start + concurrency, albums.count)
            try await withThrowingTaskGroup(of: (Int, [Song]).self) { group in
                for index in start..<end {
                    let albumID = albums[index].id
                    group.addTask { [self] in
                        (index, try await songs(in: albumID))
                    }
                }
                for try await (index, songs) in group {
                    songsByAlbum[index] = songs
                }
            }
            start = end
        }
        return songsByAlbum.flatMap { $0 }
    }

    func starredSongs() async throws -> [Song] {
        let envelope: SubsonicEnvelope<StarredResponse> = try await request("getStarred2")
        guard envelope.response.status == "ok" else { throw ClientError.serverRejected(envelope.response.status) }
        return envelope.response.starred2?.song ?? []
    }

    func songs(in albumID: String) async throws -> [Song] {
        let envelope: SubsonicEnvelope<AlbumResponse> = try await request("getAlbum", extra: [URLQueryItem(name: "id", value: albumID)])
        guard envelope.response.status == "ok" else { throw ClientError.serverRejected(envelope.response.status) }
        return envelope.response.album?.song ?? []
    }

    func coverArt(id: String, size: Int = 1200) async throws -> Data {
        let url = try endpoint("getCoverArt", extra: [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "size", value: String(size))
        ])
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw ClientError.invalidResponse
        }
        return data
    }

    func download(_ song: Song) async throws -> URL {
        try await downloadFile(song: song, extra: [], extensionOverride: song.suffix ?? "m4a", filenameSuffix: "")
    }

    /// Preserve the source file byte-for-byte for Music injection.
    func downloadForMusicInjection(_ song: Song) async throws -> URL {
        try await downloadFile(song: song, extra: [], extensionOverride: song.suffix ?? "m4a", filenameSuffix: ".music")
    }

    func cleanupOldInjectionStaging(except keepURL: URL? = nil) {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.contains(".music.") && file != keepURL {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func downloadFile(song: Song, extra: [URLQueryItem], extensionOverride: String, filenameSuffix: String) async throws -> URL {
        let remoteURL = try endpoint("download", extra: [URLQueryItem(name: "id", value: song.id)] + extra)
        let (temporaryURL, response) = try await session.download(from: remoteURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ClientError.invalidResponse }
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("\(song.id)\(filenameSuffix).\(extensionOverride)")
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private func request<T: Decodable>(_ method: String, extra: [URLQueryItem] = []) async throws -> T {
        let url = try endpoint(method, extra: extra)
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ClientError.invalidResponse }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func endpoint(_ method: String, extra: [URLQueryItem]) throws -> URL {
        let rest = baseURL.appendingPathComponent("rest").appendingPathComponent(method)
        guard var components = URLComponents(url: rest, resolvingAgainstBaseURL: false) else { throw ClientError.invalidServerURL }
        components.queryItems = [
            URLQueryItem(name: "u", value: username), URLQueryItem(name: "t", value: token), URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: "1.16.1"), URLQueryItem(name: "c", value: "NavidromeMusicSync"), URLQueryItem(name: "f", value: "json")
        ] + extra
        guard let url = components.url else { throw ClientError.invalidServerURL }
        return url
    }

    private static func md5(_ value: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}
