#!/usr/bin/env bash
# Launch quarry from this checkout, the way the installed /usr/bin/quarry
# launches the packaged copy: bring the daemon up if it is not already, then
# start the UI.
#
# This is what the user-level desktop entry points at until the package is
# installed with pacman.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
sock="${QUARRY_SOCK:-${XDG_RUNTIME_DIR:-/tmp}/quarry/sock}"

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
if [[ ! -S "$sock" ]]; then
    setsid "$here/tools/daemon.sh" --quiet >/dev/null 2>&1 &
fi

# Same flags as the installed /usr/bin/quarry, so a desktop action behaves the
# same whether you are running the checkout or the package.
query=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --query) query="${2:-}"; shift 2 ;;
        --kind)  query="kind:${2:-}"; shift 2 ;;
        *) break ;;
    esac
done

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

if $running && qs -c quarry ipc call app open >/dev/null 2>&1; then
    [[ -n "$query" ]] && qs -c quarry ipc call app query "$query" >/dev/null 2>&1 || true
    exit 0
fi

export QUARRY_QUERY="$query"
exec qs -c quarry "$@"
