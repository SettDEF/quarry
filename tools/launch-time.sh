#!/usr/bin/env bash
# How long from running `quarry` to a window you can see — measured, not felt.
#
#   tools/launch-time.sh          # one cold launch
#   tools/launch-time.sh 5        # best of five
#
# Prints three numbers, because "it takes three seconds" can mean three
# different things and they have different fixes:
#
#   config   — the QML finished loading
#   window   — the window is mapped on screen (this is "it opened")
#   content  — the first tiles have been drawn (this is "it is usable")
set -uo pipefail
runs="${1:-1}"
sock="${QUARRY_SOCK:-${XDG_RUNTIME_DIR:-/tmp}/quarry/sock}"

for run in $(seq 1 "$runs"); do
    for pid in $(pgrep -x qs 2>/dev/null); do
        tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q -- "-c quarry" && kill "$pid" 2>/dev/null
    done
    while hyprctl clients -j 2>/dev/null | grep -q '"title": "quarry"'; do sleep 0.02; done

    log=$(mktemp)
    t0=$(date +%s%N)
    setsid quarry > "$log" 2>&1 &

    config=""; window=""
    for _ in $(seq 1 2000); do
        [ -z "$config" ] && grep -q "Configuration Loaded" "$log" 2>/dev/null &&
            config=$(( ($(date +%s%N) - t0) / 1000000 ))
        [ -z "$window" ] && hyprctl clients -j 2>/dev/null | grep -q '"title": "quarry"' &&
            window=$(( ($(date +%s%N) - t0) / 1000000 ))
        [ -n "$config" ] && [ -n "$window" ] && break
        sleep 0.01
    done

    content=""
    for _ in $(seq 1 1000); do
        tiles=$(qs -c quarry ipc call perf report 2>/dev/null |
            python3 -c 'import json,sys; print(json.load(sys.stdin).get("tilesReady",0))' 2>/dev/null)
        if [ -n "$tiles" ] && [ "$tiles" -gt 0 ] 2>/dev/null; then
            content=$(( ($(date +%s%N) - t0) / 1000000 )); break
        fi
        sleep 0.02
    done

    echo "run $run: config ${config:-?}ms · window ${window:-?}ms · content ${content:-?}ms"
    rm -f "$log"
done
