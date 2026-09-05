import Foundation
import SwiftUI

@MainActor
extension AppModel {
    func syncEntireNavidromeLibrary(pairingFileURL: URL, requiresRemotePairing: Bool) async {
        loading = true
        activityTitle = "Syncing complete Navidrome library"
        activityProgress = 0
        activityLog.removeAll(keepingCapacity: true)
        activityLog.append("Comparing live Music database with Navidrome")

        do {
            NavidromeSettingsStore.save(server: server, username: username, password: password)
            let syncClient = try NavidromeClient(server: server, username: username, password: password)
            let result = try await FullLibrarySyncService().sync(
                client: syncClient,
                pairingFileURL: pairingFileURL,
                requiresRemotePairing: requiresRemotePairing
            ) { [weak self] text, value in
                guard let self else { return }
                self.activityTitle = text
                self.activityProgress = value
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss"
                self.activityLog.append("[\(formatter.string(from: Date()))] \(text)")
                if self.activityLog.count > 120 {
                    self.activityLog.removeFirst(self.activityLog.count - 120)
                }
            }

            loading = false
            activityTitle = "Library sync complete"
            activityProgress = 1
            activityLog.append(result.summary)
            message = result.summary + " Close and reopen Music before checking newly imported tracks."
        } catch {
            loading = false
            activityTitle = "Library sync failed"
            activityProgress = nil
            activityLog.append("ERROR: \(error.localizedDescription)")
            message = error.localizedDescription
        }
    }
}

struct FullLibrarySyncButton: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var pairingStore: PairingFileStore
    @State private var confirmSync = false

    var body: some View {
        if let pairingURL = pairingStore.pairingFileURL {
            Button {
                confirmSync = true
            } label: {
                Label("Sync all Navidrome", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.loading || !model.connected)
            .confirmationDialog(
                "Synchronize the complete Navidrome library?",
                isPresented: $confirmSync,
                titleVisibility: .visible
            ) {
                Button("Sync missing tracks") {
                    Task {
                        await model.syncEntireNavidromeLibrary(
                            pairingFileURL: pairingURL,
                            requiresRemotePairing: pairingStore.requiresRPPairingFile
                        )
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Force-close Music first and keep LocalDevVPN active. The live Music database is compared with the full Navidrome catalog. Tracks already present are skipped; only missing tracks are downloaded and added in protected batches.")
            }
        }
    }
}
