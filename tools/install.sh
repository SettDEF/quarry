#!/usr/bin/env bash
# Build quarry and install it with pacman, so updates and removal go through the
# package manager like everything else on the system.
#
#   tools/install.sh              # build, then install with pacman
#   tools/install.sh --build      # build the package only
#   tools/install.sh --enable     # also enable the daemon at login
#
# Re-running it after a `git pull` rebuilds and upgrades in place: pacman sees a
# newer pkgrel and replaces the installed copy, so nothing is ever left behind
# in /usr the way `make install` leaves things.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$here"

build_only=false
enable_service=false
for arg in "$@"; do
    case "$arg" in
        --build)  build_only=true ;;
        --enable) enable_service=true ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

for tool in makepkg pacman cargo; do
    command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 1; }
done

# A stale package from a previous build would be installed by the glob below.
rm -f quarry-*.pkg.tar.zst

# -f overwrites an existing build, -c cleans up $srcdir afterwards. The Rust
# build honours CARGO_TARGET_DIR from makepkg, so it does not fight the
# development target directory.
makepkg -fc

# Ask makepkg which file it wrote rather than guessing from the directory, and
# skip any debug package explicitly.
#
# `ls -t | head -1` looks equivalent and is not: makepkg writes the debug
# package last, so the newest file is quarry-debug, and installing that gives
# you symbols with no binary and no .desktop — which is exactly what happened.
package=""
while IFS= read -r candidate; do
    [[ "$candidate" == *-debug-* ]] && continue
    [[ -f "$candidate" ]] && package="$candidate" && break
done < <(makepkg --packagelist)

[[ -n "$package" ]] || { echo "makepkg produced no installable package" >&2; exit 1; }
echo "built: $package"

if $build_only; then
    echo "install it with:  sudo pacman -U $package"
    exit 0
fi

# --needed is deliberately absent: this is always a rebuild of the same version
# during development, and pacman must replace it rather than skip it.
sudo pacman -U --noconfirm "$package"

# Verify rather than assume. An install that "succeeded" without putting the
# launcher and the desktop entry on disk is the failure this script already had
# once, and it is silent unless something checks.
missing=()
for required in /usr/bin/quarry /usr/bin/quarryd /usr/share/applications/quarry.desktop; do
    [[ -e "$required" ]] || missing+=("$required")
done
if (( ${#missing[@]} )); then
    echo "install did not land: ${missing[*]}" >&2
    echo "the user-level entry has been left in place" >&2
    exit 1
fi

# A user-level entry from tools/install-user.sh shadows the packaged one, and
# would keep launching the checkout after the package is installed. Remove it.
user_desktop="${XDG_DATA_HOME:-$HOME/.local/share}/applications/quarry.desktop"
if [[ -f "$user_desktop" ]]; then
    rm -f "$user_desktop"
    command -v update-desktop-database >/dev/null &&
        update-desktop-database "$(dirname "$user_desktop")" || true
    echo "removed the user-level desktop entry; the packaged one now applies"
fi

if $enable_service; then
    systemctl --user daemon-reload
    systemctl --user enable --now quarryd.service
    echo "daemon enabled at login: systemctl --user status quarryd"
fi

cat <<'NOTE'

Installed. Launch it from your app menu, or:

    quarry

The daemon starts on demand; to have it running from login instead:

    systemctl --user enable --now quarryd.service

To bind it to a key in Hyprland, add to ~/.config/hypr (lua config):

    hl.bind({ mods = "SUPER", key = "P", dispatcher = hl.dsp.exec_cmd("quarry") })

NOTE
