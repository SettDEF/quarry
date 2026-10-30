#!/usr/bin/env bash
# Photograph quarry without touching the screen you are using.
#
#   tools/shoot.sh out.png                       # the wall, as it opens
#   tools/shoot.sh out.png --query family:video --view 0
#   tools/shoot.sh out.png --view 0 --call "app videoHold 120000" --call "app detach"
#   tools/shoot.sh out.png --probe app videoBar  # …and print a probe with it
#
# WHY THIS EXISTS
#
# UI work has to be looked at, and looking at it must not steal the display of
# somebody who is playing a game on it. This runs the app on a private Xvfb —
# its own HOME, its own prefs, no window manager — drives it over the IPC probes
# and writes a PNG. Nothing it draws can reach the real screen.
#
# It talks to whatever daemon QUARRY_SOCK points at, or the running one.
set -u

out=""; waits=14; screen="1920x1200x24"; disp=":77"
query=""; view=""; probe=""; calls=(); keephome=""

usage() { sed -n '2,20p' "$0" | sed 's/^# \?//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)  usage ;;
        --query)    query="$2"; shift 2 ;;
        --view)     view="$2"; shift 2 ;;
        --call)     calls+=("$2"); shift 2 ;;
        --probe)    probe="$2 $3"; shift 3 ;;
        --home)     keephome="$2"; shift 2 ;;
        --wait)     waits="$2"; shift 2 ;;
        --screen)   screen="$2"; shift 2 ;;
        --display)  disp="$2"; shift 2 ;;
        -*)         echo "unknown option: $1" >&2; usage 2 ;;
        *)          out="$1"; shift ;;
    esac
done
[[ -n "$out" ]] || usage 2
command -v Xvfb >/dev/null || { echo "Xvfb is not installed" >&2; exit 3; }
command -v import >/dev/null || { echo "imagemagick (import) is not installed" >&2; exit 3; }

root="$(cd "$(dirname "$0")/.." && pwd)"
# --home reuses a prepared one, for state that has to survive between shots —
# which lens is switched on, what a layout has been told to show.
home="${keephome:-$(mktemp -d "${TMPDIR:-/tmp}/quarry-shoot.XXXXXX")}"
mkdir -p "$home/.config/quarry" "$home/.cache" "$home/.local/share"
# The palette and the fonts, so it looks like your quarry rather than a default
# theme; its own prefs, so it cannot write the ones a running quarry is watching.
[[ -f "$home/.config/quarry/prefs.json" ]] || printf '{"mature":true,"videoSound":false}' > "$home/.config/quarry/prefs.json"
ln -sfn "$HOME/.cache/quarry" "$home/.cache/quarry" 2>/dev/null || true
ln -sfn "$HOME/.local/share/fonts" "$home/.local/share/fonts" 2>/dev/null || true
mkdir -p "$home/.local/state/quickshell/user/generated"
ln -sf "$HOME/.local/state/quickshell/user/generated/material_colors.scss" \
       "$home/.local/state/quickshell/user/generated/" 2>/dev/null || true

Xvfb "$disp" -screen 0 "$screen" >/dev/null 2>&1 &
xpid=$!
cleanup() { kill "${app:-}" 2>/dev/null; sleep 1; kill "$xpid" 2>/dev/null; [[ -n "$keephome" ]] || rm -rf "$home"; }
trap cleanup EXIT
sleep 2

env -u WAYLAND_DISPLAY DISPLAY="$disp" LIBGL_ALWAYS_SOFTWARE=1 HOME="$home" \
    qs -p "$root/shell.qml" >/dev/null 2>&1 &
app=$!
sleep "$waits"
pid=$(pgrep -P "$app" -x qs 2>/dev/null); pid=${pid:-$app}

# Unquoted on purpose: an IPC call is "target method arg…", and the caller
# writes it as one string. Its answer is printed — a call that failed silently
# is how you end up photographing a state you never actually reached.
say() { echo "  $1 → $(qs ipc --pid "$pid" call $1 2>&1 | head -1)"; }
[[ -n "$query" ]] && { say "catalog query $query"; sleep 5; }
[[ -n "$view"  ]] && { say "app view $view"; sleep 6; }
for c in ${calls+"${calls[@]}"}; do say "$c"; sleep 2; done

DISPLAY="$disp" import -window root "$out" 2>/dev/null
[[ -n "$probe" ]] && qs ipc --pid "$pid" call $probe 2>&1 | head -c 400 && echo
echo "wrote $out"
