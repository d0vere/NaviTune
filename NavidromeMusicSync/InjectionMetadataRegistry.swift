import Foundation

/// Short-lived in-process metadata bridge between the Navidrome download step
/// and the database post-processor. Entries are keyed by the deterministic
/// Music F00 filename and removed after finalization.
enum InjectionMetadataRegistry {
    private static let lock = NSLock()
    private static var genres: [String: String] = [:]

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
}
