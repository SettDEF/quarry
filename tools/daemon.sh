#!/usr/bin/env bash
# Start quarryd for development, picking the fastest binary that exists.
#
# THIS USED TO RUN THE DEBUG BUILD, ALWAYS.
#
# For a daemon that decodes images, resizes them, hashes them and runs SQL, an
# unoptimised build is not "a bit slower" — it is the difference between a
# thumbnail in 40ms and one in half a second, paid on every tile. It was the
# binary behind the app for as long as this script has existed.
#
# So: release if it has been built, the installed package if not, and debug
# only as a last resort — with a line saying which, because "why is it slow"
# should never again be a question you cannot answer by reading the log.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# Only ask cargo where its target directory is if cargo is actually here.
# Launched from an application menu the PATH is /usr/local/bin:/usr/bin, with no
# cargo and no jq — and paying for two failed process spawns before falling back
# to the installed binary is pure latency on the one launch that is already the
# slowest.
targets=""
if command -v cargo >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    targets=$(cargo metadata --format-version 1 --no-deps \
        --manifest-path "$here/quarryd/Cargo.toml" 2>/dev/null | jq -r .target_directory || true)
fi

pick=""
label=""
if [[ -n "$targets" && -x "$targets/release/quarryd" ]]; then
    pick="$targets/release/quarryd"; label="release build"
elif [[ -x /usr/bin/quarryd ]]; then
    pick="/usr/bin/quarryd"; label="installed package"
elif [[ -n "$targets" && -x "$targets/debug/quarryd" ]]; then
    pick="$targets/debug/quarryd"; label="DEBUG build — expect it to be slow"
else
    echo "no quarryd binary: run 'cargo build --release' in quarryd/" >&2
    exit 1
fi

# Only ours, and only by exact name: `pkill -f quarryd` matches this script's
# own command line, which is how it used to kill the shell that started it.
for pid in $(pgrep -x quarryd 2>/dev/null || true); do kill "$pid" 2>/dev/null || true; done

echo "[quarry] daemon: $label ($pick)" >&2

# The fixture is only read when the catalogue is empty, so passing it costs
# nothing on a machine that has one — and seeds a machine that does not.
exec "$pick" --fixture "$here/fixtures/sample.json" "$@"
