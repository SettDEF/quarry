#!/usr/bin/env bash
# quarry-rows — a page of the catalogue, shaped like a Wallhaven API response.
#
#   quarry-rows <query> <page> [limit]
#
# Prints one JSON object:
#
#   { "data": [ { id, title, path, thumbs: { small, original }, colors, kind } ],
#     "meta": { "current_page": N, "last_page": M, "total": T } }
#
# WHY THAT SHAPE. The wallpaper picker this feeds already parses exactly this —
# it was written against wallhaven.cc/api/v1/search and does `curl <url>` into a
# JSON handler. Emitting the same object means the swap is one command string
# and no parser changes: the dedupe, the pagination, the palette glow and the
# "has more" logic all keep working.
#
# It is also the faster half of the deal. The old path fetched remote thumbnails
# over the network on every scroll; these come from quarry's thumbnail cache as
# local files, already sized, already decoded once.
set -uo pipefail

[ $# -lt 2 ] && { echo '{"data":[],"meta":{"last_page":1}}'; exit 2; }
QUERY=$1
PAGE=${2:-1}
LIMIT=${3:-24}

case "$PAGE"  in (*[!0-9]*|"") PAGE=1 ;; esac
case "$LIMIT" in (*[!0-9]*|"") LIMIT=24 ;; esac
offset=$(( (PAGE - 1) * LIMIT ))

sock="${QUARRY_SOCK:-${XDG_RUNTIME_DIR:-/tmp}/quarry/sock}"
# The tile size the picker draws at. One rung of quarry's ladder, so this is a
# cache hit rather than a resize.
thumb_size="${QUARRY_ROWS_THUMB:-640}"

if [ ! -S "$sock" ]; then
    here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
    if [ -x /usr/bin/quarryd ]; then
        setsid /usr/bin/quarryd --quiet >/dev/null 2>&1 &
    elif [ -x "$here/tools/daemon.sh" ]; then
        setsid "$here/tools/daemon.sh" --quiet >/dev/null 2>&1 &
    fi
    for _ in $(seq 1 200); do [ -S "$sock" ] && break; sleep 0.05; done
fi
[ -S "$sock" ] || { echo '{"data":[],"meta":{"last_page":1},"error":"no daemon"}'; exit 3; }

command -v socat >/dev/null || { echo '{"data":[],"meta":{"last_page":1},"error":"socat missing"}'; exit 3; }

python3 - "$sock" "$QUERY" "$PAGE" "$LIMIT" "$offset" "$thumb_size" <<'PY'
import json, socket, sys

sock_path, query, page, limit, offset, thumb_size = sys.argv[1:7]
page, limit, offset, thumb_size = int(page), int(limit), int(offset), int(thumb_size)

def talk(frames):
    """One connection for the whole exchange.

    `queryId` refers to the daemon's current result, so the query and the fetch
    that follows it have to share a session to mean anything.
    """
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(120)
    s.connect(sock_path)
    s.sendall(("\n".join(json.dumps(f) for f in frames) + "\n").encode())
    buf = b""
    out = []
    want = len(frames)
    while len(out) < want:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if line.strip():
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    s.close()
    return out

def payload(frames, key):
    for msg in talk(frames):
        p = msg.get("p") or {}
        if key in p:
            return p
    return {}

result = payload([
    {"t": "req", "id": 1, "m": "query", "p": {"q": query}},
], "count")
total = result.get("count", 0)

# A short page means the catalogue has not been asked to look yet — crawl the
# live sources, then ask again. Without this a query nobody has run returns the
# handful of rows that happened to be there and looks like an empty site.
if total - offset < limit:
    talk([{"t": "req", "id": 1, "m": "more", "p": {"q": query, "pages": 2}}])
    result = payload([{"t": "req", "id": 1, "m": "query", "p": {"q": query}}], "count")
    total = result.get("count", 0)

items = payload([
    {"t": "req", "id": 1, "m": "query", "p": {"q": query}},
    {"t": "req", "id": 2, "m": "items", "p": {"queryId": 0, "offset": offset, "limit": limit}},
], "items").get("items", [])

# Thumbnails in one call rather than one per row: the daemon fetches what it is
# missing in parallel and answers with local paths for everything it has.
ready = {}
if items:
    # The key is "thumbs", not "ready" — getting it wrong is silent: every row
    # falls back to the source's own remote thumbnail and the page still
    # renders, just over the network, which is the whole cost this avoids.
    ready = payload([
        {"t": "req", "id": 1, "m": "thumbs",
         "p": {"ids": [i["id"] for i in items], "size": thumb_size}},
    ], "thumbs").get("thumbs", {})

def as_url(path):
    return "file://" + path if path and not path.startswith(("http", "file://")) else path

data = []
for item in items:
    local = ready.get(item["id"], "")
    data.append({
        "id": item["id"],
        # The picker shows this under the image; a booru id is not a title, so
        # fall back to the source rather than to an empty caption.
        "title": item.get("title") or item.get("slug") or item.get("source", ""),
        "path": item.get("url", ""),
        "thumbs": {
            "small": as_url(local) or item.get("thumb", ""),
            "original": item.get("sample") or item.get("url", ""),
        },
        # Quarry stores one dominant colour where Wallhaven gives five; the
        # picker slices to five, so one is a shorter list, not a broken one.
        "colors": [item["dominant"]] if item.get("dominant") else [],
        "kind": "vid" if item.get("family") == "video" else "pic",
        "source": item.get("source", ""),
        "width": item.get("w", 0),
        "height": item.get("h", 0),
    })

last_page = max(1, -(-total // limit)) if total else page
print(json.dumps({
    "data": data,
    "meta": {"current_page": page, "last_page": last_page, "total": total},
}))
PY
