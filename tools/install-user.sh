#!/usr/bin/env bash
# Put quarry in the application menu WITHOUT root, running from this checkout.
#
# For trying it and for development. `tools/install.sh` installs the real
# package with pacman and removes what this script wrote, so the two never
# shadow each other.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
icons="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"
mkdir -p "$apps" "$icons"

install -m644 "$here/packaging/quarry.svg" "$icons/quarry.svg"

# Same entry as the package, with EVERY Exec pointing at the checkout.
#
# The anchor used to be `^Exec=quarry$`, which rewrote the main entry and left
# the five desktop actions — Wallpapers, Avatars, Icons, Banners, Surprise me,
# the menu you get from right-clicking the dock icon — still saying
# `Exec=quarry --kind wallpaper`. So clicking the icon opened the checkout and
# right-clicking it opened the installed package: the same split this script
# exists to avoid, hiding one line lower down the file.
sed "s|^Exec=quarry\b|Exec=$here/tools/quarry-dev.sh|" \
    "$here/packaging/quarry.desktop" > "$apps/quarry.desktop"
chmod 644 "$apps/quarry.desktop"

# Menus read a cache, and a fresh .desktop file is invisible until it is
# rebuilt — which is exactly the "it isn't in my applications" failure.
command -v update-desktop-database >/dev/null && update-desktop-database "$apps" || true
command -v gtk-update-icon-cache >/dev/null && \
    gtk-update-icon-cache -qtf "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor" 2>/dev/null || true

echo "installed for this user:"
echo "  $apps/quarry.desktop  ->  $here/tools/quarry-dev.sh"
echo "  $icons/quarry.svg"
echo
echo "It should appear in the launcher as \"quarry\" straight away."
