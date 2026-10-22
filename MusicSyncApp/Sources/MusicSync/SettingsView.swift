import AppKit
import SwiftUI

/// Impostazioni (⌘,): cartella di destinazione, formato e qualità.
struct SettingsView: View {
    @Environment(SyncModel.self) private var model

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
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: model.format) { _, f in
            // V0 esiste solo per mp3
            if f == .m4a, model.quality == "0" { model.quality = "256" }
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
