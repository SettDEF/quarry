#!/usr/bin/env bash
# A quarry you can break.
#
# Opens a REAL window — its own daemon, its own catalogue, its own config — so
# the app can be clicked through without touching the one you actually use.
# Nothing it does reaches ~/.local/state/quarry, ~/.config/quarry or the daemon
# your own window is talking to.
#
#   tools/test-window.sh                 # empty catalogue, seeded from the fixture
#   tools/test-window.sh wallhaven,bing  # …and crawl a page from these first
#   tools/test-window.sh --keep          # reuse the last test catalogue
#   tools/test-window.sh --stop          # close it and its daemon
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
state="${QUARRY_TEST_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/quarry-test}"
sockdir="${XDG_RUNTIME_DIR:-/tmp}/quarry-test"
binary="${QUARRYD:-${XDG_CACHE_HOME:-$HOME/.cache}/quarry/targets/release/quarryd}"

stop() {
    [[ -f "$state/pids" ]] && while read -r pid; do kill "$pid" 2>/dev/null; done < "$state/pids"
    rm -f "$state/pids"
    echo "test window stopped"
}

case "${1:-}" in
    --stop) stop; exit 0 ;;
    --keep) keep=1; shift ;;
    *) keep=0 ;;
esac

stop 2>/dev/null
[[ $keep -eq 0 ]] && rm -rf "$state"
mkdir -p "$state/home/.config/quarry" "$state/home/.cache" "$state/state/quarry" "$sockdir"

# The palette and the fonts are read, never written: the test window looks like
# the real one without owning any of it.
mkdir -p "$state/home/.local/state/quickshell/user/generated" "$state/home/.local/share"
ln -sf "$HOME/.local/state/quickshell/user/generated/material_colors.scss" \
       "$state/home/.local/state/quickshell/user/generated/" 2>/dev/null
ln -sfn "$HOME/.local/share/fonts" "$state/home/.local/share/fonts" 2>/dev/null
# The desktop's own wallpaper switcher, so "set as wallpaper" behaves here the
# way it does in the real window rather than failing on a missing script.
mkdir -p "$state/home/.config/quickshell"
ln -sfn "$HOME/.config/quickshell/ii" "$state/home/.config/quickshell/ii" 2>/dev/null

export QUARRY_SOCK="$sockdir/sock"
XDG_STATE_HOME="$state/state" XDG_CACHE_HOME="$state/home/.cache" \
    setsid nice -n 19 "$binary" --socket "$QUARRY_SOCK" --quiet \
    > "$state/quarryd.log" 2>&1 < /dev/null &
echo $! > "$state/pids"
for _ in $(seq 60); do [[ -S "$QUARRY_SOCK" ]] && break; sleep 0.1; done
[[ -S "$QUARRY_SOCK" ]] || { echo "the test daemon did not start: $state/quarryd.log" >&2; exit 1; }

# Something to look at, when asked for.
if [[ -n "${1:-}" ]]; then
    for source in ${1//,/ }; do
        printf '{"t":"req","id":1,"m":"search","p":{"source":"%s","q":"","page":1}}\n' "$source" \
            | timeout 90 socat - "UNIX-CONNECT:$QUARRY_SOCK" > /dev/null 2>&1 \
            && echo "seeded from $source"
    done
fi

# Restart it once something has been crawled: a daemon that started on an empty
# catalogue is serving the built-in fixture, and would keep serving that instead
# of the rows just fetched.
if [[ -n "${1:-}" ]]; then
    while read -r pid; do kill "$pid" 2>/dev/null; done < "$state/pids"
    sleep 1
    XDG_STATE_HOME="$state/state" XDG_CACHE_HOME="$state/home/.cache" \
        setsid nice -n 19 "$binary" --socket "$QUARRY_SOCK" --quiet \
        >> "$state/quarryd.log" 2>&1 < /dev/null &
    echo $! > "$state/pids"
    for _ in $(seq 60); do [[ -S "$QUARRY_SOCK" ]] && break; sleep 0.1; done
fi

HOME="$state/home" QUARRY_SOCK="$QUARRY_SOCK" setsid qs -p "$root/shell.qml" \
    > "$state/app.log" 2>&1 < /dev/null &
echo $! >> "$state/pids"
sleep 2
echo "test window up — daemon $QUARRY_SOCK, logs in $state"
echo "stop it with: $0 --stop"
