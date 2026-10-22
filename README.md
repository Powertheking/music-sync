# Music Sync

App macOS che sincronizza le playlist di Musica (Apple Music) e le playlist
pubbliche di Spotify in cartelle di file audio scaricati da YouTube, scartando i
match sbagliati (live, cover, remix) con un controllo sulla durata. Permette anche di cercare e scaricare un singolo brano.

> Uso personale. Scaricare da YouTube può violare i termini di servizio di YouTube.

## Com'è fatta

- `music_sync.py` — il motore: legge le playlist via JXA (`osascript`), cerca su
  YouTube con yt-dlp, converte (mp3, m4a, flac, wav, aiff) con ffmpeg e scrive i
  tag con mutagen.
  Funziona anche da solo da terminale.
- `MusicSyncApp/` — l'app SwiftUI (Swift Package) che lancia lo script e ne legge
  gli eventi JSON.
- `build_app.sh` — compila `build/Music Sync.app` e, con `--standalone`, il DMG
  da condividere.
- `dist/` — Leggimi e impostazioni del DMG.

## Uso da terminale

```bash
brew install ffmpeg deno python@3.13
python3.13 -m venv .venv && .venv/bin/pip install "yt-dlp[default]" mutagen

.venv/bin/python music_sync.py list
.venv/bin/python music_sync.py sync "Nome Playlist" --dry-run
.venv/bin/python music_sync.py sync "Nome Playlist" --cookies-from-browser safari
.venv/bin/python music_sync.py sync --spotify "https://open.spotify.com/playlist/..."
.venv/bin/python music_sync.py sync --csv ~/Downloads/estate_2026.csv
.venv/bin/python music_sync.py sync "Nome Playlist" --format flac --dest /Volumes/Disco/Musica
.venv/bin/python music_sync.py search "luciid charm"
.venv/bin/python music_sync.py get <video_id> --format mp3 --quality 320
```

Formati: `mp3` (con `--quality` 128-320 o `0` = VBR V0), `m4a`, `flac`, `wav`,
`aiff`.

Playlist Spotify, in due modi e senza account developer:

- `--csv`: file esportato con [Exportify](https://exportify.app), anche per playlist
  private e senza limite di brani. Nell'app c'è una procedura guidata che
  apre Exportify e prende da sola il file dalla cartella Download.
- `--spotify`: link a una playlist pubblica, letto dalla pagina embed
  (massimo 100 brani).

I file vanno in `~/Music/YT-Sync/<Playlist>/` (o in `--dest`) (più `Singoli/` per i brani
scaricati a mano), con la playlist `.m3u8` e lo stato `.sync_state.json`:
risincronizzando si scaricano solo i brani nuovi.

## Build dell'app

Serve Xcode (o i Command Line Tools con Swift 5.10+).

```bash
./build_app.sh               # app per questo Mac, usa .venv e Homebrew
./build_app.sh --standalone  # app autonoma + build/Music Sync.dmg
```

La build autonoma richiede `brew install lame mpg123 deno` e include nell'app:

- Python 3.13 portatile ([python-build-standalone](https://github.com/astral-sh/python-build-standalone)) con yt-dlp, yt-dlp-ejs e mutagen;
- ffmpeg/ffprobe minimi compilati dal sorgente di ffmpeg.org, con lame statico;
- deno, per risolvere le challenge JavaScript di YouTube.

Risultato: Mac Apple Silicon con macOS 14 o successivo. L'app è firmata solo
ad hoc, quindi al primo avvio va aperta con *Impostazioni di Sistema > Privacy e
sicurezza > Apri comunque* (vedi `dist/Leggimi.txt`).
