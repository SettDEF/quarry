#!/usr/bin/env bash
# Launch quarry for development WITHOUT disturbing whatever is on screen.
#
#   tools/dev-run.sh            headless: no window anywhere; prints the pid
#   tools/dev-run.sh --live     a real window, for when you are at the desk
#   tools/dev-run.sh --stop     stop the instance this script started
#
# Then talk to it by pid, never by config name:
#
#   qs ipc --pid "$(cat "$pidfile")" call app probe
#
# WHY THIS CHANGED
#
# This used to install three Hyprland window rules at runtime —
# no_initial_focus, `workspace 9 silent` and float — matched on the title
# `^quarry$`. The comment defended them because they "vanish on the next
# compositor reload". That was the problem, not the defence: until a reload,
# they applied to EVERY quarry window, including the ones the person using this
# machine opened themselves, which silently landed on workspace 9 with no focus.
# It looked like quarry had stopped opening.
#
# It also killed every running `qs -c quarry` before starting, which closed
# whatever quarry they had open.
#
# Headless removes the need for any of it. With WAYLAND_DISPLAY and DISPLAY unset
# the process has no route to the compositor at all, so a window cannot appear,
# cannot take focus, and cannot land on anyone's workspace.
set -euo pipefail

state="${XDG_RUNTIME_DIR:-/tmp}/quarry-dev"
pidfile="$state/pid"
mkdir -p "$state"

stop_ours() {
    # Only the pid THIS script recorded. Pattern matching over command lines
    # (pkill -f, ps|grep) also matches this script and kills its own shell, and
    # would find the user's quarry as readily as ours.
    if [[ -f "$pidfile" ]]; then
        local pid
        pid=$(cat "$pidfile")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            # Wait for it to actually go. Returning while it is still exiting
            # lets the next launch race the old instance for the same config.
            for _ in $(seq 30); do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.1
            done
        fi
        rm -f "$pidfile"
    fi
}

mode="${1:-headless}"
case "$mode" in
    --stop)
        stop_ours
        exit 0
        ;;
    --live)
        stop_ours
        # A plain launch, because a person asked for a window they can see.
        # Still no rules: whatever this opens should behave like any other app.
        setsid qs -c quarry >"$state/log" 2>&1 < /dev/null &
        ;;
    headless|--headless)
        stop_ours
        # A private HOME too: without it the test writes prefs.json, and the
        # quarry the user has open watches that file and resizes itself to
        # match. `-p` because `-c quarry` is looked up under $HOME.
        mkdir -p "$state/home"
        setsid env -u WAYLAND_DISPLAY -u DISPLAY QT_QPA_PLATFORM=offscreen HOME="$state/home" \
            qs -p "$(cd "$(dirname "$0")/.." && pwd)/shell.qml" >"$state/log" 2>&1 < /dev/null &
        ;;
    *)
        sed -n '2,10p' "$0"
        exit 2
        ;;
esac

echo $! > "$pidfile"
echo "quarry pid $(cat "$pidfile") · log $state/log"
echo "probe it: qs ipc --pid $(cat "$pidfile") call app probe"
