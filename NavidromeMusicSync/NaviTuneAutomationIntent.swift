import AppIntents

/// Headless entry point used by Shortcuts and Personal Automations.
/// It deliberately reuses the exact same incremental engine as the app:
/// the live Music database is inspected first and only missing Navidrome
/// track IDs are downloaded and committed.
struct NaviTuneBackgroundSyncIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync NaviTune Library"
    static var description = IntentDescription(
        "Synchronizes missing Navidrome tracks into the local Music library. Existing tracks are skipped automatically."
    )
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await FullLibrarySyncService().syncUsingSavedConfiguration { _, _ in
            // Shortcuts owns the presentation while this runs headlessly.
            // The service still commits progress batch-by-batch, so an interrupted
            // automation safely resumes from the Music database next time.
        }

        return .result(dialog: "NaviTune sync completed. The Music library is up to date with the tracks this run could process.")
    }
}

struct NaviTuneAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NaviTuneBackgroundSyncIntent(),
            phrases: [
                "Sync my library with \(.applicationName)",
                "Update my music with \(.applicationName)",
                "Sync \(.applicationName)"
            ],
            shortTitle: "Sync Library",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
