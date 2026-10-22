#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Daniele Mazzanti
#
# Pubblica una nuova versione di Music Sync su GitHub Releases, da cui l'app
# installata scarica gli aggiornamenti.
#
#   ./release.sh 1.0.1 "Novità: ..."
#
# Serve: modifiche già committate, certificato "Music Sync Signing" nel Portachiavi
# (stesso certificato di sempre, o gli aggiornamenti verranno rifiutati), gh autenticato.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
V="${1:?Uso: ./release.sh <versione> \"<novità>\"}"
NOTES="${2:-}"

[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Versione non valida: $V (es. 1.0.1)"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Ci sono modifiche non committate."; exit 1; }
security find-certificate -c "Music Sync Signing" >/dev/null 2>&1 ||
    { echo "Manca il certificato \"Music Sync Signing\" nel Portachiavi."; exit 1; }
[ -z "$(git tag -l "v$V")" ] || { echo "La versione v$V esiste già."; exit 1; }

if [ "$(tr -d '[:space:]' < VERSION)" != "$V" ]; then
    echo "$V" > VERSION
    git commit -q -m "Versione $V" VERSION
fi

./build_app.sh --standalone
git tag -a "v$V" -m "Music Sync $V"
git push -q origin HEAD "v$V"
gh release create "v$V" "build/Music Sync.dmg" --title "Music Sync $V" \
    --notes "${NOTES:-Music Sync $V}"
echo "Pubblicata v$V: le app installate la vedranno al prossimo avvio."
