// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniele Mazzanti
import SwiftUI

/// Cerca un brano su YouTube e scaricalo in <dest>/Singoli nel formato scelto.
struct SearchTab: View {
    @Environment(SyncModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                TextField("Artista e titolo, es. Luciid Charm", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { Task { await model.search() } }
                Button("Cerca") { Task { await model.search() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.query.trimmingCharacters(in: .whitespaces).isEmpty
                              || model.isSearching)
                Button {
                    model.openDest(model.destPath + "/Singoli")
                } label: {
                    Image(systemName: "folder")
                }
                .help("Apri la cartella Singoli")
            }
            .padding(12)
            Divider()

            Group {
                if model.isSearching {
                    ProgressView("Cerco su YouTube…").frame(maxHeight: .infinity)
                } else if let err = model.searchError {
                    ContentUnavailableView("Niente da mostrare", systemImage: "magnifyingglass",
                                           description: Text(err))
                } else if model.results.isEmpty {
                    ContentUnavailableView(
                        "Cerca un brano",
                        systemImage: "music.note",
                        description: Text("I file (\(model.format.label)) finiscono in "
                                          + "\(model.destDisplay)/Singoli, con artista e "
                                          + "titolo ricavati dal video.")
                    )
                } else {
                    List(model.results) { ResultRow(result: $0) }
                }
            }
        }
        // senza, con la lista vuota il campo di ricerca finisce a metà finestra
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { focused = true }
    }
}

struct ResultRow: View {
    @Environment(SyncModel.self) private var model
    let result: SearchResult

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: result.thumbnail.flatMap(URL.init(string:))) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.secondary.opacity(0.15)
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(result.title).lineLimit(2)
                Text("\(result.channel) · \(result.durationText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .failed(let msg) = model.downloads[result.id] {
                    Text(msg).font(.caption).foregroundStyle(.red).lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            action
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var action: some View {
        switch model.downloads[result.id] {
        case .downloading:
            ProgressView().controlSize(.small).frame(width: 90)
        case .done(let file):
            Button {
                model.reveal(file)
            } label: {
                Label("Mostra", systemImage: "checkmark.circle.fill")
            }
            .tint(.green)
            .frame(width: 90)
        case .failed:
            Button("Riprova") { Task { await model.download(result) } }
                .frame(width: 90)
        case nil:
            Button {
                Task { await model.download(result) }
            } label: {
                Label("Scarica", systemImage: "arrow.down.circle")
            }
            .frame(width: 90)
        }
    }
}
