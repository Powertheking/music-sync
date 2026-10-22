import AppKit
import Foundation
import Observation

struct Playlist: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let count: Int
    let smart: Bool
    let special: String

    /// Playlist creata dall'utente: niente smart, cartelle o liste di sistema.
    /// Solo per le playlist Spotify (id "sp:...").
    var spotifyURL: String?
    /// Solo per le playlist importate da CSV di Exportify (id "csv:...").
    var csvPath: String?

    var isRegular: Bool { !smart && special == "none" }
    var isSpotify: Bool { spotifyURL != nil || csvPath != nil }
}

enum TrackStatus {
    case searching, present, local, done, dry, failed, notFound

    var isFinal: Bool { self != .searching }
}

struct TrackRow: Identifiable {
    let id: Int
    var label: String
    var status: TrackStatus
    var match: String?
    var note: String?
}

struct PlaylistRun: Identifiable {
    let id: String
    let name: String
    var total = 0
    var folder: String?
    var tracks: [TrackRow] = []
    var summary: String?
    var note: String?
    var failed = false

    var completed: Int { tracks.filter { $0.status.isFinal }.count }
}

struct SearchResult: Identifiable, Decodable {
    let id: String
    let title: String
    let channel: String
    let duration: Int?
    let thumbnail: String?

    var durationText: String {
        guard let d = duration else { return "–" }
        return String(format: "%d:%02d", d / 60, d % 60)
    }
}

struct ScriptError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

enum AudioFormat: String, CaseIterable, Identifiable {
    case mp3, m4a, flac, wav, aiff
    var id: String { rawValue }

    var label: String {
        switch self {
        case .mp3: "MP3"
        case .m4a: "AAC (.m4a)"
        case .flac: "FLAC"
        case .wav: "WAV"
        case .aiff: "AIFF"
        }
    }

    /// mp3 e m4a hanno un bitrate da scegliere, gli altri sono senza perdita.
    var hasQuality: Bool { self == .mp3 || self == .m4a }
}

enum DownloadState {
    case downloading
    case done(file: String)
    case failed(String)
}

@MainActor
@Observable
final class SyncModel {
    static let browsers = ["", "safari", "chrome", "firefox"]

    var playlists: [Playlist] = []
    var filter = ""
    var showAll = false
    var dryRun = false
    var selected: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "selected") ?? []) {
        didSet { UserDefaults.standard.set(Array(selected), forKey: "selected") }
    }
    var cookies: String = UserDefaults.standard.string(forKey: "cookies") ?? "safari" {
        didSet { UserDefaults.standard.set(cookies, forKey: "cookies") }
    }

    var isLoading = false
    var isRunning = false
    var runs: [PlaylistRun] = []
    var error: String?

    // ricerca di un singolo brano
    var query = ""
    var results: [SearchResult] = []
    var isSearching = false
    var searchError: String?
    var downloads: [String: DownloadState] = [:]

    // impostazioni (finestra Impostazioni, ⌘,)
    var dest: String = UserDefaults.standard.string(forKey: "dest") ?? "~/Music/YT-Sync" {
        didSet { UserDefaults.standard.set(dest, forKey: "dest") }
    }
    var format: AudioFormat = AudioFormat(
        rawValue: UserDefaults.standard.string(forKey: "format") ?? "") ?? .mp3 {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: "format") }
    }
    var quality: String = UserDefaults.standard.string(forKey: "quality") ?? "192" {
        didSet { UserDefaults.standard.set(quality, forKey: "quality") }
    }

    var destPath: String { (dest as NSString).expandingTildeInPath }
    /// Percorso breve da mostrare: ~/... per la home, nome del volume per i dischi esterni.
    var destDisplay: String { (destPath as NSString).abbreviatingWithTildeInPath }

    private var audioArgs: [String] {
        var a = ["--format", format.rawValue]
        if format.hasQuality { a += ["--quality", quality] }
        return a
    }

    /// nil se la cartella è utilizzabile, altrimenti il motivo.
    func destProblem() -> String? {
        let comps = URL(fileURLWithPath: destPath).pathComponents
        if comps.count > 2, comps[1] == "Volumes",
           !FileManager.default.fileExists(atPath: "/Volumes/" + comps[2]) {
            return "Il disco \"\(comps[2])\" non è collegato. Collegalo oppure scegli "
                + "un'altra cartella nelle Impostazioni."
        }
        do {
            try FileManager.default.createDirectory(atPath: destPath,
                                                    withIntermediateDirectories: true)
        } catch {
            return "Non posso scrivere in \(destDisplay): \(error.localizedDescription)"
        }
        return nil
    }
    private let python: String
    private let script: String
    /// Cartella con ffmpeg/ffprobe/deno inclusi nell'app (solo build autonoma).
    private let binDir: String?
    private var process: Process?
    private var cancelled = false

    init() {
        let res = Bundle.main.resourcePath ?? ""
        let bundled = res + "/python/bin/python3"
        if FileManager.default.isExecutableFile(atPath: bundled) {
            python = bundled
            binDir = res + "/bin"
        } else {
            python = Bundle.main.object(forInfoDictionaryKey: "MSPythonPath") as? String
                ?? "/usr/bin/python3"
            binDir = nil
        }
        script = Bundle.main.path(forResource: "music_sync", ofType: "py") ?? "music_sync.py"
    }

    var visible: [Playlist] {
        playlists.filter {
            (showAll || $0.isRegular)
                && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter))
        }
    }

    var selectedPlaylists: [Playlist] {
        (spotify + playlists).filter { selected.contains($0.id) }
    }

    // MARK: - Spotify (playlist pubbliche aggiunte per link)

    var spotify: [Playlist] = SyncModel.loadSpotify() {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(spotify), forKey: "spotify")
        }
    }
    var spotifyError: String?
    var isAddingSpotify = false

    private static func loadSpotify() -> [Playlist] {
        guard let data = UserDefaults.standard.data(forKey: "spotify") else { return [] }
        return (try? JSONDecoder().decode([Playlist].self, from: data)) ?? []
    }

    var visibleSpotify: [Playlist] {
        spotify.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
    }

    /// Legge nome e numero brani dal link; true se aggiunta.
    func addSpotify(_ link: String) async -> Bool {
        isAddingSpotify = true
        spotifyError = nil
        defer { isAddingSpotify = false }
        switch await runToEnd(["spotify-info", link.trimmingCharacters(in: .whitespaces)]) {
        case .failure(let e):
            spotifyError = e.message
            return false
        case .success(let data):
            guard let pl = try? JSONDecoder().decode(Playlist.self, from: data) else {
                spotifyError = "Risposta non valida dallo script."
                return false
            }
            spotify.removeAll { $0.id == pl.id }
            spotify.append(pl)
            selected.insert(pl.id)
            return true
        }
    }

    func removeSpotify(_ id: String) {
        if let csv = spotify.first(where: { $0.id == id })?.csvPath {
            try? FileManager.default.removeItem(atPath: csv)
        }
        spotify.removeAll { $0.id == id }
        selected.remove(id)
    }

    /// Dove l'app tiene una copia dei CSV importati (i Download si possono svuotare).
    private var csvStore: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Music Sync/Spotify", isDirectory: true)
    }

    /// Importa un CSV di Exportify, o uno zip di "Export All". Restituisce le playlist
    /// aggiunte; un file che non è un export di Exportify dà errore.
    func importSpotifyFile(_ url: URL) async -> Result<[Playlist], ScriptError> {
        let fm = FileManager.default
        var csvs: [URL] = []
        if url.pathExtension.lowercased() == "zip" {
            let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? fm.removeItem(at: tmp) }
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", url.path, tmp.path]
            do {
                try unzip.run()
                unzip.waitUntilExit()
            } catch {
                return .failure(ScriptError("Non riesco ad aprire lo zip."))
            }
            let found = fm.enumerator(at: tmp, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension.lowercased() == "csv"
                    && !$0.path.contains("__MACOSX") } ?? []
            // copio subito: la cartella temporanea sparisce all'uscita
            for f in found { csvs += (try? storeCSV(f)).map { [$0] } ?? [] }
        } else {
            do {
                csvs = [try storeCSV(url)]
            } catch {
                return .failure(ScriptError("Non riesco a copiare il file: "
                                            + error.localizedDescription))
            }
        }
        guard !csvs.isEmpty else {
            return .failure(ScriptError("Nello zip non ci sono file CSV."))
        }

        var added: [Playlist] = []
        var lastError: ScriptError?
        for csv in csvs {
            switch await runToEnd(["csv-info", csv.path]) {
            case .failure(let e):
                try? fm.removeItem(at: csv)
                lastError = e
            case .success(let data):
                guard let pl = try? JSONDecoder().decode(Playlist.self, from: data) else { continue }
                spotify.removeAll { $0.id == pl.id }
                spotify.append(pl)
                selected.insert(pl.id)
                added.append(pl)
            }
        }
        if added.isEmpty, let lastError { return .failure(lastError) }
        return .success(added)
    }

    private func storeCSV(_ src: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: csvStore, withIntermediateDirectories: true)
        let dst = csvStore.appendingPathComponent(src.lastPathComponent)
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.copyItem(at: src, to: dst)
        return dst
    }

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    // MARK: - Processo Python

    private func makeProcess(_ args: [String]) -> (Process, Pipe, Pipe) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-u", script] + args
        var env = ProcessInfo.processInfo.environment
        // lanciata dal Finder l'app non ha Homebrew nel PATH (ffmpeg, deno)
        let brew = "/opt/homebrew/bin:/usr/local/bin:"
        env["PATH"] = (binDir.map { $0 + ":" } ?? brew) + (env["PATH"] ?? "/usr/bin:/bin")
        env["PYTHONIOENCODING"] = "utf-8"
        // non scrivere .pyc dentro l'app firmata
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONNOUSERSITE"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        return (p, out, err)
    }

    private static func readAll(_ pipe: Pipe) -> Task<Data, Never> {
        Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }
    }

    private static func tail(_ data: Data, lines: Int = 4) -> String {
        let all = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .filter { !$0.hasPrefix("WARNING") && !$0.hasPrefix("[debug]") }
        // di un traceback Python basta l'ultima riga con l'errore
        if let last = all.last(where: { $0.contains("Error") || $0.hasPrefix("ERROR") }) {
            return last.replacingOccurrences(
                of: #"^[\w.]*(Error|Exception): (ERROR: )?"#, with: "",
                options: .regularExpression)
        }
        return all.suffix(lines).joined(separator: "\n")
    }

    /// Esegue lo script fino alla fine; restituisce stdout oppure il messaggio d'errore.
    private func runToEnd(_ args: [String]) async -> Result<Data, ScriptError> {
        let (p, out, err) = makeProcess(args)
        do {
            try p.run()
        } catch {
            return .failure(ScriptError(
                "Impossibile avviare Python (\(python)): \(error.localizedDescription)"))
        }
        let outTask = Self.readAll(out), errTask = Self.readAll(err)
        let data = await outTask.value
        let errData = await errTask.value
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            // con --json l'errore arriva come evento su stdout
            let jsonErr = String(decoding: data, as: UTF8.self).split(separator: "\n")
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .last { $0["ev"] as? String == "error" }?["msg"] as? String
            return .failure(ScriptError(jsonErr ?? Self.tail(errData)))
        }
        return .success(data)
    }

    func loadPlaylists() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        switch await runToEnd(["list", "--json"]) {
        case .failure(let e):
            error = e.message
        case .success(let data):
            do {
                playlists = try JSONDecoder().decode([Playlist].self, from: data)
                // scarta selezioni di playlist che non esistono più
                selected = selected.intersection(playlists.map(\.id) + spotify.map(\.id))
            } catch {
                self.error = "Risposta non valida dallo script: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Singolo brano

    func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        isSearching = true
        searchError = nil
        defer { isSearching = false }
        // la ricerca non ha bisogno del login: i cookie servono solo per scaricare
        switch await runToEnd(["search", q, "-n", "12", "--json"]) {
        case .failure(let e):
            searchError = e.message
        case .success(let data):
            results = (try? JSONDecoder().decode([SearchResult].self, from: data)) ?? []
            if results.isEmpty { searchError = "Nessun risultato." }
        }
    }

    func download(_ r: SearchResult) async {
        if let problem = destProblem() {
            downloads[r.id] = .failed(problem)
            return
        }
        downloads[r.id] = .downloading
        var args = ["get", r.id, "--dest", destPath, "--yt-title", r.title,
                    "--channel", r.channel, "--json"] + audioArgs
        if !cookies.isEmpty { args += ["--cookies-from-browser", cookies] }
        switch await runToEnd(args) {
        case .failure(let e):
            downloads[r.id] = .failed(e.message)
        case .success(let data):
            let file = String(decoding: data, as: UTF8.self).split(separator: "\n")
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .last { $0["ev"] as? String == "done" }?["file"] as? String
            downloads[r.id] = .done(file: file ?? "")
        }
    }

    func reveal(_ file: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)])
    }

    func sync() async {
        let todo = selectedPlaylists
        guard !todo.isEmpty else { return }
        runs = []
        if !dryRun, let problem = destProblem() {
            error = problem
            return
        }
        isRunning = true
        cancelled = false
        error = nil
        defer {
            isRunning = false
            process = nil
        }

        for pl in todo {
            if cancelled { break }
            runs.append(PlaylistRun(id: pl.id, name: pl.name))
            let idx = runs.count - 1

            var args = pl.csvPath.map { ["sync", "--csv", $0, "--name", pl.name] }
                ?? pl.spotifyURL.map { ["sync", "--spotify", $0] }
                ?? ["sync", "--id", pl.id]
            args += ["--dest", destPath, "--json"] + audioArgs
            if dryRun { args.append("--dry-run") }
            if !cookies.isEmpty { args += ["--cookies-from-browser", cookies] }

            let (p, out, err) = makeProcess(args)
            process = p
            do {
                try p.run()
            } catch {
                self.error = "Impossibile avviare Python: \(error.localizedDescription)"
                break
            }
            let errTask = Self.readAll(err)
            do {
                for try await line in out.fileHandleForReading.bytes.lines {
                    handle(line, run: idx)
                }
            } catch {}
            let errData = await errTask.value
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                runs[idx].failed = true
                runs[idx].summary = cancelled ? "Interrotta" : Self.tail(errData)
                // il brano in corso non finirà più: niente rotellina che gira per sempre
                for r in runs[idx].tracks.indices where runs[idx].tracks[r].status == .searching {
                    runs[idx].tracks[r].status = .failed
                    runs[idx].tracks[r].note = cancelled ? "Interrotto" : nil
                }
            }
        }
    }

    func cancel() {
        cancelled = true
        process?.terminate()
    }

    func openDest(_ folder: String? = nil) {
        let path = folder ?? destPath
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: - Eventi JSON dello script

    private func handle(_ line: String, run idx: Int) {
        guard let data = line.data(using: .utf8),
              let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = ev["ev"] as? String
        else { return }
        let msg = (ev["msg"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let i = ev["i"] as? Int

        switch kind {
        case "start":
            runs[idx].total = ev["total"] as? Int ?? 0
            runs[idx].folder = ev["folder"] as? String
        case "track":
            guard let i else { return }
            let label = ev["label"] as? String ?? msg
            let status: TrackStatus = switch ev["status"] as? String {
            case "present": .present
            case "local": .local
            default: .searching
            }
            upsert(idx, i) { $0.label = label; $0.status = status }
        case "match":
            guard let i else { return }
            let title = ev["title"] as? String ?? "?"
            let channel = ev["channel"] as? String ?? "?"
            let yt = ev["yt_duration"] as? Int ?? 0
            let dur = ev["duration"] as? Int ?? 0
            upsert(idx, i) { $0.match = "\(title) · \(channel) · \(yt)s / \(dur)s" }
        case "result":
            guard let i else { return }
            let status: TrackStatus = switch ev["status"] as? String {
            case "done": .done
            case "dry": .dry
            case "notfound": .notFound
            default: .failed
            }
            upsert(idx, i) { $0.status = status }
        case "warn":
            if let i {
                upsert(idx, i) { $0.note = msg }
            } else {
                runs[idx].note = msg
            }
        case "end":
            runs[idx].summary = msg.replacingOccurrences(of: "--- ", with: "")
        default:
            break
        }
    }

    private func upsert(_ idx: Int, _ i: Int, _ change: (inout TrackRow) -> Void) {
        if let r = runs[idx].tracks.firstIndex(where: { $0.id == i }) {
            change(&runs[idx].tracks[r])
        } else {
            var row = TrackRow(id: i, label: "", status: .searching)
            change(&row)
            runs[idx].tracks.append(row)
        }
    }
}
