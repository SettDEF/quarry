#!/usr/bin/env bash
# quarry board — the reference canvas, in its own window.
#
#   quarry-board                 # open the last board used
#   quarry-board "Colour study"  # open (or start) a named one
#
# Deliberately NOT single-instance, unlike `quarry`: two boards side by side is
# a reasonable thing to want while drawing, and the daemon is the shared state
# so they cannot disagree about what is on them.
set -euo pipefail

# A checkout's build wins when QUARRY_BOARD_BIN points at one; otherwise the
# packaged binary.
bin="${QUARRY_BOARD_BIN:-/usr/lib/quarry/quarry-board}"
if [[ ! -x "$bin" ]]; then
    echo "quarry-board: $bin is missing — reinstall quarry" >&2
    exit 1
fi

# The board lives in the catalogue, so it needs the daemon. Starting it here
# rather than failing means opening a board from the app menu works on a fresh
# login, when nothing has started quarryd yet.
if ! pgrep -x quarryd >/dev/null 2>&1; then
    if command -v quarryd >/dev/null 2>&1; then
        setsid quarryd >/dev/null 2>&1 < /dev/null &
        # Enough for the socket to exist; the board also offers to reconnect.
        for _ in $(seq 20); do
            [[ -S "${QUARRY_SOCK:-${XDG_RUNTIME_DIR:-/tmp}/quarry/sock}" ]] && break
            sleep 0.05
        done
    fi
fi

exec "$bin" "$@"
