#!/bin/bash
# Compila Music Sync.app in build/.
#
#   ./build_app.sh               app per questo Mac (usa .venv e Homebrew di questa cartella)
#   ./build_app.sh --standalone  app autonoma da condividere: Python, yt-dlp, ffmpeg e deno
#                                dentro il pacchetto, più build/Music Sync.dmg da condividere
#
# Requisiti per --standalone: Xcode, Homebrew con lame, mpg123 e deno
# (brew install lame mpg123 deno).
set -euo pipefail

PY_RELEASE="20261021"
PY_VERSION="3.13.17"
FFMPEG_VERSION="9.0.2"

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
CACHE="$BUILD/cache"
APP="$BUILD/Music Sync.app"
RES="$APP/Contents/Resources"
STANDALONE=0
[ "${1:-}" = "--standalone" ] && STANDALONE=1
mkdir -p "$CACHE"

# --- icona -------------------------------------------------------------------
make_icon() {
    local icns="$CACHE/AppIcon.icns"
    if [ ! -f "$icns" ] || [ "$ROOT/MusicSyncApp/make_icon.swift" -nt "$icns" ]; then
        local set="$CACHE/AppIcon.iconset"
        rm -rf "$set" && mkdir -p "$set"
        swift "$ROOT/MusicSyncApp/make_icon.swift" "$CACHE/icon_1024.png" >/dev/null
        for s in 16 32 128 256 512; do
            sips -z $s $s "$CACHE/icon_1024.png" --out "$set/icon_${s}x${s}.png" >/dev/null
            sips -z $((s * 2)) $((s * 2)) "$CACHE/icon_1024.png" \
                --out "$set/icon_${s}x${s}@2x.png" >/dev/null
        done
        iconutil -c icns "$set" -o "$icns"
    fi
    cp "$icns" "$RES/AppIcon.icns"
}

# --- Python portatile (astral-sh/python-build-standalone) ---------------------
bundle_python() {
    local name="cpython-${PY_VERSION}+${PY_RELEASE}-aarch64-apple-darwin-install_only_stripped.tar.gz"
    local url="https://github.com/astral-sh/python-build-standalone/releases/download/${PY_RELEASE}"
    if [ ! -f "$CACHE/$name" ]; then
        echo "Scarico Python ${PY_VERSION}..."
        curl -fL --progress-bar -o "$CACHE/$name.part" "$url/$name"
        curl -fsSL -o "$CACHE/SHA256SUMS" "$url/SHA256SUMS"
        local want got
        want="$(grep " $name\$" "$CACHE/SHA256SUMS" | cut -d' ' -f1)"
        got="$(shasum -a 256 "$CACHE/$name.part" | cut -d' ' -f1)"
        [ -n "$want" ] && [ "$want" = "$got" ] || { echo "Checksum Python non valido"; exit 1; }
        mv "$CACHE/$name.part" "$CACHE/$name"
    fi
    tar -xzf "$CACHE/$name" -C "$RES"          # crea $RES/python
    local py="$RES/python/bin/python3"
    "$py" -m pip install -q --no-cache-dir --disable-pip-version-check "yt-dlp[default]" mutagen
    # roba che non serve all'app
    local lib="$RES/python/lib/python${PY_VERSION%.*}"
    rm -rf "$lib"/{test,idlelib,tkinter,turtledemo,ensurepip} "$RES"/python/lib/{tcl,tk,itcl,thread}* \
           "$RES"/python/share "$RES"/python/include
    find "$RES/python" -name "__pycache__" -type d -prune -exec rm -rf {} +
    "$py" -m compileall -q -j 0 "$RES/python/lib" >/dev/null || true
}

# --- ffmpeg minimo: solo ciò che serve per webm/m4a -> mp3, lame statico -----
build_ffmpeg() {
    local dst="$CACHE/ffmpeg-$FFMPEG_VERSION-bin"
    if [ ! -x "$dst/ffmpeg" ]; then
        echo "Compilo ffmpeg ${FFMPEG_VERSION} (qualche minuto)..."
        local tarball="$CACHE/ffmpeg-$FFMPEG_VERSION.tar.xz"
        [ -f "$tarball" ] || curl -fsSL -o "$tarball" \
            "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
        # configure di ffmpeg non accetta percorsi con spazi: si compila in /tmp
        local work
        work="$(mktemp -d)"
        tar -xJf "$tarball" -C "$work"
        local src="$work/ffmpeg-$FFMPEG_VERSION"
        # solo le librerie statiche, così lame (e mpg123 che usa) finiscono nel binario
        local lame
        lame="$(brew --prefix lame)"
        mkdir -p "$work/lame"
        cp "$lame/lib/libmp3lame.a" "$(brew --prefix mpg123)/lib/libmpg123.a" "$work/lame/"
        (
            cd "$src"
            ./configure \
                --disable-everything --disable-autodetect --disable-doc --disable-network \
                --disable-ffplay --enable-ffmpeg --enable-ffprobe --enable-zlib \
                --enable-libmp3lame --enable-encoder=libmp3lame \
                --enable-decoder=opus,aac,aac_latm,mp3,mp3float,vorbis,flac,pcm_s16le,pcm_f32le \
                --enable-demuxer=matroska,mov,mp3,aac,ogg,wav,flac \
                --enable-muxer=mp3,wav,mov,mp4,ipod --enable-parser=opus,aac,mpegaudio,vorbis,flac \
                --enable-protocol=file,pipe \
                --enable-filter=aresample,aformat,anull,atrim,volume,null,format \
                --extra-cflags="-I$lame/include -mmacosx-version-min=14.0" \
                --extra-ldflags="-L$work/lame -mmacosx-version-min=14.0" \
                --extra-libs="-lmpg123" >/dev/null ||
                { tail -5 ffbuild/config.log; exit 1; }
            make -j"$(sysctl -n hw.ncpu)" >/dev/null 2>&1
            mkdir -p "$dst" && cp ffmpeg ffprobe "$dst/"
        )
        rm -rf "$work"
    fi
    mkdir -p "$RES/bin"
    cp "$dst/ffmpeg" "$dst/ffprobe" "$RES/bin/"
}

# --- DMG: app + link ad Applicazioni + Leggimi, con sfondo e freccia ---------
# dmgbuild scrive sfondo e posizioni delle icone senza passare dal Finder.
make_dmg() {
    local dmg="$BUILD/Music Sync.dmg" tmp
    tmp="$(mktemp -d)"
    [ -x "$ROOT/.venv/bin/dmgbuild" ] || "$ROOT/.venv/bin/pip" install -q dmgbuild
    # sfondo @1x + @2x nello stesso tiff
    swift "$ROOT/MusicSyncApp/make_dmg_background.swift" "$tmp/bg.png" 1
    swift "$ROOT/MusicSyncApp/make_dmg_background.swift" "$tmp/bg@2x.png" 2
    tiffutil -cathidpicheck "$tmp/bg.png" "$tmp/bg@2x.png" -out "$tmp/bg.tiff" >/dev/null 2>&1
    rm -f "$dmg"
    "$ROOT/.venv/bin/dmgbuild" -s "$ROOT/dist/dmg_settings.py" \
        -D app="$APP" -D readme="$ROOT/dist/Leggimi.txt" -D background="$tmp/bg.tiff" \
        "Music Sync" "$dmg" >/dev/null
    rm -rf "$tmp"
}

bundle_deno() {
    cp "$(readlink -f "$(brew --prefix deno)/bin/deno")" "$RES/bin/deno"
    chmod 755 "$RES/bin/deno"
}

# --- build ---------------------------------------------------------------------
cd "$ROOT/MusicSyncApp"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/MusicSync"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES"
cp "$BIN" "$APP/Contents/MacOS/MusicSync"
cp "$ROOT/music_sync.py" "$RES/"
make_icon

if [ $STANDALONE = 1 ]; then
    sed "s|@PYTHON@||" Info.plist > "$APP/Contents/Info.plist"
    bundle_python
    build_ffmpeg
    bundle_deno
    # firma ad hoc ogni eseguibile e libreria, poi il pacchetto
    find "$RES" -type f \( -perm -u+x -o -name "*.so" -o -name "*.dylib" \) -print0 |
        while IFS= read -r -d '' f; do
            if file -b "$f" | grep -q Mach-O; then
                codesign --force --sign - "$f" 2>/dev/null
            fi
        done
    codesign --force --sign - "$APP"
    codesign --verify --deep --strict "$APP"
    rm -f "$BUILD/Music Sync.zip"
    make_dmg
    echo "Creata: $APP ($(du -sh "$APP" | cut -f1))"
    echo "Da condividere: $BUILD/Music Sync.dmg ($(du -sh "$BUILD/Music Sync.dmg" | cut -f1))"
else
    PY="$ROOT/.venv/bin/python"
    [ -x "$PY" ] || { echo "Manca $PY: crea prima il venv (vedi music_sync.py)"; exit 1; }
    sed "s|@PYTHON@|$PY|" Info.plist > "$APP/Contents/Info.plist"
    codesign --force --sign - "$APP"
    echo "Creata: $APP"
fi
