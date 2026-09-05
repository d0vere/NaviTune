import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var pairingStore: PairingFileStore

    @State private var showingSettings = false
    @State private var showingMaintenance = false
    @State private var alertText: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    hero
                    readinessCard
                    syncCard
                    if model.loading || !model.activityLog.isEmpty {
                        ActivityCard()
                    }
                    libraryOverview
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 36)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("NaviTune")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingMaintenance = true
                    } label: {
                        Image(systemName: "wrench.and.screwdriver")
                    }
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .environmentObject(model)
                    .environmentObject(pairingStore)
            }
            .sheet(isPresented: $showingMaintenance) {
                MaintenanceView()
                    .environmentObject(model)
                    .environmentObject(pairingStore)
            }
            .alert("NaviTune", isPresented: Binding(
                get: { model.message != nil || alertText != nil },
                set: { if !$0 { model.message = nil; alertText = nil } }
            )) {
                Button("OK", role: .cancel) {
                    model.message = nil
                    alertText = nil
                }
            } message: {
                Text(alertText ?? model.message ?? "")
            }
            .task {
                if !model.connected && !model.server.isEmpty && !model.username.isEmpty && !model.password.isEmpty {
                    await model.connect()
                    if model.connected {
                        model.message = nil
                    }
                }
            }
        }
    }

    private var hero: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .frame(width: 74, height: 74)
                Image(systemName: "music.note.list")
                    .font(.system(size: 31, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Your Navidrome library")
                    .font(.title2.bold())
                Text("Synced into Apple Music, locally on this iPhone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
    }

    private var readinessCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Ready to sync")
                    .font(.headline)
                Spacer()
                if model.connected && pairingStore.pairingFileURL != nil {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                } else {
                    Label("Setup needed", systemImage: "exclamationmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }

            HStack(spacing: 10) {
                StatusPill(title: "Navidrome", ready: model.connected, symbol: "server.rack")
                StatusPill(title: "Pairing", ready: pairingStore.pairingFileURL != nil, symbol: "iphone")
                StatusPill(title: "Music", ready: true, symbol: "music.note")
            }
        }
        .cardStyle()
    }

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.loading ? model.activityTitle : "Incremental sync")
                        .font(.headline)
                    Text(model.loading
                         ? "You can leave NaviTune open or move it to the background."
                         : "Checks the live Music database and downloads only tracks that are missing.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.loading {
                    ProgressView()
                        .controlSize(.large)
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 32))
                }
            }

            if let progress = model.activityProgress, model.loading {
                ProgressView(value: progress)
                HStack {
                    Text("Sync in progress")
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Button {
                if !model.connected || pairingStore.pairingFileURL == nil {
                    showingSettings = true
                } else if let pairingURL = pairingStore.pairingFileURL {
                    Task {
                        await model.syncEntireNavidromeLibrary(
                            pairingFileURL: pairingURL,
                            requiresRemotePairing: pairingStore.requiresRPPairingFile
                        )
                    }
                }
            } label: {
                HStack {
                    Image(systemName: model.loading ? "clock.fill" : "arrow.triangle.2.circlepath")
                    Text(model.loading ? "Sync running" : "Sync now")
                        .fontWeight(.semibold)
                    Spacer()
                    if !model.loading {
                        Image(systemName: "arrow.right")
                            .font(.caption.bold())
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.loading)
        }
        .cardStyle()
    }

    private var libraryOverview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Navidrome")
                    .font(.headline)
                Spacer()
                if model.connected {
                    Button("Refresh") { Task { await model.refresh() } }
                        .font(.caption.weight(.semibold))
                        .disabled(model.loading)
                }
            }

            HStack(spacing: 12) {
                MetricCard(value: "\(model.albums.count)", label: "Recent albums", symbol: "square.stack.fill")
                MetricCard(value: "\(model.starred.count)", label: "Starred loaded", symbol: "star.fill")
            }

            if !model.albums.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Recently added")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(model.albums.prefix(6)) { album in
                        NavigationLink {
                            AlbumView(album: album)
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(.thinMaterial)
                                        .frame(width: 46, height: 46)
                                    Image(systemName: "music.note")
                                        .foregroundStyle(.secondary)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(album.artist ?? "Unknown artist")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .cardStyle()
    }
}

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var pairingStore: PairingFileStore

    @State private var showingPairingImporter = false
    @State private var localMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Navidrome") {
                    TextField("https://music.example.com", text: $model.server)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("Username", text: $model.username)
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $model.password)
                    Button(model.connected ? "Reconnect" : "Connect") {
                        Task { await model.connect() }
                    }
                    .disabled(model.server.isEmpty || model.username.isEmpty || model.password.isEmpty || model.loading)
                }

                Section("Device pairing") {
                    Label(
                        pairingStore.status,
                        systemImage: pairingStore.pairingFileURL == nil ? "iphone.slash" : "checkmark.circle.fill"
                    )
                    Button("Import \(pairingStore.expectedFilename)") {
                        showingPairingImporter = true
                    }
                    if pairingStore.pairingFileURL != nil {
                        Button("Remove pairing file", role: .destructive) {
                            do { try pairingStore.removePairingFile() }
                            catch { localMessage = error.localizedDescription }
                        }
                    }
                }

                Section("Background sync") {
                    Label("Manual sync can continue after locking the screen on iOS 26+.", systemImage: "moon.stars.fill")
                    Text("For nightly updates, create a Personal Automation in Shortcuts and run “Sync NaviTune Library”. Existing Music tracks are skipped automatically; only missing Navidrome tracks are imported.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("Keep LocalDevVPN or the equivalent local-device tunnel active whenever NaviTune syncs with Music.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showingPairingImporter,
                allowedContentTypes: [.propertyList, .data],
                allowsMultipleSelection: false
            ) { result in
                do {
                    guard let url = try result.get().first else { return }
                    try pairingStore.importPairingFile(from: url)
                } catch {
                    localMessage = error.localizedDescription
                }
            }
            .alert("NaviTune", isPresented: Binding(
                get: { localMessage != nil },
                set: { if !$0 { localMessage = nil } }
            )) {
                Button("OK", role: .cancel) { localMessage = nil }
            } message: {
                Text(localMessage ?? "")
            }
        }
    }
}

private struct MaintenanceView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var pairingStore: PairingFileStore

    @State private var localMessage: String?
    @State private var confirmCleanup = false

    var body: some View {
        NavigationStack {
            List {
                Section("Device diagnostics") {
                    if let pairingURL = pairingStore.pairingFileURL {
                        Button("Test device connection") {
                            do {
                                try DeviceBridge().testConnection(pairingFileURL: pairingURL, requiresRemotePairing: pairingStore.requiresRPPairingFile)
                                localMessage = "Device heartbeat connected successfully."
                            } catch { localMessage = error.localizedDescription }
                        }

                        Button("Inspect Music library") {
                            do {
                                let result = try DeviceBridge().inspectSystemMusicLibrary(pairingFileURL: pairingURL, requiresRemotePairing: pairingStore.requiresRPPairingFile)
                                localMessage = result.summary
                            } catch { localMessage = error.localizedDescription }
                        }

                        Button("Validate Music database") {
                            do {
                                let snapshot = try DeviceBridge().stageSystemMusicDatabase(pairingFileURL: pairingURL, requiresRemotePairing: pairingStore.requiresRPPairingFile)
                                defer { try? FileManager.default.removeItem(at: snapshot.directoryURL) }
                                let report = try MusicLibraryStager().prepareWorkingCopy(from: snapshot.databaseURL)
                                localMessage = report.summary
                            } catch { localMessage = error.localizedDescription }
                        }
                    } else {
                        Text("Import the pairing file in Settings first.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Library maintenance") {
                    if let pairingURL = pairingStore.pairingFileURL {
                        Button("Clean duplicates & ghost tracks") {
                            confirmCleanup = true
                        }
                        .disabled(model.loading)
                        .confirmationDialog(
                            "Clean NaviTune duplicates?",
                            isPresented: $confirmCleanup,
                            titleVisibility: .visible
                        ) {
                            Button("Clean duplicates", role: .destructive) {
                                Task {
                                    await model.cleanDuplicateAndGhostTracks(
                                        pairingFileURL: pairingURL,
                                        requiresRemotePairing: pairingStore.requiresRPPairingFile
                                    )
                                }
                            }
                            Button("Cancel", role: .cancel) { }
                        } message: {
                            Text("A rollback database is created before replacement. Music should be closed during this operation.")
                        }
                    }
                }

                Section("Recovery") {
                    EmergencyLibraryRestoreButton()
                    MusicLibraryWipeButton()
                }

                Section {
                    Text("Artist artwork is intentionally not modified by NaviTune. Music handles artist imagery independently.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Maintenance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("NaviTune", isPresented: Binding(
                get: { localMessage != nil },
                set: { if !$0 { localMessage = nil } }
            )) {
                Button("OK", role: .cancel) { localMessage = nil }
            } message: {
                Text(localMessage ?? "")
            }
        }
    }
}

private struct ActivityCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if model.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Text("Activity").font(.headline)
                Spacer()
                if !model.loading {
                    Button("Clear") { model.clearActivityLog() }
                        .font(.caption.weight(.semibold))
                }
            }

            if let progress = model.activityProgress {
                ProgressView(value: progress)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.activityLog.suffix(12).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 130)
        }
        .cardStyle()
    }
}

private struct StatusPill: View {
    let title: String
    let ready: Bool
    let symbol: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: ready ? "checkmark.circle.fill" : symbol)
                .font(.title3)
                .foregroundStyle(ready ? .green : .secondary)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct MetricCard: View {
    let value: String
    let label: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.title3.bold()).monospacedDigit()
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct AlbumView: View {
    @EnvironmentObject private var model: AppModel
    let album: Album
    @State private var songs: [Song] = []

    var body: some View {
        List(songs) { song in
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title).font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(song.artist ?? "Unknown artist")
                    if let genre = song.genre, !genre.isEmpty {
                        Text("•")
                        Text(genre)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
        }
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { songs = await model.albumSongs(album) }
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.05))
            }
    }
}
