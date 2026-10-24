// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniele Mazzanti
import AppKit
import Foundation
import Observation
import Security
import SwiftUI

/// Aggiornamenti dalle release GitHub: controlla l'ultima versione, scarica il DMG,
/// verifica che sia firmato come l'app in uso, sostituisce l'app e la riapre.
@MainActor
@Observable
final class Updater {
    static let repo = "Powertheking/music-sync"
    static var repoURL: URL { URL(string: "https://github.com/\(repo)")! }

    struct Release {
        let version: String
        let notes: String
        let dmgURL: URL
        let pageURL: URL
    }

    enum State: Equatable {
        case idle, checking, downloading, installing
        case upToDate
        case failed(String)
    }

    var available: Release?
    var state: State = .idle

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - Controllo

    /// Controlla a ogni avvio: il limite dell'API GitHub (60 richieste l'ora) è per
    /// indirizzo IP di chi usa l'app, quindi una richiesta ad avvio è irrilevante.
    /// Gli errori si mostrano solo se il controllo l'ha chiesto l'utente.
    func check(userInitiated: Bool = false) async {
        state = .checking

        var req = URLRequest(url: URL(string:
            "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                state = userInitiated ? .failed("Nessuna versione pubblicata trovata.") : .idle
                return
            }
            let r = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let version = r.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            guard let dmg = r.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }),
                  let dmgURL = URL(string: dmg.browser_download_url),
                  let page = URL(string: r.html_url) else {
                state = .idle
                return
            }
            if Self.isNewer(version, than: currentVersion) {
                available = Release(version: version, notes: r.body ?? "", dmgURL: dmgURL,
                                    pageURL: page)
                state = .idle
            } else {
                available = nil
                state = userInitiated ? .upToDate : .idle
            }
        } catch {
            state = userInitiated ? .failed("Controllo non riuscito: \(error.localizedDescription)")
                                  : .idle
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Installazione

    func install() async {
        guard let release = available else { return }
        state = .downloading
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("MusicSyncUpdate-\(UUID().uuidString)")
        let mount = work.appendingPathComponent("mnt")
        do {
            try fm.createDirectory(at: mount, withIntermediateDirectories: true)
            let (tmp, resp) = try await URLSession.shared.download(from: release.dmgURL)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError("download non riuscito")
            }
            let dmg = work.appendingPathComponent("update.dmg")
            try fm.moveItem(at: tmp, to: dmg)

            state = .installing
            try await run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify",
                                               "-mountpoint", mount.path, dmg.path])
            guard let newApp = try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else {
                throw UpdateError("nel DMG non c'è l'app")
            }

            let current = Bundle.main.bundleURL
            let parent = current.deletingLastPathComponent()
            guard fm.isWritableFile(atPath: parent.path) else {
                throw UpdateError("non posso scrivere in \(parent.path)")
            }
            let staged = parent.appendingPathComponent(".Music Sync aggiornamento.app")
            try? fm.removeItem(at: staged)
            try await run("/usr/bin/ditto", [newApp.path, staged.path])
            try? await run("/usr/bin/hdiutil", ["detach", "-force", mount.path])
            try Self.verifySameSigner(staged)

            // uno script aspetta che l'app si chiuda, scambia le cartelle e la riapre
            let script = work.appendingPathComponent("swap.sh")
            try """
            #!/bin/sh
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
            rm -rf "\(current.path)" && mv "\(staged.path)" "\(current.path)"
            xattr -dr com.apple.quarantine "\(current.path)" 2>/dev/null
            open "\(current.path)"
            rm -rf "\(work.path)"
            """.write(to: script, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [script.path]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            try? await run("/usr/bin/hdiutil", ["detach", "-force", mount.path])
            try? fm.removeItem(at: work)
            try? fm.removeItem(at: Bundle.main.bundleURL.deletingLastPathComponent()
                .appendingPathComponent(".Music Sync aggiornamento.app"))
            state = .failed("Aggiornamento non riuscito: "
                            + ((error as? UpdateError)?.message ?? error.localizedDescription)
                            + ". Puoi scaricarlo a mano dalla pagina della versione.")
        }
    }

    /// L'aggiornamento deve soddisfare il "designated requirement" dell'app in uso:
    /// stesso identificativo e stesso certificato di firma.
    private static func verifySameSigner(_ app: URL) throws {
        var selfCode: SecCode?
        var req: SecRequirement?
        var newCode: SecStaticCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyDesignatedRequirement(selfCode as! SecStaticCode, [], &req)
                == errSecSuccess,
              SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess,
              let newCode
        else { throw UpdateError("impossibile verificare la firma") }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode
                               | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(newCode, flags, req) == errSecSuccess else {
            throw UpdateError("la nuova versione non è firmata come quella installata")
        }
    }

    private func run(_ tool: String, _ args: [String]) async throws {
        try await Self.runDetached(tool, args)
    }

    nonisolated private static func runDetached(_ tool: String, _ args: [String]) async throws {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                throw UpdateError("\((tool as NSString).lastPathComponent) non riuscito")
            }
        }.value
    }
}

private struct UpdateError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: String
    }
    let tag_name: String
    let body: String?
    let html_url: String
    let assets: [Asset]
}

// MARK: - Interfaccia

/// Barra in cima alla finestra quando c'è una versione nuova.
struct UpdateBanner: View {
    @Environment(Updater.self) private var updater
    @Environment(SyncModel.self) private var model
    @State private var showNotes = false

    var body: some View {
        if let r = updater.available {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("È disponibile Music Sync \(r.version)").font(.headline)
                    if case .failed(let msg) = updater.state {
                        Text(msg).font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Hai la versione \(updater.currentVersion). L'app si riapre da sola.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !r.notes.isEmpty {
                    Button("Novità") { showNotes = true }
                        .popover(isPresented: $showNotes) {
                            ScrollView {
                                Text(r.notes).textSelection(.enabled).padding()
                            }
                            .frame(width: 360, height: 240)
                        }
                }
                switch updater.state {
                case .downloading, .installing:
                    ProgressView().controlSize(.small)
                    Text(updater.state == .downloading ? "Scarico…" : "Installo…")
                        .foregroundStyle(.secondary)
                case .failed:
                    Button("Apri la pagina") { NSWorkspace.shared.open(r.pageURL) }
                default:
                    Button("Aggiorna") { Task { await updater.install() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isRunning)
                        .help(model.isRunning ? "Aspetta che finisca la sincronizzazione" : "")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}
