import SwiftUI

@main
struct NavidromeMusicSyncApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var pairingStore = PairingFileStore()

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .topTrailing) {
                ContentView()
                VStack(alignment: .trailing, spacing: 8) {
                    EmergencyLibraryRestoreButton()
                    FullLibrarySyncButton()
                }
            }
            .environmentObject(model)
            .environmentObject(pairingStore)
        }
    }
}
