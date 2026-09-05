import Foundation

/// Short-lived in-process metadata bridge between the Navidrome download step,
/// database writers, and AFC artwork uploader. Entries are keyed by the
/// deterministic Music F00 filename or by the album artwork token.
enum InjectionMetadataRegistry {
    private static let lock = NSLock()
    private static var genres: [String: String] = [:]
    private static var artistIDs: [String: String] = [:]
    private static var pendingArtistArtwork: [String: InjectionArtwork] = [:]

    static func setGenre(_ genre: String, for remoteFilename: String) {
        lock.lock()
        genres[remoteFilename] = genre
        lock.unlock()
    }

    static func takeGenre(for remoteFilename: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return genres.removeValue(forKey: remoteFilename)
    }

    static func setArtistID(_ artistID: String, for remoteFilename: String) {
        lock.lock()
        artistIDs[remoteFilename] = artistID
        lock.unlock()
    }

    static func takeArtistID(for remoteFilename: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return artistIDs.removeValue(forKey: remoteFilename)
    }

    static func setPendingArtistArtwork(_ artwork: InjectionArtwork, forAlbumToken albumToken: String) {
        lock.lock()
        pendingArtistArtwork[albumToken] = artwork
        lock.unlock()
    }

    static func takePendingArtistArtwork(forAlbumToken albumToken: String) -> InjectionArtwork? {
        lock.lock()
        defer { lock.unlock() }
        return pendingArtistArtwork.removeValue(forKey: albumToken)
    }
}
