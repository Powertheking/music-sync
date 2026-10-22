import SwiftUI

@main
struct MusicSyncApp: App {
    @State private var model = SyncModel()

    var body: some Scene {
        WindowGroup("Music Sync") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 520)
                .task { await model.loadPlaylists() }
        }
        Settings {
            SettingsView().environment(model)
        }
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            PlaylistsTab()
                .tabItem { Label("Playlist", systemImage: "music.note.list") }
            SearchTab()
                .tabItem { Label("Cerca brano", systemImage: "magnifyingglass") }
        }
    }
}

struct CookiesPicker: View {
    @Environment(SyncModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Picker("Login YouTube", selection: $model.cookies) {
            Text("Senza login").tag("")
            Text("Cookie Safari").tag("safari")
            Text("Cookie Chrome").tag("chrome")
            Text("Cookie Firefox").tag("firefox")
        }
        .help("Browser da cui prendere il login YouTube per i video con blocco età")
    }
}

struct PlaylistsTab: View {
    @Environment(SyncModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            PlaylistSidebar()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            RunView()
        }
        .searchable(text: $model.filter, placement: .sidebar, prompt: "Cerca playlist")
        .toolbar {
            ToolbarItemGroup {
                CookiesPicker()

                Toggle("Solo anteprima", isOn: $model.dryRun)
                    .toggleStyle(.checkbox)
                    .help("Cerca i match senza scaricare nulla")

                Button {
                    model.openDest()
                } label: {
                    Label("Apri cartella", systemImage: "folder")
                }
                .help("Apri \(model.destDisplay)")

                SettingsLink {
                    Label("Impostazioni", systemImage: "gearshape")
                }
                .help("Cartella, formato e qualità")

                if model.isRunning {
                    Button(role: .cancel) {
                        model.cancel()
                    } label: {
                        Label("Interrompi", systemImage: "stop.fill")
                    }
                } else {
                    Button {
                        Task { await model.sync() }
                    } label: {
                        Label("Sincronizza (\(model.selected.count))",
                              systemImage: "arrow.triangle.2.circlepath")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selected.isEmpty || model.isLoading)
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
        }
    }
}

struct PlaylistSidebar: View {
    @Environment(SyncModel.self) private var model
    @State private var showAddSpotify = false

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                ForEach(model.visibleSpotify) { pl in
                    PlaylistToggle(pl: pl)
                        .contextMenu {
                            Button("Apri in Spotify") {
                                if let u = pl.spotifyURL.flatMap(URL.init(string:)) {
                                    NSWorkspace.shared.open(u)
                                }
                            }
                            Button("Rimuovi dall'elenco", role: .destructive) {
                                model.removeSpotify(pl.id)
                            }
                        }
                }
                Button {
                    showAddSpotify = true
                } label: {
                    Label("Aggiungi link Spotify…", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(model.isRunning)
            } header: {
                Text("Spotify")
            }
            Section("Musica") {
                ForEach(model.visible) { PlaylistToggle(pl: $0) }
            }
        }
        .sheet(isPresented: $showAddSpotify) { AddSpotifySheet() }
        .overlay {
            if model.isLoading {
                ProgressView("Leggo le playlist da Music…")
            } else if model.playlists.isEmpty, model.error != nil {
                ContentUnavailableView("Playlist non lette", systemImage: "exclamationmark.triangle",
                                       description: Text("Vedi il messaggio a destra."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Toggle("Mostra smart e di sistema", isOn: $model.showAll)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
                Button {
                    Task { await model.loadPlaylists() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Ricarica le playlist")
                .disabled(model.isLoading || model.isRunning)
            }
            .padding(8)
            .background(.bar)
        }
    }
}

struct PlaylistToggle: View {
    @Environment(SyncModel.self) private var model
    let pl: Playlist

    var body: some View {
        Toggle(isOn: Binding(
            get: { model.selected.contains(pl.id) },
            set: { _ in model.toggle(pl.id) }
        )) {
            HStack {
                Text(pl.name).lineLimit(1)
                if !pl.isRegular {
                    Text(pl.smart ? "smart" : "sistema")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if pl.isSpotify, pl.count >= 100 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Spotify mostra solo i primi 100 brani di una playlist")
                }
                Text(pl.count >= 0 ? "\(pl.count)" : "–")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(model.isRunning)
    }
}

struct AddSpotifySheet: View {
    @Environment(SyncModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Aggiungi playlist Spotify").font(.headline)
            Text("In Spotify: tasto ··· sulla playlist > Condividi > Copia link alla playlist. "
                 + "Funziona solo con playlist pubbliche e legge al massimo i primi 100 brani.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://open.spotify.com/playlist/…", text: $link)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            if let err = model.spotifyError {
                Text(err).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if model.isAddingSpotify { ProgressView().controlSize(.small) }
                Spacer()
                Button("Annulla", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Aggiungi", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(link.isEmpty || model.isAddingSpotify)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { model.spotifyError = nil }
    }

    private func add() {
        Task {
            if await model.addSpotify(link) { dismiss() }
        }
    }
}

struct RunView: View {
    @Environment(SyncModel.self) private var model

    var body: some View {
        Group {
            if let error = model.error, model.runs.isEmpty {
                ContentUnavailableView {
                    Label("Errore", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error).textSelection(.enabled)
                } actions: {
                    Button("Riprova") { Task { await model.loadPlaylists() } }
                }
            } else if model.runs.isEmpty {
                ContentUnavailableView(
                    "Scegli le playlist",
                    systemImage: "music.note.list",
                    description: Text("Spunta le playlist a sinistra e premi Sincronizza.\n"
                                      + "Formato \(model.format.label), cartella "
                                      + "\(model.destDisplay). Si cambiano nelle Impostazioni (⌘,).")
                )
            } else {
                List {
                    ForEach(model.runs) { run in
                        Section {
                            ForEach(run.tracks) { TrackRowView(row: $0) }
                        } header: {
                            RunHeader(run: run)
                        }
                    }
                }
            }
        }
    }
}

struct RunHeader: View {
    @Environment(SyncModel.self) private var model
    let run: PlaylistRun

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(run.name).font(.headline)
                Spacer()
                if let folder = run.folder, !model.dryRun || FileManager.default.fileExists(atPath: folder) {
                    Button("Mostra nel Finder") { model.openDest(folder) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            if run.total > 0 {
                ProgressView(value: Double(run.completed), total: Double(run.total))
            }
            if let note = run.note {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
            if let summary = run.summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(run.failed ? .red : .secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }
}

struct TrackRowView: View {
    let row: TrackRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label)
                if let match = row.match {
                    Text(match).font(.caption).foregroundStyle(.secondary)
                }
                if let note = row.note, row.status != .done {
                    Text(note).font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder private var icon: some View {
        switch row.status {
        case .searching: ProgressView().controlSize(.small)
        case .present: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        case .local: Image(systemName: "internaldrive").foregroundStyle(.blue)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .dry: Image(systemName: "eye").foregroundStyle(.blue)
        case .notFound: Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}
