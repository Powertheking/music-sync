// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniele Mazzanti
import AppKit
import SwiftUI

/// Impostazioni (⌘,): cartella di destinazione, formato e qualità.
struct SettingsView: View {
    @Environment(SyncModel.self) private var model
    @Environment(Updater.self) private var updater

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Cartella") {
                LabeledContent("Salva in") {
                    HStack {
                        Text(model.destDisplay)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(model.destPath)
                        Button("Scegli…") { chooseFolder() }
                    }
                }
                Text("Ogni playlist diventa una sottocartella, i brani singoli vanno in "
                     + "Singoli. Va bene anche un disco esterno: se non è collegato l'app "
                     + "te lo dice prima di iniziare.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Ripristina Musica/YT-Sync") { model.dest = "~/Music/YT-Sync" }
                    .disabled(model.dest == "~/Music/YT-Sync")
            }

            Section("Formato") {
                Picker("Formato", selection: $model.format) {
                    ForEach(AudioFormat.allCases) { Text($0.label).tag($0) }
                }
                if model.format.hasQuality {
                    Picker("Qualità", selection: $model.quality) {
                        Text("128 kbps").tag("128")
                        Text("192 kbps").tag("192")
                        Text("256 kbps").tag("256")
                        Text("320 kbps").tag("320")
                        if model.format == .mp3 {
                            Text("VBR alta qualità (V0)").tag("0")
                        }
                    }
                }
                Text(formatNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Scelta del video") {
                LabeledContent("Margine sulla durata") {
                    HStack {
                        Text("± \(model.tolerance) secondi").monospacedDigit()
                        Stepper("", value: $model.tolerance, in: 2...20).labelsHidden()
                    }
                }
                Text(toleranceNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Ripristina ± \(SyncModel.defaultTolerance) secondi") {
                    model.tolerance = SyncModel.defaultTolerance
                }
                .disabled(model.tolerance == SyncModel.defaultTolerance)
            }

            Section("Informazioni") {
                LabeledContent("Versione") {
                    HStack {
                        Text(updater.currentVersion)
                        updateStatus
                        Button("Controlla aggiornamenti") {
                            Task { await updater.check(userInitiated: true) }
                        }
                        .disabled(updater.state == .checking)
                    }
                }
                HStack {
                    Button("Codice sorgente") { NSWorkspace.shared.open(Updater.repoURL) }
                    Button("Licenza") { openResource("LICENSE.txt") }
                    Button("Licenze di terze parti") {
                        openResource("Licenze di terze parti.txt")
                    }
                }
                Text("Music Sync è software libero (GNU GPL v3 o successiva): puoi usarlo, "
                     + "studiarlo, modificarlo e ridistribuirlo alle stesse condizioni.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Ti è utile?") {
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://ko-fi.com/powertheking")!)
                    } label: {
                        Label("Offrimi un caffè", systemImage: "cup.and.saucer.fill")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: model.format) { _, f in
            // V0 esiste solo per mp3
            if f == .m4a, model.quality == "0" { model.quality = "256" }
        }
    }

    @ViewBuilder private var updateStatus: some View {
        switch updater.state {
        case .checking: ProgressView().controlSize(.small)
        case .upToDate: Text("· aggiornata").foregroundStyle(.secondary)
        case .failed(let msg): Text("· \(msg)").foregroundStyle(.red).lineLimit(2)
        default:
            if let r = updater.available {
                Text("· disponibile la \(r.version)").foregroundStyle(Color.accentColor)
            }
        }
    }

    private func openResource(_ name: String) {
        let url = Bundle.main.resourceURL!.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(Updater.repoURL)
        }
    }

    private var toleranceNote: String {
        let base = "Un video viene scelto solo se dura quanto il brano in Musica o su Spotify, "
            + "con questo margine. "
        switch model.tolerance {
        case ..<5:
            return base + "Margine stretto: quasi solo versioni identiche all'originale, ma "
                + "più brani \"non trovati\" (molti video hanno qualche secondo di intro o "
                + "di silenzio in più)."
        case 5...8:
            return base + "Valore consigliato: scarta live, remix ed edit, accetta le piccole "
                + "differenze dei video ufficiali."
        default:
            return base + "Margine largo: trova più brani, ma aumenta il rischio di prendere "
                + "versioni sbagliate (radio edit, extended, live). Controlla con Solo anteprima."
        }
    }

    private var formatNote: String {
        let base = "L'audio di YouTube è già compresso (circa 130-160 kbps): "
        switch model.format {
        case .mp3, .m4a:
            return base + "oltre 192-256 kbps i file diventano più grandi senza suonare meglio. "
                + "Il formato cambia solo per i brani nuovi, quelli già scaricati restano come sono."
        case .flac, .wav, .aiff:
            return base + "\(model.format.label) non recupera qualità, utile solo se il tuo "
                + "software (DJ, DAW) vuole quel formato. File circa 10 volte più grandi di un MP3. "
                + "Il formato cambia solo per i brani nuovi."
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Usa questa cartella"
        panel.directoryURL = URL(fileURLWithPath: model.destPath)
        if panel.runModal() == .OK, let url = panel.url {
            model.dest = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}
