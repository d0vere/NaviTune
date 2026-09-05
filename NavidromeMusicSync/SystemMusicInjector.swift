import Foundation

protocol SystemMusicInjecting {
    func importTrack(fileURL: URL, song: Song) async throws
}

/// Boundary for the private/internal iOS media-library transport.
///
/// The public iOS SDK does not provide an API for inserting an arbitrary local
/// audio file into Music.app. The ByeTunes-style implementation therefore
/// belongs behind this interface so the Navidrome client and UI remain testable
/// and the risky transport can be replaced when iOS changes.
struct SystemMusicInjector: SystemMusicInjecting {
    enum InjectorError: LocalizedError {
        case notEnabled

        var errorDescription: String? {
            "System Music injection is not enabled in this build yet. The track was downloaded successfully to the app sandbox."
        }
    }

    func importTrack(fileURL: URL, song: Song) async throws {
        throw InjectorError.notEnabled
    }
}
