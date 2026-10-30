#!/usr/bin/env bash
# /usr/bin/quarry — open the gallery, optionally straight onto a query.
#
#   quarry                              the whole catalogue
#   quarry --kind wallpaper             one kind of thing
#   quarry --query "kind:avatar animated"   any query the bar accepts
#   quarry wallpaper --random [--source konachan] [--query Q] [--path P] [--apply]
#                                       one random picture, saved whole; prints the path
#   quarry term [QUERY]                 the catalogue in this terminal (quarry term --help)
#
# The launcher's desktop actions are these flags, which is why they exist: a
# second launch should land on what you asked for, not on a blank gallery.
set -euo pipefail

share="/usr/share/quarry"
sock="${QUARRY_SOCK:-${XDG_RUNTIME_DIR:-/tmp}/quarry/sock}"

# ── quarry term: browse, search and play inside a terminal ──────────────────
if [[ "${1:-}" == term ]]; then
    shift
    exec /usr/lib/quarry/quarry-term "$@"
fi

# ── quarry wallpaper --random: one request to the daemon, no window ──────────
# For the shell's "Random wallpaper" buttons, the launcher and keybinds alike.
if [[ "${1:-}" == wallpaper ]]; then
    shift
    random=0 source="" q="" path="" apply=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --random) random=1; shift ;;
            --source) source="${2:-}"; shift 2 ;;
            --query)  q="${2:-}"; shift 2 ;;
            --path)   path="${2:-}"; shift 2 ;;
            --apply)  apply=1; shift ;;
            -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
            *) echo "quarry wallpaper: unknown option $1" >&2; exit 2 ;;
        esac
    done
    (( random )) || { echo "quarry wallpaper: only --random exists so far" >&2; exit 2; }
    if [[ ! -S "$sock" ]]; then
        systemctl --user start quarryd 2>/dev/null || true
        for _ in $(seq 40); do [[ -S "$sock" ]] && break; sleep 0.1; done
    fi
    [[ -S "$sock" ]] || { echo "quarry wallpaper: the daemon is not running ($sock)" >&2; exit 1; }
    req=$(jq -cn --arg s "$source" --arg q "$q" --arg p "$path" \
        '{t: "req", id: 1, m: "random", p: ({} + (if $s != "" then {source: $s} else {} end)
            + (if $q != "" then {q: $q} else {} end) + (if $p != "" then {path: $p} else {} end))}')
    # One connection held open until our answer (a crawl can take a while), then closed.
    answer=""
    coproc DAEMON { socat - UNIX-CONNECT:"$sock" 2>/dev/null; }
    printf '%s\n' "$req" >&"${DAEMON[1]}"
    while IFS= read -r -t 120 line <&"${DAEMON[0]}"; do
        if jq -e 'select(.t == "res" and .id == 1)' >/dev/null 2>&1 <<<"$line"; then
            answer="$line"
            break
        fi
    done
    kill "$DAEMON_PID" 2>/dev/null || true
    [[ -n "$answer" ]] || { echo "quarry wallpaper: no answer from the daemon" >&2; exit 1; }
    if [[ $(jq -r .ok <<<"$answer") != true ]]; then
        echo "quarry wallpaper: $(jq -r '.err // "failed"' <<<"$answer")" >&2
        exit 1
    fi
    file=$(jq -r .p.path <<<"$answer")
    echo "$file"
    if (( apply )); then
        switchwall="$HOME/.config/quickshell/ii/scripts/colors/switchwall.sh"
        [[ -x "$switchwall" ]] || { echo "quarry wallpaper: no $switchwall to apply it with" >&2; exit 1; }
        exec "$switchwall" --image "$file"
    fi
    exit 0
fi

query=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --query) query="${2:-}"; shift 2 ;;
        --kind)  query="kind:${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) break ;;
    esac
done

# Already running? Hand the query over and raise it, rather than starting a
# second copy that would fight over the same IPC socket.
# TWO THINGS THIS USED TO GET WRONG.
#
# It probed `qs -c quarry` but launched `qs -p .../shell.qml` — different
# instance identities, so the probe could not find what the launcher itself had
# started. And it tested the EXIT CODE, which `qs ipc call` sets to 0 even for
# an unknown method, so "an instance answered" and "the window opened" were
# indistinguishable. A closed-but-running instance therefore swallowed every
# launch: quarry printed nothing and returned in 33ms.
#
# Same identity for both now, and the ANSWER is what decides — `app open`
# returns "open" only when a window is actually on screen.
# WHICH COPY OF THE APP THIS OPENS.
#
# There are two, and until now the answer depended on how you started it:
# `quarry` ran the packaged QML in /usr/share, while `qs -c quarry` ran whatever
# ~/.config/quickshell/quarry points at. On a machine where that is a symlink to
# a checkout — which is how this is developed — the menu entry and the terminal
# opened different applications, and a UI change needed a package install before
# the launcher could see it.
#
# A user config wins when there is one. That is the rule everywhere else in
# quickshell, and it means the packaged copy is the fallback, not the authority.
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/quarry"
if [[ -f "$config_dir/shell.qml" ]]; then
    qs_id=(qs -c quarry)
else
    qs_id=(qs -p "$share/qml/shell.qml")
fi
# IS ONE ALREADY RUNNING? ASK THE PROCESS TABLE FIRST.
#
# The IPC probe below starts a whole second `qs` process to ask — 34ms of
# launching an application in order to find out whether to launch an
# application, paid on every cold start where the answer is always "no". A look
# at the process table costs about a millisecond and answers the common case.
#
# It is not sufficient on its own: a running instance whose window is closed
# still needs the IPC round trip to be raised. So this only SKIPS the probe when
# there is provably nothing to talk to.
running=false
for pid in $(pgrep -x qs 2>/dev/null); do
    if tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q -- "-c quarry"; then
        running=true
        break
    fi
done

if $running && [[ "$("${qs_id[@]}" ipc call app open 2>/dev/null)" == "open" ]]; then
    if [[ -n "$query" ]]; then
        "${qs_id[@]}" ipc call app query "$query" >/dev/null 2>&1 || true
    fi
    exit 0
fi

# The daemon holds the catalogue, does the crawling and owns the image pipeline.
# One check, not two: if the systemd unit is running then the socket is there.
# It starts in about 4 ms, which is why nothing needs to keep it alive.
# THE DAEMON STARTS ALONGSIDE THE WINDOW, NOT BEFORE IT.
#
# This used to start the daemon and then wait for its socket — up to two
# seconds, in fifty-millisecond steps — before the UI was even launched. The
# daemon comes up in about 70ms, so the wait was mostly the polling
# granularity, and all of it was time with nothing on screen.
#
# Both start together now. The window is drawing while the daemon binds, and
# the client connects the moment it does: see the first-second retry in
# services/Client.qml, which exists precisely so this order is safe.
# Through the systemd unit when there is one, so a later `systemctl restart`
# (the stale-build bar's button) reaches the daemon that is actually running;
# an unmanaged one made every restart fail against its lock. `--no-block`
# keeps this as fast as the bare start was.
if [[ ! -S "$sock" ]]; then
    systemctl --user start --no-block quarryd 2>/dev/null \
        || { setsid /usr/bin/quarryd --quiet >/dev/null 2>&1 & }
fi

export QUARRY_QUERY="$query"
exec "${qs_id[@]}" "$@"
