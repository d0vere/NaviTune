import SwiftUI

@main
struct NavidromeMusicSyncApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var pairingStore = PairingFileStore()

    init() {
        Task { @MainActor in
            BackgroundSyncCoordinator.shared.registerIfSupported()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(pairingStore)
        }
    }
}
