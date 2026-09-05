import Foundation
import CryptoKit

struct NavidromeMatchedMetadata {
    let genre: String
    let artistID: String?
}

/// Synchronous best-effort lookup used by one-time repair tools. The normal
/// browsing/import path remains async through NavidromeClient.
enum NavidromeMetadataLookup {
    private struct SearchEnvelope: Decodable {
        let response: SearchResponse
        enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
    }

    private struct SearchResponse: Decodable {
        let status: String
        let searchResult3: SearchResult?
    }

    private struct SearchResult: Decodable {
        let song: [SearchSong]?
    }

    private struct SearchSong: Decodable {
        let title: String
        let artist: String?
        let album: String?
        let genre: String?
        let artistId: String?
    }

    static func lookup(title: String, artist: String, album: String?) -> NavidromeMatchedMetadata? {
        let settings = NavidromeSettingsStore.load()
        guard !settings.server.isEmpty, !settings.username.isEmpty, !settings.password.isEmpty else { return nil }

        let normalized = settings.server.hasSuffix("/") ? String(settings.server.dropLast()) : settings.server
        guard let baseURL = URL(string: normalized) else { return nil }
        let salt = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).description
        let token = md5(settings.password + salt)
        let rest = baseURL.appendingPathComponent("rest").appendingPathComponent("search3")
        guard var components = URLComponents(url: rest, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "u", value: settings.username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: "1.16.1"),
            URLQueryItem(name: "c", value: "NavidromeMusicSync"),
            URLQueryItem(name: "f", value: "json"),
            URLQueryItem(name: "query", value: title),
            URLQueryItem(name: "artistCount", value: "0"),
            URLQueryItem(name: "albumCount", value: "0"),
            URLQueryItem(name: "songCount", value: "25")
        ]
        guard let url = components.url, let data = synchronousData(url: url) else { return nil }
        guard let envelope = try? JSONDecoder().decode(SearchEnvelope.self, from: data), envelope.response.status == "ok" else { return nil }

        let wantedTitle = normalizedText(title)
        let wantedArtist = normalizedText(artist)
        let wantedAlbum = album.map(normalizedText)

        let candidates = envelope.response.searchResult3?.song ?? []
        let match = candidates.first { candidate in
            guard normalizedText(candidate.title) == wantedTitle,
                  normalizedText(candidate.artist ?? "") == wantedArtist else { return false }
            if let wantedAlbum, !wantedAlbum.isEmpty {
                return normalizedText(candidate.album ?? "") == wantedAlbum
            }
            return true
        } ?? candidates.first { candidate in
            normalizedText(candidate.title) == wantedTitle && normalizedText(candidate.artist ?? "") == wantedArtist
        }

        guard let match else { return nil }
        let genre = match.genre?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !genre.isEmpty else { return nil }
        return NavidromeMatchedMetadata(genre: genre, artistID: match.artistId)
    }

    private static func synchronousData(url: URL) -> Data? {
        final class Box: @unchecked Sendable { var data: Data? }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data, !data.isEmpty else { return }
            box.data = data
        }.resume()
        _ = semaphore.wait(timeout: .now() + 14)
        return box.data
    }

    private static func normalizedText(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func md5(_ value: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}
