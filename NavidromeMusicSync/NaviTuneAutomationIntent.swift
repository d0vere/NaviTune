import AppIntents

/// Headless entry point used by Shortcuts and Personal Automations.
/// It reuses the same incremental engine as the app: the live Music database
/// is inspected first and only missing Navidrome tracks are imported.
struct NaviTuneBackgroundSyncIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync NaviTune Library"
    static var description = IntentDescription(
        "Synchronizes missing Navidrome tracks into the local Music library. Existing tracks are skipped automatically."
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        // Keep a Personal Automation bounded to one protected batch. If more
        // tracks are pending, the next execution re-reads the live Music DB and
        // resumes with only the tracks that are still missing.
        _ = try await FullLibrarySyncService().syncUsingSavedConfiguration(maxImports: 25)
        return .result()
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
