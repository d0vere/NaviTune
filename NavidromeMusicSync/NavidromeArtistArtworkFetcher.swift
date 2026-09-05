import Foundation
import CryptoKit

/// Best-effort synchronous fetch used inside the existing synchronous Music
/// database/artwork pipeline. Artist artwork failure must never fail a song import.
enum NavidromeArtistArtworkFetcher {
    private final class DataBox: @unchecked Sendable { var data: Data? }

    static func fetch(artistID: String, size: Int = 1200) -> Data? {
        let settings = NavidromeSettingsStore.load()
        guard !settings.server.isEmpty, !settings.username.isEmpty, !settings.password.isEmpty else { return nil }

        let normalized = settings.server.hasSuffix("/") ? String(settings.server.dropLast()) : settings.server
        guard let baseURL = URL(string: normalized) else { return nil }
        let salt = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).description
        let token = md5(settings.password + salt)
        let rest = baseURL.appendingPathComponent("rest").appendingPathComponent("getCoverArt")
        guard var components = URLComponents(url: rest, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "u", value: settings.username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: "1.16.1"),
            URLQueryItem(name: "c", value: "NavidromeMusicSync"),
            URLQueryItem(name: "f", value: "json"),
            URLQueryItem(name: "id", value: artistID),
            URLQueryItem(name: "size", value: String(size))
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let semaphore = DispatchSemaphore(value: 0)
        let box = DataBox()
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data, !data.isEmpty else { return }
            box.data = data
        }.resume()
        _ = semaphore.wait(timeout: .now() + 14)
        return box.data
    }

    private static func md5(_ value: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}
