import Foundation
import SwiftUI

@MainActor
extension AppModel {
    func syncEntireNavidromeLibrary(pairingFileURL: URL, requiresRemotePairing: Bool) async {
        loading = true
        activityTitle = "Preparing NaviTune sync"
        activityProgress = 0
        activityLog.removeAll(keepingCapacity: true)
        activityLog.append("Comparing live Music database with Navidrome")
        NavidromeSettingsStore.save(server: server, username: username, password: password)

        if #available(iOS 26.0, *) {
            do {
                try BackgroundSyncCoordinator.shared.startUserInitiatedSync { [weak self] text, value in
                    guard let self else { return }
                    self.activityTitle = text
                    self.activityProgress = value
                    let formatter = DateFormatter()
                    formatter.dateFormat = "HH:mm:ss"
                    self.activityLog.append("[\(formatter.string(from: Date()))] \(text)")
                    if self.activityLog.count > 120 {
                        self.activityLog.removeFirst(self.activityLog.count - 120)
                    }
                } completion: { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let syncResult):
                        self.loading = false
                        self.activityTitle = "Library sync complete"
                        self.activityProgress = 1
                        self.activityLog.append(syncResult.summary)
                        self.message = syncResult.summary + " Music can be reopened after the sync has finished."
                    case .failure(let error):
                        self.loading = false
                        self.activityTitle = "Library sync failed"
                        self.activityProgress = nil
                        self.activityLog.append("ERROR: \(error.localizedDescription)")
                        self.message = error.localizedDescription
                    }
                }
                activityTitle = "Sync running in background"
                activityLog.append("iOS continued-processing task started. You can lock the screen or switch apps.")
                return
            } catch {
                activityLog.append("Continued processing unavailable; using protected foreground fallback: \(error.localizedDescription)")
            }
        }

        let lease = BackgroundExecutionLease(name: "NaviTune Library Sync", keepsScreenAwake: true)
        defer { lease.end() }

        do {
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
            message = result.summary + " Music can be reopened after the sync has finished."
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
                Label("Sync library", systemImage: "arrow.triangle.2.circlepath.circle.fill")
            }
            .disabled(model.loading || !model.connected)
            .confirmationDialog(
                "Sync Navidrome with Music?",
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
                Text("Music should be closed and the local-device VPN/tunnel must remain active. Tracks already present are skipped; only missing tracks are downloaded and committed in protected batches.")
            }
        }
    }
}
