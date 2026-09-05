import AppIntents

@available(iOS 16.0, *)
struct SyncNavidromeLibraryIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync NaviTune Library"
    static var description = IntentDescription("Compare Music with Navidrome and import only missing tracks in a background-friendly batch.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Keep scheduled Shortcuts executions bounded. If more than one batch is
        // pending, the next nightly run resumes from the live Music database.
        let result = try await FullLibrarySyncService().syncUsingSavedConfiguration(maxImports: 25)
        return .result(dialog: IntentDialog(stringLiteral: result.summary))
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
