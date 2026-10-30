#!/usr/bin/env bash
# Talk to quarryd from a terminal. One frame per invocation:
#
#   tools/proto.sh hello
#   tools/proto.sh query '{"kind":"wallpaper"}'
#   tools/proto.sh items '{"queryId":1,"offset":0,"limit":3}'
set -euo pipefail
sock="${QUARRY_SOCK:-${XDG_RUNTIME_DIR:-/tmp}/quarry/sock}"
# Several frames go down ONE connection, which matters: `queryId` refers to the
# daemon's current result, so a query and the items fetch that follows it have
# to be in the same session to be meaningful.
#
#   tools/proto.sh hello
#   tools/proto.sh query '{"kind":"wallpaper"}' items '{"queryId":1,"limit":2}'
frames=""
id=0
while [ $# -gt 0 ]; do
    id=$((id + 1))
    method="$1"
    params="{}"
    case "${2:-}" in
        "{"*) params="$2"; shift ;;
    esac
    shift
    frames="${frames}$(printf '{"t":"req","id":%d,"m":"%s","p":%s}' "$id" "$method" "$params")
"
done
printf '%s' "$frames" | socat -t 40 - "UNIX-CONNECT:$sock"
