import AppIntents

@available(iOS 16.0, *)
struct SyncNavidromeLibraryIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync Navidrome Library"
    static var description = IntentDescription("Compare the native Music library with Navidrome and import only missing tracks.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await FullLibrarySyncService().syncUsingSavedConfiguration()
        return .result(dialog: IntentDialog(stringLiteral: result.summary))
    }
}

@available(iOS 16.0, *)
struct NavidromeMusicSyncShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncNavidromeLibraryIntent(),
            phrases: [
                "Sync Navidrome with \(.applicationName)",
                "Update my music with \(.applicationName)"
            ],
            shortTitle: "Sync Navidrome",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
