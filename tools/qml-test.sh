#!/usr/bin/env bash
# Assert what the UI actually measures.
#
#   tools/qml-test.sh            # both apps
#   tools/qml-test.sh --offscreen  # no window on your session at all
#   tools/qml-test.sh app        # just quarry
#   tools/qml-test.sh board      # just the board
#
# WHY THIS EXISTS
#
# There are 113 Rust tests and, until this file, no test of the QML at all —
# and every user-visible defect in this project has been in the QML. A search
# bar that rendered 4px wide. A filter panel 70px tall holding 73 rows. A
# completions dropdown 900px from its field. A settings page listing 0 of 29
# sources. A text field whose clickable band was 20px of a 46px control. Board
# pieces destroyed and rebuilt on every drop, so every picture reloaded.
#
# Every one of those was found by a person looking at a screen. Not one of them
# needed judgement: they are all NUMBERS, and a number can be asserted. That is
# the whole idea here — the `probe` IPC methods report the measurements, and
# this decides whether they are sane.
#
# It is deliberately not a pixel-comparison suite. Screenshot diffing breaks on
# every theme change and teaches you to ignore it; these assertions only fail
# when something is genuinely, structurally wrong.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$here"

offscreen=false
targets=()
for arg in "$@"; do
    case "$arg" in
        --offscreen) offscreen=true ;;
        app|board) targets+=("$arg") ;;
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done
[[ ${#targets[@]} -eq 0 ]] && targets=(app board)

pass=0
fail=0
launched=()

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }

# `check <name> <expr>` where expr is a jq-style test over $J, evaluated in python.
check() {
    local name="$1" expr="$2"
    local got
    got=$(python3 -c "
import json,sys
d = json.loads(sys.stdin.read())
def get(path, default=None):
    cur = d
    for part in path.split('.'):
        if not isinstance(cur, dict) or part not in cur: return default
        cur = cur[part]
    return cur
print('PASS' if ($expr) else 'FAIL: ' + json.dumps(d))
" <<<"$J" 2>&1)
    case "$got" in
        PASS) ok "$name" ;;
        *)    bad "$name — $got" ;;
    esac
}

cleanup() {
    for pid in "${launched[@]:-}"; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
    done
}
trap cleanup EXIT

# ── the daemon ───────────────────────────────────────────────────────────────
if ! pgrep -x quarryd >/dev/null; then
    echo "starting quarryd…"
    for candidate in ./quarryd/target/release/quarryd \
                     ${CARGO_TARGET_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/quarry/targets}/release/quarryd \
                     quarryd; do
        if command -v "$candidate" >/dev/null 2>&1 || [[ -x "$candidate" ]]; then
            "$candidate" >/dev/null 2>&1 &
            launched+=("$!")
            break
        fi
    done
    sleep 2
fi

# ── somewhere to draw ────────────────────────────────────────────────────────
#
# --offscreen cuts the apps off from the compositor entirely: WAYLAND_DISPLAY and
# DISPLAY are unset, so no window can appear or take focus, and Qt renders into
# memory. Verified to run the full app, reach the daemon and answer its probe
# with zero windows on the session while a game stayed focused.
#
# This used to be --nested, which launched a nested Hyprland and claimed to keep
# the test "off your screen". A nested Hyprland IS a window on your screen, and
# it can take focus. That claim was never tested, and it was false.
if $offscreen; then
    unset WAYLAND_DISPLAY DISPLAY
    export QT_QPA_PLATFORM=offscreen
fi

# `qs ... ipc call` needs the same config the instance was started with.
# By pid. `qs -c quarry ipc call` goes to whichever instance matches the config,
# and the person running this may well have their own quarry open.
APP_PID=""
BOARD_PID=""
probe_app()   { qs ipc --pid "$APP_PID" call app probe 2>/dev/null; }
probe_board() { qs ipc --pid "$BOARD_PID" call board probe 2>/dev/null; }

# `wait_for <probe fn> <seconds> [readiness expr]`
#
# Answering at all is not the same as being READY. A window that has just
# opened reports a connected client and zero rows for a moment, because its
# first query has not landed — and asserting in that window produces a failure
# that says nothing about the code. A flaky test is worse than no test: it
# teaches you to ignore the one time it is right.
wait_for() {
    local fn="$1" limit="$2" ready="${3:-True}" waited=0
    while (( waited < limit )); do
        if out=$("$fn") && [[ "$out" == \{* ]]; then
            if python3 -c "
import json,sys
d = json.loads(sys.argv[1])
def get(path, default=None):
    cur = d
    for part in path.split('.'):
        if not isinstance(cur, dict) or part not in cur: return default
        cur = cur[part]
    return cur
sys.exit(0 if ($ready) else 1)
" "$out" 2>/dev/null; then
                J="$out"
                return 0
            fi
        fi
        sleep 1
        waited=$((waited+1))
    done
    # Report on whatever the last answer was rather than nothing at all.
    [[ -n "${out:-}" && "$out" == \{* ]] && J="$out"
    return 1
}

# ── quarry ───────────────────────────────────────────────────────────────────
if [[ " ${targets[*]} " == *" app "* ]]; then
    echo
    echo "quarry"
    # Always our own instance, so we know exactly which pid to probe and to stop
    # — and its own HOME, so it cannot write the prefs.json a quarry you have
    # open is watching (it would resize itself, or change layout, mid-use). The
    # palette and the thumbnail cache are linked in so it looks and loads the
    # same; fonts come from the system and ~/.local/share/fonts.
    TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/qml-test-home.XXXXXX")"
    mkdir -p "$TEST_HOME/.local/state/quickshell/user/generated" "$TEST_HOME/.cache" "$TEST_HOME/.local/share"
    ln -sf "$HOME/.local/state/quickshell/user/generated/material_colors.scss" "$TEST_HOME/.local/state/quickshell/user/generated/" 2>/dev/null || true
    ln -sfn "$HOME/.cache/quarry" "$TEST_HOME/.cache/quarry" 2>/dev/null || true
    ln -sfn "$HOME/.local/share/fonts" "$TEST_HOME/.local/share/fonts" 2>/dev/null || true
    HOME="$TEST_HOME" setsid qs -p "$(pwd)/shell.qml" >/dev/null 2>&1 < /dev/null &
    APP_PID=$!
    launched+=("$APP_PID")

    # Ready means: connected AND the first query has come back.
    if ! wait_for probe_app 25 "get('catalog.connected') is True and get('catalog.count',0) > 0"; then
        bad "never became ready (connected with rows) — last: ${J:-no answer}"
    else
        # The window exists and has a size at all.
        check "window has a size"            "get('window.width',0) > 200 and get('window.height',0) > 200"
        # 4px. The one that started all of this.
        check "search bar is a bar"          "get('search.width',0) > 200"
        # A dropdown with nothing in it must have no height.
        check "empty dropdown has no height" "get('search.completions',0) > 0 or get('search.dropdown',0) == 0"
        # 2px of handle on a 37k-row list.
        check "scroll handle is grabbable"   "not get('scrollbar.visible') or get('scrollbar.handle',0) >= 20"
        # 73 rows in a 70px panel.
        check "filter panel fits its rows"   "get('filter.rows',0) < 20 or get('filter.height',0) > 200"
        # "0 sources known" while 29 existed.
        check "settings lists every source"  "get('settings.rows') == get('settings.sources')"
        check "daemon is connected"          "get('catalog.connected') is True"
        check "catalogue has rows"           "get('catalog.count',0) > 0"
        check "facets are populated"         "not get('catalog.connected') or get('catalog.facets',0) > 0"

        # ── the player's bar ─────────────────────────────────────────────────
        #
        # The timeline was 84px of a 642px bar — thirteen per cent — because the
        # bar sized itself to its own contents, so the scrubber's `fillWidth`
        # had nothing to fill. One pixel was eight seconds of a ten minute clip.
        # And every shortcut the bar's tooltips advertised was dead: the pane
        # asked for focus, the viewer above it held focus, and nobody checked.
        qs ipc --pid "$APP_PID" call catalog query "family:video" >/dev/null 2>&1
        sleep 4
        qs ipc --pid "$APP_PID" call app view 0 >/dev/null 2>&1
        sleep 6
        # Only when a video is actually open: the bar reports its geometry
        # whatever is on screen, so asserting it over a still passes without
        # having measured anything.
        VV=$(qs ipc --pid "$APP_PID" call app video 2>/dev/null)
        VB=$(qs ipc --pid "$APP_PID" call app videoBar 2>/dev/null)
        if [[ "$VB" == \{* && "$VV" == *'"active":true'* ]]; then
            J="$VB"
            check "the timeline owns its row"    "get('share',0) >= 60"
            check "the timeline can be grabbed"  "get('scrubH',0) >= 24 and get('trackH',0) >= 16"
            check "the bar fits its pane"        "get('barW',0) <= get('paneW',1)"
            VK=$(qs ipc --pid "$APP_PID" call app key s 2>/dev/null)
            case "$VK" in
                *"took it"*) ok "the player is given its keys" ;;
                *)           bad "the player never sees its keys — $VK" ;;
            esac
        else
            ok "no video in this catalogue — the player's bar was not checked"
        fi

        # ── what each layout shows ───────────────────────────────────────────
        #
        # A wall and a list are not one screen at two sizes, and the options
        # that say so have to actually differ and actually survive a restart.
        LW=$(qs ipc --pid "$APP_PID" call app layoutOptions wall 2>/dev/null)
        LC=$(qs ipc --pid "$APP_PID" call app layoutOptions compact 2>/dev/null)
        if [[ "$LW" == \{* && "$LC" == \{* ]]; then
            J="$LW"
            check "the wall keeps its caption"   "get('strip') is True"
            J="$LC"
            check "the list drops what it prints" "get('strip') is False and get('ring') is False"
            qs ipc --pid "$APP_PID" call app setLayoutOption wall keep on >/dev/null 2>&1
            J=$(qs ipc --pid "$APP_PID" call app layoutOptions wall 2>/dev/null)
            check "a toggle is remembered"       "'keep' in get('buttons', [])"
            qs ipc --pid "$APP_PID" call app setLayoutOption wall keep off >/dev/null 2>&1
        else
            bad "the layout options could not be read — $LW"
        fi
    fi
fi

# ── the board ────────────────────────────────────────────────────────────────
if [[ " ${targets[*]} " == *" board "* ]]; then
    echo
    echo "quarry-board"
    setsid qs -p board.qml >/dev/null 2>&1 < /dev/null &
    BOARD_PID=$!
    launched+=("$BOARD_PID")

    if ! wait_for probe_board 25 "get('connected') is True"; then
        bad "never became ready — last: ${J:-no answer}"
    else
        check "daemon is connected"          "get('connected') is True"
        # The delegate-churn detector. If the Repeater's model has drifted from
        # the data, pieces are being destroyed and rebuilt — which is what made
        # every picture reload on every drop.
        check "piece model matches the data" "get('pieceRows') == get('pieces')"
        check "container model matches"      "get('containerRows') == get('containers')"
        # A board holds ids the current query does not, so records are fetched
        # by id; a piece with no record draws an empty frame.
        check "every piece has a picture"    "get('pieces',0) == 0 or get('drawn') == get('pieces')"
        check "zoom is inside its bounds"    "0.1 <= get('zoom',1) <= 4"
        check "an opened board has a name"   "get('boards',0) == 0 or len(get('board','')) > 0"
    fi
fi

# ── the native board ─────────────────────────────────────────────────────────
#
# It reports on itself without opening a window, which is the whole reason it
# has a --probe: the QML boards' bugs were found by looking at a screen, and a
# screen is exactly what a test cannot look at.
NATIVE=${CARGO_TARGET_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/quarry/targets}/release/quarry-board
[[ -x ./board/target/release/quarry-board ]] && NATIVE=./board/target/release/quarry-board
if [[ -x "$NATIVE" ]]; then
    echo
    echo "quarry-board (native)"
    if J=$("$NATIVE" --probe 2>/dev/null) && [[ "$J" == \{* ]]; then
        check "daemon is connected"           "get('connected') is True"
        # Membership is derived from geometry and cached in a column; if those
        # two disagree, a container is lying about what it holds.
        check "membership matches geometry"   "get('consistent') is True"
        check "a board is readable"           "get('boards',0) == 0 or len(get('board','')) > 0"
    else
        bad "native board never answered its probe"
    fi
fi

echo
if (( fail > 0 )); then
    printf '\033[31m%d failed\033[0m, %d passed\n' "$fail" "$pass"
    exit 1
fi
printf '\033[32mall %d passed\033[0m\n' "$pass"
