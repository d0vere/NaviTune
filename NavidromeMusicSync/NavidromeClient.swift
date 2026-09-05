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

    func download(_ song: Song) async throws -> URL {
        try await downloadFile(song: song, extra: [], extensionOverride: song.suffix ?? "m4a", filenameSuffix: "")
    }

    /// Preserve the source file byte-for-byte for Music injection. The previous
    /// forced MP3 path could cause an unnecessary lossy transcode (and on some
    /// Navidrome/transcoding configurations produced audibly degraded output).
    /// The database builder already understands the native audio extensions we
    /// use, so prefer the original Navidrome download.
    func downloadForMusicInjection(_ song: Song) async throws -> URL {
        try await downloadFile(
            song: song,
            extra: [],
            extensionOverride: song.suffix ?? "m4a",
            filenameSuffix: ".music"
        )
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
