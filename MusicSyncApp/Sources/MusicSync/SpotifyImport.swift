// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniele Mazzanti
import AppKit
import SwiftUI

/// Procedura guidata per portare una playlist Spotify (anche privata) nell'app:
/// l'utente la esporta con Exportify e l'app trova da sola il file nei Download.
struct SpotifyImportSheet: View {
    @Environment(SyncModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    static let exportifyURL = URL(string: "https://exportify.app")!

    @State private var openedAt = Date()
    @State private var seen: Set<String> = []
    @State private var added: [Playlist] = []
    @State private var importError: String?
    @State private var isImporting = false
    @State private var dropTargeted = false
    @State private var showLink = false
    @State private var link = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Aggiungi playlist da Spotify").font(.title2.bold())

            step(1, "Apri Exportify e accedi con il tuo account Spotify, come fai di solito.") {
                Button {
                    NSWorkspace.shared.open(Self.exportifyURL)
                } label: {
                    Label("Apri Exportify", systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            step(2, "Premi «Export» accanto alla playlist che vuoi, oppure «Export All» "
                 + "per averle tutte. Il browser scarica un file: non serve aprirlo.") {
                EmptyView()
            }

            step(3, "Fatto! Music Sync trova da solo il file nella cartella Download.") {
                status
            }

            dropZone

            Text("Stai solo esportando l'elenco dei brani delle tue playlist, come una lista "
                 + "della spesa. Music Sync non accede al tuo account Spotify.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup("Hai il link di una playlist pubblica?", isExpanded: $showLink) {
                HStack {
                    TextField("https://open.spotify.com/playlist/…", text: $link)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addLink)
                    Button("Aggiungi", action: addLink)
                        .disabled(link.isEmpty || model.isAddingSpotify)
                }
                .padding(.top, 6)
                Text("Senza Exportify, ma solo playlist pubbliche e al massimo 100 brani.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            HStack {
                Spacer()
                Button(added.isEmpty ? "Annulla" : "Fine") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
        .task { await watchDownloads() }
    }

    // MARK: - Pezzi della finestra

    private func step<Content: View>(_ n: Int, _ text: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 8) {
                Text(text).fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }

    @ViewBuilder private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(added) { pl in
                Label("\(pl.name) · \(pl.count) brani", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if isImporting {
                HStack { ProgressView().controlSize(.small); Text("Importo…") }
            } else if let importError {
                Text(importError).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(added.isEmpty ? "Aspetto il file nei Download…"
                                       : "Puoi esportarne altre, le aggiungo qui.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var dropZone: some View {
        HStack {
            Image(systemName: "arrow.down.doc")
            Text("Il file è altrove? Trascinalo qui oppure")
            Button("scegli il file…", action: chooseFile).buttonStyle(.link)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
        )
        .dropDestination(for: URL.self) { urls, _ in
            Task { for u in urls { await importFile(u, explicit: true) } }
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
    }

    // MARK: - Azioni

    /// Controlla la cartella Download finché la finestra è aperta: ogni CSV o zip
    /// arrivato dopo l'apertura viene provato; quelli che non sono di Exportify si ignorano.
    private func watchDownloads() async {
        openedAt = Date().addingTimeInterval(-5)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        while !Task.isCancelled {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: downloads, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in files {
                let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                guard date > openedAt, !seen.contains(f.path) else { continue }
                if ["csv", "zip"].contains(f.pathExtension.lowercased()) {
                    seen.insert(f.path)
                    await importFile(f, explicit: false)
                } else if f.hasDirectoryPath {
                    // Safari scompatta da solo lo zip di "Export All" in una cartella
                    let inside = (try? FileManager.default.contentsOfDirectory(
                        at: f, includingPropertiesForKeys: nil)) ?? []
                    let csvs = inside.filter { $0.pathExtension.lowercased() == "csv" }
                    guard !csvs.isEmpty else { continue }  // forse ancora in scompattamento
                    seen.insert(f.path)
                    for c in csvs { await importFile(c, explicit: false) }
                }
            }
            try? await Task.sleep(for: .seconds(1.5))
        }
    }

    private func importFile(_ url: URL, explicit: Bool) async {
        isImporting = true
        defer { isImporting = false }
        switch await model.importSpotifyFile(url) {
        case .success(let pls):
            importError = nil
            added.removeAll { pl in pls.contains { $0.id == pl.id } }
            added += pls
        case .failure(let e):
            // un CSV qualsiasi scaricato nel frattempo non è un errore da mostrare
            if explicit { importError = e.message }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .zip]
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory,
                                                      in: .userDomainMask).first
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { for u in urls { await importFile(u, explicit: true) } }
        }
    }

    private func addLink() {
        Task {
            if await model.addSpotify(link) {
                if let pl = model.spotify.last { added.append(pl) }
                link = ""
                importError = nil
            } else {
                importError = model.spotifyError
            }
        }
    }
}
