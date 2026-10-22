#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Raccoglie le licenze dei componenti inclusi nell'app autonoma in un unico file.

Uso (da build_app.sh):
    collect_licenses.py <Resources> <ffmpeg.tar.xz> <ffmpeg-version> <out.txt>
"""
import email
import sys
import tarfile
from pathlib import Path

res, ffmpeg_tar, ffmpeg_ver, out = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4])
brew = Path("/opt/homebrew/opt")
SEP = "=" * 78

parts = [
    "MUSIC SYNC - LICENZE DEI COMPONENTI DI TERZE PARTI",
    "",
    "Music Sync è software libero distribuito con licenza GNU GPL versione 3 o",
    "successiva (vedi LICENSE.txt). Il codice sorgente è su",
    "https://github.com/Powertheking/music-sync",
    "",
    "L'app include i componenti seguenti, ognuno con la propria licenza.",
    "",
]


def section(title, body, note=""):
    parts.extend([SEP, title, SEP])
    if note:
        parts.extend([note, ""])
    parts.extend([body.strip(), ""])


def read(p):
    return Path(p).read_text(encoding="utf-8", errors="replace")


# Python (python-build-standalone): il LICENSE.txt include anche le librerie collegate
py_lib = next((res / "python" / "lib").glob("python3.*"))
section(f"Python {py_lib.name.removeprefix('python')} "
        "(build di astral-sh/python-build-standalone)",
        read(py_lib / "LICENSE.txt"),
        "Sorgente: https://www.python.org/downloads/source/ e "
        "https://github.com/astral-sh/python-build-standalone")

# pacchetti Python: licenza dichiarata nei metadati e file di licenza del pacchetto
for dist in sorted((py_lib / "site-packages").glob("*.dist-info")):
    meta = email.message_from_string(read(dist / "METADATA"))
    name, version = meta["Name"], meta["Version"]
    if name == "pip":
        continue  # serve solo durante la build
    lic = meta.get("License-Expression") or meta.get("License") or ""
    if not lic or len(lic) > 80:
        lic = ", ".join(c.split("::")[-1].strip() for c in meta.get_all("Classifier") or []
                        if c.startswith("License ::")) or "vedi testo"
    files = sorted(p for p in dist.rglob("*")
                   if p.is_file() and any(k in p.name.upper()
                                          for k in ("LICENSE", "COPYING", "NOTICE", "AUTHORS")))
    body = "\n\n".join(read(f) for f in files) or f"Licenza: {lic}"
    section(f"{name} {version} - {lic}", body,
            f"Sorgente: https://pypi.org/project/{name}/{version}/")

# ffmpeg: compilato da noi in configurazione LGPL (nessun componente GPL attivo)
with tarfile.open(ffmpeg_tar) as t:
    lgpl = t.extractfile(f"ffmpeg-{ffmpeg_ver}/COPYING.LGPLv2.1").read().decode()
section(f"FFmpeg {ffmpeg_ver} (ffmpeg, ffprobe) - LGPL-2.1-or-later", lgpl,
        f"Compilato senza modifiche dal sorgente ufficiale "
        f"https://ffmpeg.org/releases/ffmpeg-{ffmpeg_ver}.tar.xz con le opzioni\n"
        "indicate in build_app.sh (https://github.com/Powertheking/music-sync).\n"
        "Include LAME (libmp3lame) e mpg123, sotto.")

section("LAME (libmp3lame) - LGPL-2.0-or-later", read(brew / "lame" / "COPYING"),
        "Sorgente: https://lame.sourceforge.io")
section("mpg123 (libmpg123) - LGPL-2.1-only", read(brew / "mpg123" / "COPYING"),
        "Sorgente: https://www.mpg123.de")
section("Deno - MIT", read(brew / "deno" / "LICENSE.md"),
        "Sorgente: https://github.com/denoland/deno")

out.write_text("\n".join(parts) + "\n", encoding="utf-8")
print(f"{out} ({out.stat().st_size // 1024} KB)")
