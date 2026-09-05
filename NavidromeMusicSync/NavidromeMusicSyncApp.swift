import SwiftUI

@main
struct NavidromeMusicSyncApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var pairingStore = PairingFileStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(pairingStore)
        }
    }
}
