#!/usr/bin/env python3
"""
music_sync.py - sincronizza playlist di Music.app (macOS) con cartelle locali di file audio
scaricati da YouTube, con controllo sulla durata per evitare live/cover sbagliati.

Setup:
    brew install ffmpeg deno python@3.13
    python3.13 -m venv .venv && .venv/bin/pip install "yt-dlp[default]" mutagen

Uso:
    python3 music_sync.py list
    python3 music_sync.py sync "Nome Playlist" --dest ~/Music/YT-Sync --dry-run
    python3 music_sync.py sync "Nome Playlist" --dest ~/Music/YT-Sync
    python3 music_sync.py sync --all --dest ~/Music/YT-Sync --prune
    python3 music_sync.py sync "Nome Playlist" --cookies-from-browser chrome

Ogni playlist diventa una cartella in dest/, con:
    .sync_state.json   stato (persistentID -> file/video scelto)
    <Playlist>.m3u8    playlist locale nell'ordine di Music
    _rimossi/          file tolti dalla playlist (solo con --prune, non cancella nulla)
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

JXA_LIST = r"""
function run(argv) {
  const app = Application('Music');
  const pls = app.userPlaylists;
  const ids = pls.persistentID(), names = pls.name();
  const smart = pls.smart(), special = pls.specialKind();
  const out = [];
  for (let i = 0; i < ids.length; i++) {
    let n = -1;
    try { n = pls[i].tracks.length; } catch (e) {}
    out.push({id: ids[i], name: names[i], count: n,
              smart: !!smart[i], special: String(special[i])});
  }
  return JSON.stringify(out);
}
"""

# argv[0] = nome, argv[1] = persistentID (opzionale, vince sul nome)
JXA_TRACKS = r"""
function run(argv) {
  const app = Application('Music');
  const pl = argv[1] ? app.userPlaylists.whose({persistentID: argv[1]})[0]
                     : app.userPlaylists.byName(argv[0]);
  const t = pl.tracks;
  const ids = t.persistentID();
  const names = t.name();
  const artists = t.artist();
  const albums = t.album();
  const durs = t.duration();
  let locs = null;
  try { locs = t.location(); } catch (e) { locs = null; }
  const out = [];
  for (let i = 0; i < ids.length; i++) {
    let loc = null;
    if (locs) {
      loc = locs[i];
    } else {
      try { loc = t[i].location(); } catch (e) { loc = null; }
    }
    loc = (loc === null || loc === undefined) ? null : String(loc);
    if (loc === '' || loc === 'null' || loc === 'missing value') loc = null;
    out.push({
      id: ids[i], name: names[i] || '', artist: artists[i] || '',
      album: albums[i] || '', duration: durs[i] || 0, location: loc
    });
  }
  return JSON.stringify(out);
}
"""

# parole che penalizzano un risultato YouTube se NON compaiono nel titolo originale
BAD_WORDS = [
    "live", "cover", "karaoke", "remix", "instrumental", "reaction",
    "slowed", "sped up", "nightcore", "8d", "acoustic", "tribute", "mashup",
]

# quanti candidati provare se il download fallisce
MAX_TRIES = 3

# con --json ogni messaggio diventa una riga JSON su stdout (usato dall'app)
JSON_OUT = False


def emit(ev, msg, **data):
    if JSON_OUT:
        print(json.dumps({"ev": ev, "msg": msg, **data}, ensure_ascii=False), flush=True)
    else:
        print(msg)


def jxa(code, *args):
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
        f.write(code)
        path = f.name
    try:
        r = subprocess.run(
            ["osascript", "-l", "JavaScript", path, *args],
            capture_output=True, text=True,
        )
    finally:
        os.unlink(path)
    if r.returncode != 0:
        sys.exit(f"Errore osascript: {r.stderr.strip()}\n"
                 "(Se è la prima volta, consenti al Terminale di controllare Music in "
                 "Impostazioni > Privacy e sicurezza > Automazione)")
    return json.loads(r.stdout)


def safe(s):
    s = re.sub(r'[\\/:*?"<>|]', "_", s).strip(" .")
    return s[:120] or "senza_nome"


def score(c, t, tol):
    """Punteggio più basso = meglio. None = scartato."""
    d = c.get("duration")
    if t["duration"] and t["duration"] > 0:
        if not d:
            return None
        diff = abs(d - t["duration"])
        if diff > tol:
            return None
    else:
        diff = 0
    s = float(diff)
    title = (c.get("title") or "").lower()
    orig = f"{t['name']} {t['album']}".lower()
    for w in BAD_WORDS:
        if re.search(rf"\b{re.escape(w)}\b", title) and w not in orig:
            s += 15
    ch = (c.get("channel") or c.get("uploader") or "").lower()
    if ch.endswith("- topic") or "vevo" in ch:
        s -= 3
    first_artist = re.split(r"[,&]", t["artist"])[0].strip().lower()
    if first_artist and first_artist in f"{ch} {title}":
        s -= 2
    if "official audio" in title:
        s -= 1
    return s


def ydl_base(cookies_browser):
    opts = {"quiet": True}
    if cookies_browser:
        # es. "chrome", "firefox", "safari" o "chrome:Profile 1"
        browser, _, profile = cookies_browser.partition(":")
        opts["cookiesfrombrowser"] = (browser, profile or None)
    return opts


def find_matches(t, tol, cookies_browser=None):
    """Candidati entro tolleranza, ordinati dal migliore."""
    from yt_dlp import YoutubeDL
    q = f"ytsearch8:{t['artist']} - {t['name']}"
    opts = {**ydl_base(cookies_browser), "extract_flat": True, "skip_download": True}
    with YoutubeDL(opts) as y:
        info = y.extract_info(q, download=False)
    scored = []
    for c in (info or {}).get("entries", []) or []:
        s = score(c, t, tol)
        if s is not None:
            scored.append((s, c))
    scored.sort(key=lambda x: x[0])
    return [c for _, c in scored]


# formato -> (codec per yt-dlp, estensione). aiff passa da wav e si converte dopo.
FORMATS = {
    "mp3": ("mp3", ".mp3"),
    "m4a": ("m4a", ".m4a"),
    "flac": ("flac", ".flac"),
    "wav": ("wav", ".wav"),
    "aiff": ("wav", ".aiff"),
}


def download_audio(video_id, outbase, fmt="mp3", quality="192", cookies_browser=None):
    """Scarica l'audio e lo converte nel formato scelto. quality vale per mp3/m4a:
    kbps (128-320) oppure 0 = VBR alta qualità."""
    from yt_dlp import YoutubeDL
    codec, ext = FORMATS[fmt]
    opts = {
        **ydl_base(cookies_browser),
        "format": "bestaudio/best",
        "outtmpl": str(outbase).replace("%", "%%") + ".%(ext)s",
        "noprogress": True,
        "postprocessors": [{
            "key": "FFmpegExtractAudio",
            "preferredcodec": codec,
            "preferredquality": str(quality),
        }],
    }
    with YoutubeDL(opts) as y:
        y.download([f"https://www.youtube.com/watch?v={video_id}"])
    out = Path(str(outbase) + ext)
    if fmt == "aiff":
        wav = Path(str(outbase) + ".wav")
        r = subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(wav),
                            "-c:a", "pcm_s16be", str(out)], capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f"conversione AIFF fallita: {r.stderr.strip()}")
        wav.unlink()
    return out


def tag_file(path, t):
    """Titolo/artista/album; ID3 per mp3/wav/aiff, tag nativi per m4a e flac."""
    try:
        import mutagen
        from mutagen.id3 import TALB, TIT2, TPE1
        if path.suffix in (".mp3", ".wav", ".aiff"):
            f = mutagen.File(str(path))
            if f.tags is None:
                f.add_tags()
            tags = f.tags
            tags.add(TIT2(encoding=3, text=t["name"]))
            tags.add(TPE1(encoding=3, text=t["artist"]))
            if t.get("album"):
                tags.add(TALB(encoding=3, text=t["album"]))
            f.save()
        else:
            f = mutagen.File(str(path), easy=True)
            if f.tags is None:
                f.add_tags()
            f["title"] = t["name"]
            f["artist"] = t["artist"]
            if t.get("album"):
                f["album"] = t["album"]
            f.save()
    except Exception as e:
        emit("warn", f"    (tag non scritti: {e})")


def load_state(folder):
    p = folder / ".sync_state.json"
    return json.loads(p.read_text()) if p.exists() else {}


def save_state(folder, state):
    (folder / ".sync_state.json").write_text(
        json.dumps(state, indent=2, ensure_ascii=False))


def cookies_usable(browser):
    """Verifica una volta sola che i cookie del browser siano leggibili."""
    from yt_dlp.cookies import extract_cookies_from_browser
    b, _, profile = browser.partition(":")
    try:
        extract_cookies_from_browser(b, profile or None)
        return True
    except Exception as e:
        hint = ""
        if "not permitted" in str(e):
            hint = (" Dai a Music Sync l'Accesso completo al disco in Impostazioni di "
                    "Sistema > Privacy e sicurezza.")
        emit("warn", f"Login YouTube da {b} non disponibile, continuo senza: i video con "
                     f"blocco età verranno saltati.{hint}")
        return False


def sync_playlist(name, dest, tol, prune, dry, use_local, cookies_browser=None,
                  pid=None, folder_name=None, fmt="mp3", quality="192", tracks=None):
    if tracks is None:
        tracks = jxa(JXA_TRACKS, name, *([pid] if pid else []))
    folder = Path(dest).expanduser() / (folder_name or safe(name))
    emit("start", f"\n=== {name} ({len(tracks)} brani) -> {folder}",
         playlist=name, total=len(tracks), folder=str(folder))
    if not dry:
        folder.mkdir(parents=True, exist_ok=True)
    state = load_state(folder) if folder.exists() else {}
    current_ids = {t["id"] for t in tracks}
    ok = skipped = failed = 0
    failures = []

    for i, t in enumerate(tracks, 1):
        label = f"{t['artist']} - {t['name']}"
        entry = state.get(t["id"])
        if entry and (folder / entry["file"]).exists():
            skipped += 1
            if JSON_OUT:
                emit("track", label, i=i, label=label, status="present")
            continue

        base = safe(label)
        target_stem = base
        used = {e["file"] for k, e in state.items() if k != t["id"]}
        ext = FORMATS[fmt][1]
        if f"{base}{ext}" in used or (folder / f"{base}{ext}").exists():
            target_stem = f"{base} [{t['id'][-4:]}]"

        # 1) file locale già presente in Music
        loc = Path(t["location"]) if t["location"] else None
        if use_local and loc and loc.exists():
            ext = loc.suffix or ".m4a"
            emit("track", f"[{i}/{len(tracks)}] locale: {label}", i=i, label=label, status="local")
            if not dry:
                shutil.copy2(loc, folder / f"{target_stem}{ext}")
                state[t["id"]] = {"file": f"{target_stem}{ext}", "src": "local",
                                  "name": t["name"], "artist": t["artist"]}
            ok += 1
            continue

        # 2) ricerca + download da YouTube
        emit("track", f"[{i}/{len(tracks)}] cerco: {label}", i=i, label=label, status="search")
        try:
            cands = find_matches(t, tol, cookies_browser)
        except Exception as e:
            emit("warn", f"    ricerca fallita: {e}", i=i)
            cands = []
        if not cands:
            emit("result", f"    NON TROVATO (nessun risultato entro ±{tol}s)",
                 i=i, status="notfound")
            failed += 1
            failures.append(label)
            continue
        # se il download fallisce (es. blocco età) prova il candidato successivo
        done = False
        for m in cands[:MAX_TRIES]:
            emit("match", f"    -> {m.get('title')} [{m.get('channel') or m.get('uploader')}] "
                          f"{m.get('duration')}s vs {t['duration']:.0f}s",
                 i=i, title=m.get("title"), channel=m.get("channel") or m.get("uploader"),
                 yt_duration=m.get("duration"), duration=round(t["duration"]))
            if dry:
                done = True
                break
            try:
                out = download_audio(m["id"], folder / target_stem, fmt, quality,
                                     cookies_browser)
                tag_file(out, t)
                state[t["id"]] = {"file": out.name, "src": "youtube", "vid": m["id"],
                                  "name": t["name"], "artist": t["artist"]}
                save_state(folder, state)
                done = True
                break
            except Exception as e:
                emit("warn", f"    download fallito: {e}", i=i)
            finally:
                time.sleep(1)
        if done:
            ok += 1
            if JSON_OUT:
                emit("result", label, i=i, status="dry" if dry else "done")
        else:
            failed += 1
            failures.append(label)
            if JSON_OUT:
                emit("result", label, i=i, status="failed")

    # prune: sposta in _rimossi i file non più in playlist
    removed = 0
    if prune:
        for tid in list(state):
            if tid not in current_ids:
                f = folder / state[tid]["file"]
                emit("removed", f"rimosso dalla playlist: {state[tid]['file']}")
                if not dry and f.exists():
                    (folder / "_rimossi").mkdir(exist_ok=True)
                    shutil.move(str(f), str(folder / "_rimossi" / f.name))
                if not dry:
                    del state[tid]
                removed += 1

    if not dry:
        save_state(folder, state)
        lines = ["#EXTM3U"]
        for t in tracks:
            e = state.get(t["id"])
            if e and (folder / e["file"]).exists():
                lines.append(f"#EXTINF:{int(t['duration'])},{t['artist']} - {t['name']}")
                lines.append(e["file"])
        (folder / f"{folder.name}.m3u8").write_text("\n".join(lines) + "\n")
        nf = folder / "_non_trovati.txt"
        if failures:
            nf.write_text("\n".join(failures) + "\n")
        elif nf.exists():
            nf.unlink()

    emit("end", f"--- {name}: nuovi {ok}, già presenti {skipped}, falliti {failed}, "
                f"rimossi {removed}{' (dry-run)' if dry else ''}",
         ok=ok, skipped=skipped, failed=failed, removed=removed)


# --- Spotify ------------------------------------------------------------------
# Senza account developer: la pagina "embed" pubblica della playlist contiene
# titolo, artisti e durata dei brani, ma al massimo i primi 100.
SPOTIFY_EMBED_LIMIT = 100


def spotify_playlist(url):
    """Playlist pubblica da link Spotify -> {id, name, tracks}."""
    import ssl
    import urllib.request
    m = re.search(r"playlist[/:]([A-Za-z0-9]{22})", url)
    if not m:
        sys.exit("Link Spotify non valido: serve un link a una playlist "
                 "(open.spotify.com/playlist/...)")
    sid = m.group(1)
    try:
        import certifi
        ctx = ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        ctx = None
    req = urllib.request.Request(
        f"https://open.spotify.com/embed/playlist/{sid}",
        headers={"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"})
    try:
        html = urllib.request.urlopen(req, timeout=20, context=ctx).read().decode("utf-8")
        data = re.search(r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>',
                         html, re.S).group(1)
        ent = json.loads(data)["props"]["pageProps"]["state"]["data"]["entity"]
    except Exception as e:
        sys.exit(f"Playlist Spotify non leggibile (privata o link sbagliato?): {e}")
    tracks = []
    for t in ent.get("trackList") or []:
        tracks.append({
            "id": t.get("uri") or t.get("title"),
            "name": t.get("title") or "",
            "artist": (t.get("subtitle") or "").replace("\xa0", " "),
            "album": "",
            "duration": (t.get("duration") or 0) / 1000,
            "location": None,
        })
    return {"id": sid, "name": ent.get("name") or sid, "tracks": tracks}


# Export CSV di Exportify (exportify.app): le intestazioni sono tradotte nella
# lingua del browser, l'ordine delle colonne no. Si legge quindi per posizione.
CSV_URI, CSV_NAME, CSV_ARTISTS, CSV_ALBUM, CSV_DURATION = 0, 1, 3, 5, 12


def csv_playlist_name(path):
    """Exportify salva 'Estate 2026' come estate_2026.csv."""
    stem = Path(path).stem.replace("_", " ").strip()
    return stem[:1].upper() + stem[1:] if stem else "Playlist"


def read_spotify_csv(path):
    """Brani da un CSV di Exportify; esce con un messaggio se il file non lo è."""
    import csv
    tracks = []
    try:
        with open(path, newline="", encoding="utf-8-sig") as f:
            for row in csv.reader(f):
                if len(row) <= CSV_DURATION or not row[CSV_URI].startswith("spotify:"):
                    continue  # intestazione o riga non valida
                # gli artisti sono separati da ", " e le virgole nei nomi sono "\,"
                artists = [a.replace("\\,", ",")
                           for a in re.split(r"(?<!\\), ", row[CSV_ARTISTS]) if a]
                try:
                    dur = int(row[CSV_DURATION]) / 1000
                except ValueError:
                    dur = 0
                tracks.append({
                    "id": row[CSV_URI], "name": row[CSV_NAME],
                    "artist": ", ".join(artists), "album": row[CSV_ALBUM],
                    "duration": dur, "location": None,
                })
    except (OSError, UnicodeDecodeError, csv.Error) as e:
        sys.exit(f"File non leggibile: {e}")
    if not tracks:
        sys.exit("Questo file non sembra un export di Exportify (nessun brano Spotify trovato).")
    return tracks


def spotify_folder(name):
    return f"{safe(name)} (Spotify)"


def search_youtube(query, n=10, cookies_browser=None):
    """Risultati grezzi di una ricerca, senza filtro sulla durata."""
    from yt_dlp import YoutubeDL
    opts = {**ydl_base(cookies_browser), "extract_flat": True, "skip_download": True}
    with YoutubeDL(opts) as y:
        info = y.extract_info(f"ytsearch{n}:{query}", download=False)
    out = []
    for c in (info or {}).get("entries", []) or []:
        thumbs = c.get("thumbnails") or []
        out.append({
            "id": c["id"], "title": c.get("title") or "",
            "channel": c.get("channel") or c.get("uploader") or "",
            "duration": c.get("duration"),
            "thumbnail": thumbs[0]["url"] if thumbs else None,
        })
    return out


# pezzi di titolo YouTube da togliere per ricavare il nome del brano
NOISE = re.compile(
    r"\s*[\(\[][^\)\]]*\b(official|audio|video|visualizer|lyrics?|hd|4k|hq|clip)\b"
    r"[^\)\]]*[\)\]]", re.I)


def guess_tags(title, channel):
    """'Artista - Titolo (Official Video)' -> ('Artista', 'Titolo')."""
    t = title.split(" | ")[0]
    t = NOISE.sub("", t).strip()
    if " - " in t:
        artist, name = t.split(" - ", 1)
        return artist.strip(), name.strip()
    artist = re.sub(r"\s*(- Topic|VEVO)$", "", channel or "", flags=re.I).strip()
    # "Metallica: Enter Sandman" sul canale Metallica
    if artist and t.lower().startswith(artist.lower() + ":"):
        t = t[len(artist) + 1:].strip()
    return artist, t


def get_single(video_id, dest, artist=None, title=None, yt_title="", channel="",
               cookies_browser=None, fmt="mp3", quality="192"):
    """Scarica un singolo video nel formato scelto in dest/Singoli."""
    g_artist, g_title = guess_tags(yt_title, channel)
    t = {"artist": artist or g_artist, "name": title or g_title, "album": ""}
    folder = Path(dest).expanduser() / "Singoli"
    folder.mkdir(parents=True, exist_ok=True)
    stem = safe(f"{t['artist']} - {t['name']}" if t["artist"] else t["name"])
    if (folder / f"{stem}{FORMATS[fmt][1]}").exists():
        stem = f"{stem} [{video_id[-4:]}]"
    emit("start", f"scarico {t['artist']} - {t['name']}", id=video_id)
    out = download_audio(video_id, folder / stem, fmt, quality, cookies_browser)
    tag_file(out, t)
    emit("done", str(out), id=video_id, file=str(out))


def main():
    global JSON_OUT
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    lp = sub.add_parser("list", help="elenca le playlist di Music")
    lp.add_argument("--json", action="store_true",
                    help="output JSON con id, numero brani, smart/speciale")
    s = sub.add_parser("sync", help="sincronizza una o tutte le playlist")
    s.add_argument("playlist", nargs="?", help="nome playlist (omettere con --all)")
    s.add_argument("--id", help="persistentID della playlist (per nomi duplicati)")
    s.add_argument("--spotify", metavar="LINK",
                   help="playlist Spotify pubblica invece di una di Musica "
                        f"(massimo {SPOTIFY_EMBED_LIMIT} brani)")
    s.add_argument("--csv", metavar="FILE",
                   help="playlist Spotify esportata con Exportify (anche privata)")
    s.add_argument("--name", help="con --csv: nome della playlist (default: dal file)")
    si = sub.add_parser("spotify-info", help="nome e numero brani di una playlist Spotify")
    si.add_argument("url")
    ci = sub.add_parser("csv-info", help="nome e numero brani di un CSV di Exportify")
    ci.add_argument("path")
    ci.add_argument("--name", help="nome della playlist (default: dal nome del file)")
    s.add_argument("--all", action="store_true",
                   help="tutte le playlist normali (escluse smart, cartelle e di sistema)")
    s.add_argument("--json", action="store_true",
                   help="eventi JSON una riga alla volta (per l'app)")
    s.add_argument("--dest", default="~/Music/YT-Sync")
    s.add_argument("--tolerance", type=int, default=6,
                   help="differenza massima di durata in secondi (default 6)")
    s.add_argument("--prune", action="store_true",
                   help="sposta in _rimossi i file tolti dalla playlist")
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--no-local", action="store_true",
                   help="non copiare i file già locali di Music")
    s.add_argument("--cookies-from-browser", metavar="BROWSER[:PROFILO]",
                   help="usa il login YouTube del browser (chrome, firefox, safari...) "
                        "per i video con blocco età")
    se = sub.add_parser("search", help="cerca un brano su YouTube")
    se.add_argument("query")
    se.add_argument("-n", type=int, default=10, help="numero di risultati (default 10)")
    se.add_argument("--json", action="store_true")
    se.add_argument("--cookies-from-browser", metavar="BROWSER[:PROFILO]")
    g = sub.add_parser("get", help="scarica un singolo video in <dest>/Singoli")
    g.add_argument("video_id")
    g.add_argument("--dest", default="~/Music/YT-Sync")
    g.add_argument("--artist", help="tag artista (default: ricavato dal titolo)")
    g.add_argument("--title", help="tag titolo (default: ricavato dal titolo)")
    g.add_argument("--yt-title", default="", help="titolo YouTube, per ricavare i tag")
    g.add_argument("--channel", default="", help="canale YouTube, per ricavare i tag")
    g.add_argument("--json", action="store_true")
    g.add_argument("--cookies-from-browser", metavar="BROWSER[:PROFILO]")
    for p in (s, g):
        p.add_argument("--format", choices=list(FORMATS), default="mp3",
                       help="formato audio (default mp3)")
        p.add_argument("--quality", default="192",
                       help="mp3/m4a: kbps (128, 192, 256, 320) oppure 0 = VBR alta "
                            "qualità (default 192)")
    a = ap.parse_args()

    if a.cmd == "search":
        cookies = a.cookies_from_browser
        if cookies and not cookies_usable(cookies):
            cookies = None
        res = search_youtube(a.query, a.n, cookies)
        if a.json:
            print(json.dumps(res, ensure_ascii=False))
        else:
            for r in res:
                print(f"{r['id']}  {r['duration'] or '?':>5}s  {r['title']} [{r['channel']}]")
        return

    if a.cmd == "get":
        JSON_OUT = a.json
        if shutil.which("ffmpeg") is None:
            sys.exit("ffmpeg non trovato: brew install ffmpeg")
        cookies = a.cookies_from_browser
        if cookies and not cookies_usable(cookies):
            cookies = None
        yt_title, channel = a.yt_title, a.channel
        if not (a.artist and a.title) and not yt_title:
            # senza titolo YouTube lo recupero, servono i tag
            from yt_dlp import YoutubeDL
            with YoutubeDL({**ydl_base(cookies), "extract_flat": True}) as y:
                info = y.extract_info(f"https://www.youtube.com/watch?v={a.video_id}",
                                      download=False, process=False)
            yt_title = info.get("title") or ""
            channel = info.get("channel") or info.get("uploader") or ""
        try:
            get_single(a.video_id, a.dest, a.artist, a.title, yt_title, channel, cookies,
                       a.format, a.quality)
        except Exception as e:
            emit("error", f"download fallito: {e}", id=a.video_id)
            sys.exit(1)
        return

    if a.cmd == "csv-info":
        tracks = read_spotify_csv(a.path)
        name = a.name or csv_playlist_name(a.path)
        print(json.dumps({"id": "csv:" + Path(a.path).stem.lower(), "name": name,
                          "count": len(tracks), "smart": False, "special": "none",
                          "csvPath": str(Path(a.path).resolve())}, ensure_ascii=False))
        return

    if a.cmd == "spotify-info":
        sp = spotify_playlist(a.url)
        print(json.dumps({"id": "sp:" + sp["id"], "name": sp["name"],
                          "count": len(sp["tracks"]), "smart": False, "special": "none",
                          "spotifyURL": f"https://open.spotify.com/playlist/{sp['id']}"},
                         ensure_ascii=False))
        return

    if a.cmd == "list":
        pls = jxa(JXA_LIST)
        if a.json:
            print(json.dumps(pls, ensure_ascii=False))
        else:
            for p in pls:
                print(p["name"])
        return

    JSON_OUT = a.json
    if a.csv:
        if shutil.which("ffmpeg") is None:
            sys.exit("ffmpeg non trovato: brew install ffmpeg")
        tracks = read_spotify_csv(a.csv)
        name = a.name or csv_playlist_name(a.csv)
        cookies = a.cookies_from_browser
        if cookies and not cookies_usable(cookies):
            cookies = None
        sync_playlist(name, a.dest, a.tolerance, a.prune, a.dry_run, False, cookies,
                      folder_name=spotify_folder(name), fmt=a.format,
                      quality=a.quality, tracks=tracks)
        return

    if a.spotify:
        if shutil.which("ffmpeg") is None:
            sys.exit("ffmpeg non trovato: brew install ffmpeg")
        sp = spotify_playlist(a.spotify)
        if len(sp["tracks"]) >= SPOTIFY_EMBED_LIMIT:
            emit("warn", f"Spotify mostra solo i primi {SPOTIFY_EMBED_LIMIT} brani: "
                         "quelli successivi non vengono sincronizzati")
        cookies = a.cookies_from_browser
        if cookies and not cookies_usable(cookies):
            cookies = None
        sync_playlist(sp["name"], a.dest, a.tolerance, a.prune, a.dry_run, False, cookies,
                      folder_name=spotify_folder(sp["name"]), fmt=a.format,
                      quality=a.quality, tracks=sp["tracks"])
        return

    if not a.all and not a.playlist and not a.id:
        ap.error("indica una playlist (nome o --id) oppure usa --all")
    if shutil.which("ffmpeg") is None:
        sys.exit("ffmpeg non trovato: brew install ffmpeg")
    cookies = a.cookies_from_browser
    if cookies and not cookies_usable(cookies):
        cookies = None

    pls = jxa(JXA_LIST)
    # playlist con lo stesso nome: cartella distinta con suffisso dell'id
    counts = {}
    for p in pls:
        counts[safe(p["name"])] = counts.get(safe(p["name"]), 0) + 1

    def folder_for(p):
        base = safe(p["name"])
        return f"{base} [{p['id'][-4:]}]" if counts[base] > 1 else base

    if a.all:
        todo = [p for p in pls if not p["smart"] and p["special"] == "none"]
    elif a.id:
        todo = [p for p in pls if p["id"] == a.id]
        if not todo:
            sys.exit(f"playlist con id {a.id} non trovata")
    else:
        todo = [p for p in pls if p["name"] == a.playlist][:1]
        if not todo:
            sys.exit(f"playlist '{a.playlist}' non trovata")
    for p in todo:
        sync_playlist(p["name"], a.dest, a.tolerance, a.prune, a.dry_run, not a.no_local,
                      cookies, pid=p["id"], folder_name=folder_for(p),
                      fmt=a.format, quality=a.quality)


if __name__ == "__main__":
    main()
