import AppIntents

@available(iOS 16.0, *)
struct SyncNavidromeLibraryIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync NaviTune Library"
    static var description = IntentDescription("Compare the live Music database with Navidrome and import only missing tracks.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        // Shortcuts/background executions are intentionally bounded to one
        // protected batch. The next run re-reads the live Music database and
        // resumes only with tracks that are still missing.
        _ = try await FullLibrarySyncService().syncUsingSavedConfiguration(maxImports: 25)
        return .result()
    }
}

@available(iOS 16.0, *)
struct NaviTuneShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncNavidromeLibraryIntent(),
            phrases: [
                "Sync my music with \(.applicationName)",
                "Update \(.applicationName)",
                "Sync Navidrome with \(.applicationName)"
            ],
            shortTitle: "Sync NaviTune",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
