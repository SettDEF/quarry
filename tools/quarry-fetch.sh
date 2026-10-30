#!/usr/bin/env bash
# quarry-fetch — fill a folder with wallpapers, through quarry's daemon.
#
# A DROP-IN FOR fetch_reddit.sh.
#
# Same four arguments, same two things on stdout, same exit codes — so a shell
# that already knows how to page through one source can page through
# twenty-one without learning anything new:
#
#   quarry-fetch <query> <sort> <after> <dest>
#
#   query  — anything the query bar accepts: "space", "kind:wallpaper w>=3440",
#            "source:wikimedia video". A bare word is a search, as it is there.
#   sort   — new | large | wide | random | relevance. Reddit's names (hot, top,
#            rising) are accepted and mapped, so an existing caller's sort
#            cycle keeps working rather than erroring.
#   after  — the cursor: an offset into the result. "" starts at the beginning.
#   dest   — destination root; files land in $dest/quarry/<query-slug>/.
#
# stdout:
#   AFTER=<offset>   — empty when the query is exhausted AND the sources are
#   <path>           — one line per file newly written
#
# exit: 0 ok · 2 bad args · 3 daemon unreachable · 4 nothing matched
#
# WHY THIS EXISTS. Reddit is one site with an OAuth dance and a 403 for anyone
# without it; quarry already holds a catalogue crawled from twenty-one sources,
# knows how to page them, dedupes by perceptual hash, and renders to a size.
# The fetching mechanism does not need to know any of that — it needs a folder
# with pictures in it.
set -uo pipefail

[ $# -lt 4 ] && { echo "usage: $0 <query> <sort> <after> <dest>" >&2; exit 2; }
QUERY=$1
SORT=$2
AFTER=$3
DEST=$4

sock="${QUARRY_SOCK:-${XDG_RUNTIME_DIR:-/tmp}/quarry/sock}"
# How many to bring back per call. Matches the Reddit fetcher's page feel
# without asking the sources for a hundred images at once.
limit="${QUARRY_FETCH_LIMIT:-24}"

# The size written to disk. A wallpaper folder wants wallpapers, not originals
# that may be 16000px wide — but the caller may disagree, so it is one variable.
width="${QUARRY_FETCH_WIDTH:-3840}"
height="${QUARRY_FETCH_HEIGHT:-2160}"

command -v socat >/dev/null || { echo "socat is required" >&2; exit 3; }

# ── the daemon, started if it is not there ──────────────────────────────────
#
# Same on-demand rule the launcher uses: it comes up in a few milliseconds, so
# nothing has to keep it alive, and a fetch that fails because a background
# service was not running is a bad reason to fail.
if [ ! -S "$sock" ]; then
    here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
    if [ -x /usr/bin/quarryd ]; then
        setsid /usr/bin/quarryd --quiet >/dev/null 2>&1 &
    elif [ -x "$here/tools/daemon.sh" ]; then
        setsid "$here/tools/daemon.sh" --quiet >/dev/null 2>&1 &
    fi
    for _ in $(seq 1 200); do [ -S "$sock" ] && break; sleep 0.05; done
fi
[ -S "$sock" ] || { echo "no quarry daemon at $sock" >&2; exit 3; }

# One connection carries the whole conversation: `queryId` refers to the
# daemon's current result, so a query and the fetch that follows it have to be
# in the same session to mean anything.
ask() { printf '%s\n' "$@" | socat -t 60 - "UNIX-CONNECT:$sock" 2>/dev/null; }

# Reddit's sort names, and quarry's. Accepting both is what makes this a
# drop-in rather than a rewrite of the caller.
case "${SORT%%\?*}" in
    hot|rising|best|relevance|"") sortToken="" ;;
    new)                          sortToken="sort:new" ;;
    top)                          sortToken="sort:large" ;;
    wide)                         sortToken="sort:wide" ;;
    random|shuffle)               sortToken="sort:random" ;;
    *)                            sortToken="sort:${SORT%%\?*}" ;;
esac

offset=${AFTER:-0}
case "$offset" in (*[!0-9]*|"") offset=0 ;; esac

# A bare word means "wallpapers about this", which is what a wallpaper fetcher
# is for — but a query that already says what it wants is left alone.
case "$QUERY" in
    *kind:*|*source:*|*family:*) full="$QUERY $sortToken" ;;
    *)                           full="$QUERY kind:wallpaper $sortToken" ;;
esac
full=$(printf '%s' "$full" | sed 's/  */ /g; s/^ //; s/ $//')

slug=$(printf '%s' "$QUERY" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//')
[ -n "$slug" ] || slug="everything"
outdir="$DEST/quarry/$slug"
mkdir -p "$outdir"

json_escape() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }
q=$(json_escape "$full")

# ── ask, and crawl if the catalogue has run out ─────────────────────────────
frames="{\"t\":\"req\",\"id\":1,\"m\":\"query\",\"p\":{\"q\":$q}}
{\"t\":\"req\",\"id\":2,\"m\":\"items\",\"p\":{\"queryId\":0,\"offset\":$offset,\"limit\":$limit}}"
answer=$(ask "$frames")

count=$(printf '%s' "$answer" | python3 -c '
import json, sys
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    p = d.get("p") or {}
    if "count" in p:
        print(p["count"]); break
else:
    print(0)
')

# A SHORT PAGE IS THE SIGNAL, NOT AN EMPTY ONE.
#
# Crawling only when the catalogue was completely exhausted meant a query the
# catalogue barely knew — two matches for "space" out of 44,000 rows — returned
# those two and stopped, which reads as "there is nothing" rather than as "I
# have not looked yet". Anything short of a full page is a reason to go and ask
# the sources.
available=$(( ${count:-0} - offset ))
if [ "$available" -lt "$limit" ]; then
    ask "{\"t\":\"req\",\"id\":1,\"m\":\"more\",\"p\":{\"q\":$q,\"pages\":2}}" >/dev/null
    answer=$(ask "$frames")
fi

ids=$(printf '%s' "$answer" | python3 -c '
import json, sys
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    p = d.get("p") or {}
    for item in p.get("items", []):
        print(item["id"])
')

[ -z "$ids" ] && { echo "AFTER="; exit 4; }

# ── write the files ─────────────────────────────────────────────────────────
#
# `export` renders through quarry's own pipeline — smart crop, never upscaled,
# never overwriting an existing file — so what lands in the folder is a
# wallpaper rather than whatever shape the source happened to hold.
written=0
{
    n=0
    for id in $ids; do
        n=$((n + 1))
        idj=$(json_escape "$id")
        printf '{"t":"req","id":%d,"m":"export","p":{"id":%s,"recipe":{"width":%s,"height":%s,"fit":"cover","gravity":"smart","format":"png","quality":95,"radius":0,"background":"#000000ff"},"path":"%s/{slug}-{w}x{h}.{ext}"}}\n' \
            "$n" "$idj" "$width" "$height" "$outdir"
    done
} > /tmp/quarry-fetch-$$.frames

paths=$(socat -t 120 - "UNIX-CONNECT:$sock" < /tmp/quarry-fetch-$$.frames 2>/dev/null | python3 -c '
import json, sys
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    if d.get("ok") and (d.get("p") or {}).get("path"):
        print(d["p"]["path"])
')
rm -f /tmp/quarry-fetch-$$.frames

written=$(printf '%s' "$paths" | grep -c . || true)

# The cursor moves by what was ASKED for, not by what was written: a row that
# failed to export is still a row we have passed, and not moving would fetch it
# again forever.
asked=$(printf '%s' "$ids" | grep -c . || true)
if [ "${asked:-0}" -gt 0 ]; then
    echo "AFTER=$((offset + asked))"
else
    echo "AFTER="
fi
[ -n "$paths" ] && printf '%s\n' "$paths"

exit 0
