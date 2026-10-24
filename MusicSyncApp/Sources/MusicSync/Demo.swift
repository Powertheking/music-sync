// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniele Mazzanti
import Foundation

/// Modalità dimostrativa per gli screenshot del sito: avviando l'app con `--demo`
/// mostra playlist e brani inventati, senza leggere Musica e senza salvare nulla.
///
///     open -n "Music Sync.app" --args --demo
extension SyncModel {
    static let isDemo = CommandLine.arguments.contains("--demo")

    func loadDemo() {
        func pl(_ id: String, _ name: String, _ count: Int, spotify: Bool = false) -> Playlist {
            Playlist(id: id, name: name, count: count, smart: false, special: "none",
                     spotifyURL: spotify ? "https://open.spotify.com/playlist/\(id)" : nil)
        }
        spotify = [
            pl("sp1", "Road trip estate", 48, spotify: true),
            pl("sp2", "Indie da scoprire", 72, spotify: true),
        ]
        playlists = [
            pl("m01", "Aperitivo in terrazza", 34),
            pl("m02", "Anni '80", 112),
            pl("m03", "Anni '90", 96),
            pl("m04", "Chill della domenica", 41),
            pl("m05", "Corsa al parco", 27),
            pl("m06", "Dance classics", 150),
            pl("m07", "Deep house", 63),
            pl("m08", "Festa di compleanno", 58),
            pl("m09", "Jazz della sera", 22),
            pl("m10", "Lo-fi per studiare", 85),
            pl("m11", "Matrimonio – ingresso", 6),
            pl("m12", "Rock italiano", 77),
            pl("m13", "Serata disco", 44),
            pl("m14", "Viaggio in treno", 31),
        ]
        selected = ["sp1", "m02", "m07"]

        let tracks: [(String, TrackStatus, String?)] = [
            ("Neon Avenue - Midnight Drive", .done, "Neon Avenue - Midnight Drive (Official Audio) · Neon Avenue - Topic · 214s / 213s"),
            ("Marta Sole - Vento caldo", .done, "Marta Sole - Vento caldo · Marta Sole - Topic · 187s / 187s"),
            ("I Sentieri - Via del mare", .done, "I Sentieri - Via del mare (Official Video) · I Sentieri · 241s / 240s"),
            ("Luna Park - Estate infinita", .present, nil),
            ("The Harbour Lights - Golden Hour", .present, nil),
            ("Kite Season - Open Roads", .done, "Kite Season - Open Roads | Official Audio · Kite Season · 198s / 198s"),
            ("Selva - Notte di luglio", .done, "Selva - Notte di luglio (Audio) · Selva - Topic · 226s / 225s"),
        ]
        var run = PlaylistRun(id: "sp1", name: "Road trip estate")
        run.total = tracks.count
        run.summary = "Road trip estate: nuovi 5, già presenti 2, falliti 0, rimossi 0"
        run.folder = destPath + "/Road trip estate (Spotify)"
        run.tracks = tracks.enumerated().map { i, t in
            TrackRow(id: i + 1, label: t.0, status: t.1, match: t.2)
        }
        runs = [run]
    }
}
