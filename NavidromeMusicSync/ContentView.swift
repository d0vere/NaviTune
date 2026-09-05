import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var pairingStore: PairingFileStore
    @State private var showingPairingImporter = false
    @State private var pairingError: String?
    @State private var deviceStatus: String?

    var body: some View {
        NavigationStack {
            Group {
                if model.connected { library }
                else { login }
            }
            .navigationTitle("Navi Music Sync")
            .toolbar {
                if model.connected {
                    Button {
                        Task { await model.refresh() }
                    } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .overlay {
                if model.loading { ProgressView().controlSize(.large) }
            }
            .alert("NavidromeMusicSync", isPresented: Binding(
                get: { model.message != nil || pairingError != nil || deviceStatus != nil },
                set: {
                    if !$0 {
                        model.message = nil
                        pairingError = nil
                        deviceStatus = nil
                    }
                }
            )) {
                Button("OK", role: .cancel) {
                    model.message = nil
                    pairingError = nil
                    deviceStatus = nil
                }
            } message: {
                Text(pairingError ?? deviceStatus ?? model.message ?? "")
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
                    pairingError = error.localizedDescription
                }
            }
        }
    }

    private var login: some View {
        Form {
            Section("Navidrome server") {
                TextField("https://music.example.com", text: $model.server)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                TextField("Username", text: $model.username)
                    .textInputAutocapitalization(.never)
                SecureField("Password", text: $model.password)
            }

            pairingSection

            Section {
                Button("Connect") { Task { await model.connect() } }
                    .disabled(model.server.isEmpty || model.username.isEmpty || model.password.isEmpty || model.loading)
            }

            Section {
                Text("Use HTTPS when connecting to a server over the internet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pairingSection: some View {
        Section("Device pairing") {
            HStack {
                Label(
                    pairingStore.status,
                    systemImage: pairingStore.pairingFileURL == nil ? "iphone.slash" : "iphone.and.arrow.forward"
                )
                Spacer()
                if pairingStore.pairingFileURL != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Button("Import \(pairingStore.expectedFilename)") {
                showingPairingImporter = true
            }

            if let pairingURL = pairingStore.pairingFileURL {
                Button("Test device connection") {
                    do {
                        try DeviceBridge().testConnection(
                            pairingFileURL: pairingURL,
                            requiresRemotePairing: pairingStore.requiresRPPairingFile
                        )
                        deviceStatus = "Device heartbeat connected successfully. idevice transport is working."
                    } catch {
                        pairingError = error.localizedDescription
                    }
                }

                Button("Inspect Music library (read-only)") {
                    do {
                        let result = try DeviceBridge().inspectSystemMusicLibrary(
                            pairingFileURL: pairingURL,
                            requiresRemotePairing: pairingStore.requiresRPPairingFile
                        )
                        deviceStatus = result.summary
                    } catch {
                        pairingError = error.localizedDescription
                    }
                }

                Button("Stage & validate Music database") {
                    do {
                        let snapshot = try DeviceBridge().stageSystemMusicDatabase(
                            pairingFileURL: pairingURL,
                            requiresRemotePairing: pairingStore.requiresRPPairingFile
                        )
                        let report = try MusicLibraryStager().prepareWorkingCopy(from: snapshot.databaseURL)
                        deviceStatus = report.summary
                    } catch {
                        pairingError = error.localizedDescription
                    }
                }

                Button("Remove pairing file", role: .destructive) {
                    do { try pairingStore.removePairingFile() }
                    catch { pairingError = error.localizedDescription }
                }
            }

            Text("Stage & validate downloads MediaLibrary.sqlitedb into the app's temporary container, runs SQLite quick_check, validates the expected schema and rolls back a test transaction. It does not write anything back to /iTunes_Control.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var library: some View {
        List {
            pairingSection

            if !model.starred.isEmpty {
                Section("Starred") {
                    ForEach(model.starred.prefix(20)) { song in
                        SongRow(song: song)
                    }
                }
            }
            Section("Newest albums") {
                ForEach(model.albums) { album in
                    NavigationLink {
                        AlbumView(album: album)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(album.name)
                            Text(album.artist ?? "Unknown artist")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct SongRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var pairingStore: PairingFileStore
    let song: Song

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(song.title)
                Text(song.artist ?? "Unknown artist")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if let pairingURL = pairingStore.pairingFileURL {
                Button {
                    Task {
                        await model.simulateLocalInjection(
                            song,
                            pairingFileURL: pairingURL,
                            requiresRemotePairing: pairingStore.requiresRPPairingFile
                        )
                    }
                } label: {
                    Image(systemName: "testtube.2")
                }
                .buttonStyle(.borderless)
                .help("Simulate Music database injection locally")
            }

            Button {
                Task { await model.downloadAndImport(song) }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
        }
    }
}

private struct AlbumView: View {
    @EnvironmentObject private var model: AppModel
    let album: Album
    @State private var songs: [Song] = []

    var body: some View {
        List(songs) { song in SongRow(song: song) }
            .navigationTitle(album.name)
            .task { songs = await model.albumSongs(album) }
    }
}
