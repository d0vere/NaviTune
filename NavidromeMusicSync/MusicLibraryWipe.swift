import Foundation
import SwiftUI

@MainActor
extension AppModel {
    func wipeMusicLibrary(pairingFileURL: URL, requiresRemotePairing: Bool) async {
        loading = true
        activityTitle = "Resetting Music library"
        activityProgress = 0
        activityLog.removeAll(keepingCapacity: true)

        do {
            activityLog.append("Music must remain force-closed during this operation")

            // Read whatever is currently on device only so we can preserve it.
            // The live database may be structurally broken, so do not validate
            // its schema and do not use it as the template for the replacement.
            activityProgress = 0.12
            activityTitle = "Saving current database"
            let snapshot = try DeviceBridge().stageSystemMusicDatabase(
                pairingFileURL: pairingFileURL,
                requiresRemotePairing: requiresRemotePairing
            )
            defer { try? FileManager.default.removeItem(at: snapshot.directoryURL) }

            let backupDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MusicLibraryBackups", isDirectory: true)
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let backup = backupDir.appendingPathComponent("MediaLibrary-pre-fresh-reset-\(formatter.string(from: Date())).sqlitedb")
            try FileManager.default.copyItem(at: snapshot.databaseURL, to: backup)
            activityLog.append("Current DB saved: \(backup.lastPathComponent)")

            // Build a complete empty iOS 26 MediaLibrary independently of the
            // broken live file. This is the same strategy used by ByeTunes when
            // creating a database from scratch.
            activityProgress = 0.38
            activityTitle = "Building fresh iOS 26 database"
            let freshURL = try FreshMusicDatabaseBuilder().create()
            defer { try? FileManager.default.removeItem(at: freshURL.deletingLastPathComponent()) }
            activityLog.append("Fresh DB created with user_version 2320030")

            activityProgress = 0.68
            activityTitle = "Installing fresh Music database"
            let device = try LegacyGhostDeviceWriter().commit(
                modifiedDatabaseURL: freshURL,
                legacyFilenames: [],
                pairingFileURL: pairingFileURL,
                requiresRemotePairing: requiresRemotePairing
            )
            activityLog.append("Fresh DB promoted to MediaLibrary.sqlitedb")
            activityLog.append("Previous live DB retained at \(device.databaseBackupPath)")

            activityProgress = 1
            activityTitle = "Music database reset complete"
            loading = false
            message = "Fresh iOS 26 Music database installed. Force-close Music if necessary, then open it and verify that it starts with an empty library. Old orphaned F00 audio files are intentionally left untouched during this recovery reset; they do not appear in the new database and can be cleaned safely after Music is healthy. Safety backup: \(backup.lastPathComponent)."
        } catch {
            activityProgress = nil
            activityTitle = "Music database reset failed"
            activityLog.append("ERROR: \(error.localizedDescription)")
            loading = false
            message = error.localizedDescription
        }
    }
}

struct MusicLibraryWipeButton: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var pairingStore: PairingFileStore
    @State private var firstConfirm = false
    @State private var secondConfirm = false

    var body: some View {
        if let pairingURL = pairingStore.pairingFileURL {
            Button(role: .destructive) { firstConfirm = true } label: {
                Label("Wipe Music Library", systemImage: "trash.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.loading)
            .confirmationDialog(
                "Replace the Music database with a fresh empty database?",
                isPresented: $firstConfirm,
                titleVisibility: .visible
            ) {
                Button("Continue", role: .destructive) { secondConfirm = true }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Music must be force-closed. The current database is backed up first, even if its schema is broken. A new empty iOS 26 MediaLibrary database is then installed.")
            }
            .confirmationDialog(
                "Final confirmation",
                isPresented: $secondConfirm,
                titleVisibility: .visible
            ) {
                Button("REBUILD EMPTY MUSIC DB", role: .destructive) {
                    Task {
                        await model.wipeMusicLibrary(
                            pairingFileURL: pairingURL,
                            requiresRemotePairing: pairingStore.requiresRPPairingFile
                        )
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This replaces MediaLibrary.sqlitedb with a fresh empty schema. A byte-for-byte copy of the current database remains available for emergency recovery.")
            }
        }
    }
}
