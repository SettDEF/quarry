#!/usr/bin/env bash
# Render the native board to a PNG without touching anyone's desktop or data.
#
#   tools/board-demo.sh out.png <images-dir> [seconds] [prefs-json] [ui-state]
#
# ui-state opens menus and dialogs a hidden window cannot be clicked into —
# e.g. "select,menu" or "help" (see demo_state in board/src/main.rs).
#
#   tools/board-demo.sh /tmp/board.png ~/Pictures/ref 8 '{"library":true,"minimap":true}'
#
# Everything is private to one throwaway directory:
#   - its own quarryd, on its own socket, with its own catalogue (HOME is
#     redirected, so the real ~/.local/state/quarry is never opened)
#   - its own board prefs, so the person's board.json is never rewritten
#   - its own X server (Xvfb), so no window appears on any real screen and
#     nothing can take keyboard or mouse focus
#
# The daemon is niced: seeding decodes thumbnails, and a machine someone is
# using should not feel it.
set -euo pipefail

out="${1:?usage: board-demo.sh out.png <images-dir> [seconds] [prefs-json]}"
images="${2:?images dir}"
wait_s="${3:-8}"
prefs="${4:-}"
export QUARRY_BOARD_DEMO="${5:-}"

root="$(cd "$(dirname "$0")/.." && pwd)"
bin="${CARGO_TARGET_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/quarry/targets}/release"
work="$(mktemp -d "${TMPDIR:-/tmp}/board-demo.XXXXXX")"
mkdir -p "$work/home/.config/quarry"
chmod 700 "$work"
export HOME="$work/home"
unset XDG_STATE_HOME XDG_CACHE_HOME XDG_CONFIG_HOME
# A unix socket path must fit in 108 bytes, which a scratch directory often
# does not; the socket gets its own short private directory.
sockdir="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/qbd.XXXXXX")"
export QUARRY_SOCK="$sockdir/sock"

[[ -n "$prefs" ]] && printf '%s\n' "$prefs" > "$HOME/.config/quarry/board.json"

cleanup() {
    [[ -n "${daemon:-}" ]] && kill "$daemon" 2>/dev/null || true
    wait 2>/dev/null || true
    rm -rf "$sockdir"
}
trap cleanup EXIT

setsid nice -n 19 "$bin/quarryd" --socket "$QUARRY_SOCK" --fixture "$root/fixtures/sample.json" --quiet \
    >"$work/quarryd.log" 2>&1 < /dev/null &
daemon=$!
for _ in $(seq 50); do [[ -S "$QUARRY_SOCK" ]] && break; sleep 0.1; done
[[ -S "$QUARRY_SOCK" ]] || { echo "quarryd did not start: $work/quarryd.log" >&2; exit 1; }

python3 - "$QUARRY_SOCK" "$images" <<'PY'
import json, os, socket, sys
sock, images = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX); s.connect(sock); f = s.makefile("rwb")
n = 0
def call(m, p):
    global n; n += 1
    f.write((json.dumps({"t": "req", "id": n, "m": m, "p": p}) + "\n").encode()); f.flush()
    while True:
        msg = json.loads(f.readline())
        if msg.get("t") == "res" and msg.get("id") == n:
            if not msg.get("ok", True): raise SystemExit(f"{m}: {msg.get('error')}")
            return msg.get("p", {})

files = sorted(os.path.join(dp, x) for dp, _, fs in os.walk(images) for x in fs
               if x.lower().endswith((".png", ".jpg", ".jpeg", ".webp")))[:12]
call("boards", {"action": "create", "name": "Creatures"})
call("boards", {"action": "create", "name": "Lighting studies"})
x, y, z = 0.0, 0.0, 1
for i, path in enumerate(files):
    item = call("adopt", {"path": path})["item"]
    w = 300.0
    h = w * (item.get("h") or 3) / (item.get("w") or 4)
    if i and i % 4 == 0:
        x, y = 0.0, y + 300.0
    call("boards", {"action": "place", "name": "Creatures", "id": item["id"],
                    "x": x, "y": y, "w": w, "h": h, "z": z,
                    "angle": -6.0 if i == 2 else 0.0, "hflip": i == 5})
    x += w + 28.0; z += 1
call("boards", {"action": "container", "name": "Creatures", "container": 0,
                "x": -24, "y": 272, "w": 1360, "h": 360, "label": "Inked"})
call("boards", {"action": "view", "name": "Creatures", "x": -260, "y": -150, "z": 0.72})
print(f"seeded {len(files)} pictures")
PY

xvfb-run -a -s "-screen 0 1280x820x24" env -u WAYLAND_DISPLAY LIBGL_ALWAYS_SOFTWARE=1 bash -c '
    "$1" > "$2/board.log" 2>&1 &
    app=$!
    sleep "$3"
    import -window root "$4"
    kill "$app" 2>/dev/null
    wait "$app" 2>/dev/null || true
' _ "$bin/quarry-board" "$work" "$wait_s" "$out"

echo "wrote $out · logs in $work"
