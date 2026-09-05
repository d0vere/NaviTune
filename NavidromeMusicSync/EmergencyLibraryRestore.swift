import Foundation
import SwiftUI

@MainActor
extension AppModel {
    func emergencyRestoreLatestMusicBackup(pairingFileURL: URL, requiresRemotePairing: Bool) async {
        loading = true
        activityTitle = "Emergency Music library restore"
        activityProgress = 0
        activityLog.removeAll(keepingCapacity: true)
        activityLog.append("Restoring the newest local Music database backup")

        do {
            let fm = FileManager.default
            let directory = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MusicLibraryBackups", isDirectory: true)

            let backups = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension.lowercased() == "sqlitedb" }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }

            guard let backup = backups.first else {
                throw EmergencyRestoreError.noLocalBackup
            }

            activityProgress = 0.25
            activityTitle = "Validating local backup"
            activityLog.append("Backup selected: \(backup.lastPathComponent)")

            let data = try Data(contentsOf: backup, options: [.mappedIfSafe])
            guard data.starts(with: Data("SQLite format 3\0".utf8)) else {
                throw EmergencyRestoreError.invalidBackup
            }

            activityProgress = 0.55
            activityTitle = "Writing known-good database"
            activityLog.append("Music must remain closed during restore")

            let result = try LegacyGhostDeviceWriter().commit(
                modifiedDatabaseURL: backup,
                legacyFilenames: [],
                pairingFileURL: pairingFileURL,
                requiresRemotePairing: requiresRemotePairing
            )

            activityProgress = 1
            activityTitle = "Restore complete"
            activityLog.append("Known-good database restored")
            activityLog.append("Broken live database retained at \(result.databaseBackupPath)")
            loading = false
            message = "Emergency restore completed from \(backup.lastPathComponent). Force-close Music if it is open, then reopen it and check the library. Do not run metadata repair or cleanup yet."
        } catch {
            activityProgress = nil
            activityTitle = "Emergency restore failed"
            activityLog.append("ERROR: \(error.localizedDescription)")
            loading = false
            message = error.localizedDescription
        }
    }
}

enum EmergencyRestoreError: LocalizedError {
    case noLocalBackup
    case invalidBackup

    var errorDescription: String? {
        switch self {
        case .noLocalBackup:
            return "No local Music database backup was found in Documents/MusicLibraryBackups. Do not perform any other write operation; the remote .navsync-backup may still be recoverable."
        case .invalidBackup:
            return "The newest local Music backup is not a valid SQLite database. Do not perform any other write operation."
        }
    }
}

struct EmergencyLibraryRestoreButton: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var pairingStore: PairingFileStore
    @State private var confirmRestore = false

    var body: some View {
        if let pairingURL = pairingStore.pairingFileURL {
            Button(role: .destructive) {
                confirmRestore = true
            } label: {
                Label("Emergency restore Music DB", systemImage: "lifepreserver.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.loading)
            .padding(.top, 8)
            .padding(.trailing, 8)
            .confirmationDialog(
                "Restore the newest known-good Music database backup?",
                isPresented: $confirmRestore,
                titleVisibility: .visible
            ) {
                Button("Restore newest backup", role: .destructive) {
                    Task {
                        await model.emergencyRestoreLatestMusicBackup(
                            pairingFileURL: pairingURL,
                            requiresRemotePairing: pairingStore.requiresRPPairingFile
                        )
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Force-close Music first and keep LocalDevVPN active. This restores only the Music database from the newest local pre-write backup; it does not delete audio files. Do not use cleanup or metadata repair before recovery.")
            }
        }
    }
}
