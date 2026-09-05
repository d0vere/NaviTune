import Foundation
import AVFoundation
import CryptoKit

struct InjectionSongMetadata {
    let navidromeID: String
    let localURL: URL
    let title: String
    let artist: String
    let album: String
    let genre: String
    let year: Int
    let trackNumber: Int?
    let fileSize: Int
    let remoteFilename: String
    let fileExtension: String
    let durationMs: Int

    init(song: Song, localURL: URL) throws {
        let values = try localURL.resourceValues(forKeys: [.fileSizeKey])
        self.navidromeID = song.id
        self.localURL = localURL
        self.title = song.title
        self.artist = song.artist ?? "Unknown artist"
        self.album = song.album ?? "Unknown album"
        let trimmedGenre = song.genre?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.genre = trimmedGenre.isEmpty ? "Unknown Genre" : trimmedGenre
        self.year = song.year ?? 0
        self.trackNumber = song.track
        self.fileSize = values.fileSize ?? 0
        let ext = localURL.pathExtension.isEmpty ? (song.suffix ?? "m4a") : localURL.pathExtension.lowercased()
        self.fileExtension = ext
        self.remoteFilename = Self.remoteFilename(for: song.id, ext: ext)
        InjectionMetadataRegistry.setGenre(self.genre, for: self.remoteFilename)

        let asset = AVURLAsset(url: localURL)
        let seconds = CMTimeGetSeconds(asset.duration)
        self.durationMs = seconds.isFinite && seconds > 0 ? Int(seconds * 1000.0) : 0
    }

    private static func remoteFilename(for navidromeID: String, ext: String) -> String {
        let digest = SHA256.hash(data: Data(navidromeID.utf8))
        let stem = digest.prefix(8).map { String(format: "%02X", $0) }.joined()
        return "\(stem).\(ext)"
    }
}
