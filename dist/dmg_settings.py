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
window_rect = ((200, 120), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 112
text_size = 13
icon_locations = {
    os.path.basename(app): (160, 200),
    "Applications": (480, 200),
    os.path.basename(readme): (320, 330),
}
