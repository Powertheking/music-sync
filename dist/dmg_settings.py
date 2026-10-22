# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Daniele Mazzanti
# Impostazioni per dmgbuild (vedi make_dmg in build_app.sh).
# Variabili passate con -D: app, readme, background
import os.path

app = defines["app"]  # noqa: F821
readme = defines["readme"]  # noqa: F821

format = "UDZO"
compression_level = 9
filesystem = "HFS+"

files = [app, readme]
symlinks = {"Applications": "/Applications"}

background = defines["background"]  # noqa: F821
# finestra più alta del contenuto: niente scorrimento anche con la barra di stato
window_rect = ((200, 120), (640, 470))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 112
text_size = 13
icon_locations = {
    os.path.basename(app): (160, 150),
    "Applications": (480, 150),
    os.path.basename(readme): (320, 300),
}
