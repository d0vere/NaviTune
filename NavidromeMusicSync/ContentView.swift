import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var pairingStore: PairingFileStore
    @State private var showingPairingImporter = false
    @State private var pairingError: String?

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
                get: { model.message != nil || pairingError != nil },
                set: {
                    if !$0 {
                        model.message = nil
                        pairingError = nil
                    }
                }
            )) {
                Button("OK", role: .cancel) {
                    model.message = nil
                    pairingError = nil
                }
            } message: {
                Text(pairingError ?? model.message ?? "")
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

                if pairingStore.pairingFileURL != nil {
                    Button("Remove pairing file", role: .destructive) {
                        do { try pairingStore.removePairingFile() }
                        catch { pairingError = error.localizedDescription }
                    }
                }

                Text("The pairing record is stored only inside this app's Documents container. On iOS 26.4+ the app expects an RP pairing file, matching the transport used by current ByeTunes builds.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

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

    private var library: some View {
        List {
            Section("Device pairing") {
                HStack {
                    Text(pairingStore.status)
                    Spacer()
                    Button("Import") { showingPairingImporter = true }
                        .buttonStyle(.borderless)
                }
            }

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
