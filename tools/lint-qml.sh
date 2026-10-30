#!/usr/bin/env bash
# Check the app's WIRING, which neither the compiler nor the test suite can.
#
# WHY THIS EXISTS
# ---------------
# QML resolves names at runtime. Calling a method that does not exist raises a
# TypeError inside whatever handler you are in, aborts the rest of that handler,
# and prints where nobody is looking. Connecting nothing to a signal is not an
# error at all. Both are invisible to `cargo test` and to review, because the
# code reads correctly — the fault is in the join between two files.
#
# On 2026-09-29 five bugs were found in one day and every one of them reported
# success. Three were this shape:
#
#   * `Catalog.refresh()` did not exist. It was called in `setAdult`'s reply
#     handler, so turning the adult switch off told the daemon, threw, and never
#     re-queried — the wall kept showing adult pictures and nothing was logged.
#   * `Catalog.thumbReady` was emitted and had no listener anywhere, so a tile
#     whose thumbnail was not already cached stayed empty for good.
#   * A user copy of a shipped script shadowed the fixed one, so a fix that was
#     installed was not running.
#
# Each cost hours, and each is one grep. So: the greps, in `check()`.
#
# WHAT IT CANNOT DO
# -----------------
# It matches text. It does not know types, and it deliberately only looks at
# CALLS (`Thing.method(`) rather than property reads, because a singleton
# inherits members this cannot see and guessing there would mean false failures
# blocking a build — which is how a linter gets switched off.
#
# USAGE
#   tools/lint-qml.sh                 # report everything, exit 0
#   tools/lint-qml.sh --strict        # exit 1 on anything not in the baseline
#   tools/lint-qml.sh --baseline      # record what exists now as accepted
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
BASELINE="tools/lint-qml.baseline"
STRICT=0
WRITE=0

for arg in "$@"; do
    case "$arg" in
        --strict)   STRICT=1 ;;
        --baseline) WRITE=1 ;;
        -h|--help)  sed -n '2,36p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
    esac
done

# Everything the app actually loads. `pkg/` is makepkg's staging copy of it.
# Comments are not code, and this file's own history proves why that matters:
# the note explaining the `Catalog.refresh()` bug contains the words
# `root.refresh()`, and the first version of this tool reported it as a missing
# function — failing the build over a comment about a fixed bug. A linter that
# does that gets switched off, which is worse than not having one.
#
# awk rather than a regex: a block comment spans lines, so it needs a state
# machine. `//` inside a string (a URL) loses the rest of the line, which can
# only ever hide text, never invent a call.
strip_comments() {
    awk '
        { line = $0 }
        {
            out = ""
            while (length(line) > 0) {
                if (in_block) {
                    i = index(line, "*/")
                    if (i == 0) { line = ""; break }
                    in_block = 0; line = substr(line, i + 2); continue
                }
                b = index(line, "/*"); l = index(line, "//")
                if (b > 0 && (l == 0 || b < l)) {
                    out = out substr(line, 1, b - 1); line = substr(line, b + 2); in_block = 1; continue
                }
                if (l > 0) { out = out substr(line, 1, l - 1); line = ""; break }
                out = out line; line = ""
            }
            print out
        }
    ' "$1"
}

qml_files() {
    find modules services shell.qml extensions optional-lenses -name '*.qml' 2>/dev/null \
        | grep -v '^pkg/'
}

# `pragma Singleton` is the marker, not the root element: ten of the eighteen
# declare it and then open with something other than `Singleton {` at column 0,
# so matching the element missed nearly half of them — including Scheme, whose
# dead signal this tool was written to find.
singletons() {
    grep -l 'pragma Singleton' services/*.qml modules/common/*.qml 2>/dev/null
}

fail=0
found_now=$(mktemp)
trap 'rm -f "$found_now"' EXIT

# ── 1. calls to members that do not exist ───────────────────────────────────
#
# The `Catalog.refresh()` class. Fatal on sight: there is no baseline for this,
# because a call that cannot resolve is never intentional.
echo "== calls to members that do not exist =="
undefined=0
for file in $(singletons); do
    name=$(basename "$file" .qml)
    {
        grep -oE '^[[:space:]]*function [a-zA-Z_][a-zA-Z0-9_]*' "$file" | sed 's/.*function //'
        grep -oE '^[[:space:]]*(readonly )?property [A-Za-z0-9_<>]+ [a-zA-Z_][a-zA-Z0-9_]*' "$file" \
            | sed -E 's/.*[[:space:]]//'
        grep -oE '^[[:space:]]*property alias [a-zA-Z_][a-zA-Z0-9_]*' "$file" | sed 's/.*alias //'
        grep -oE '^[[:space:]]*signal [a-zA-Z_][a-zA-Z0-9_]*' "$file" | sed 's/.*signal //'
    } | sort -u > /tmp/lint-def.$$

    {
        # Other files calling it by name.
        qml_files | while read -r f; do strip_comments "$f"; done \
            | grep -hoE "\b$name\.[a-zA-Z_][a-zA-Z0-9_]*\(" 2>/dev/null \
            | sed "s/^$name\.//"
        # AND the singleton calling ITSELF through `root.`, which is how the bug
        # this tool exists for was actually written:
        #
        #     Prefs.showNsfw = payload && payload.adult === true;
        #     root.refresh();            <- no such function; the handler died here
        #     root.refreshSourcePrefs(); <- never ran
        #
        # Checking only `Catalog.foo(` missed it completely, because nothing
        # outside Catalog.qml ever called it. Verified by reintroducing the bug:
        # this tool reported "none" until the line below existed.
        strip_comments "$file" | grep -hoE '\broot\.[a-zA-Z_][a-zA-Z0-9_]*\(' | sed 's/^root\.//'
    } | sed 's/($//;s/(//' | sort -u > /tmp/lint-use.$$

    # Members every QML object has, which the singleton does not declare.
    printf '%s\n' objectName destroy toString valueOf hasOwnProperty >> /tmp/lint-def.$$
    sort -u -o /tmp/lint-def.$$ /tmp/lint-def.$$

    while read -r member; do
        [ -n "$member" ] || continue
        echo "  $name.$member() — called, never defined"
        qml_files | xargs grep -ln "$name\.$member(" 2>/dev/null | sed 's/^/      /'
        undefined=$((undefined + 1))
    done < <(comm -23 /tmp/lint-use.$$ /tmp/lint-def.$$)
    rm -f /tmp/lint-def.$$ /tmp/lint-use.$$
done
[ "$undefined" -eq 0 ] && echo "  none"
[ "$undefined" -gt 0 ] && fail=1

# ── 2. signals with no listener ─────────────────────────────────────────────
#
# The `thumbReady` class. Baselined rather than fatal: some of these are real
# gaps worth their own fix and some are API an extension connects at runtime,
# and neither should stop a build today. A NEW one does.
echo
echo "== signals nothing listens to =="
for file in $(singletons); do
    name=$(basename "$file" .qml)
    # Host and Extensions are the extension-facing API by design: a listener
    # arrives when an extension is enabled, so there is nothing to find here.
    case "$name" in Host|Extensions) continue ;; esac
    grep -oE '^[[:space:]]*signal [a-zA-Z_][a-zA-Z0-9_]*' "$file" 2>/dev/null | sed 's/.*signal //' \
    | while read -r sig; do
        handler="on$(printf '%s' "${sig:0:1}" | tr '[:lower:]' '[:upper:]')${sig:1}"
        # Comments stripped here too: a note that MENTIONS `onThumbReady` is not
        # a listener, and counting it as one is a false negative — the exact
        # failure this scan exists to catch.
        listener=0
        while read -r candidate; do
            [ "$candidate" = "$file" ] && continue
            if strip_comments "$candidate" | grep -q "$handler"; then listener=1; break; fi
        done < <(qml_files)
        if [ "$listener" -eq 0 ]; then
            echo "$name.$sig"
        fi
    done
done | sort -u >> "$found_now"

if [ "$WRITE" -eq 1 ]; then
    {
        echo "# Signals with no listener, accepted as of $(date +%Y-%m-%d)."
        echo "# Each is a real gap, not a false positive — see TASKS.md, round 2026-09-29."
        echo "# A signal NOT in this list failing the build is the point of the file."
        cat "$found_now"
    } > "$BASELINE"
    echo "  baseline written: $(grep -cv '^#' "$BASELINE") accepted"
    exit 0
fi

# `name # why it is accepted` — the reason is the point of the file, so it is
# stripped for the comparison and kept for the reader.
accepted=$(sed 's/#.*//' "$BASELINE" 2>/dev/null | tr -d ' \t' | grep -v '^$' | sort -u)
new=$(comm -23 "$found_now" <(printf '%s\n' "$accepted"))
if [ -z "$(cat "$found_now")" ]; then
    echo "  none"
else
    while read -r s; do [ -n "$s" ] && echo "  $s — known, in the baseline"; done <<< "$accepted"
    while read -r s; do [ -n "$s" ] && { echo "  $s — NEW, nothing connects to it"; fail=1; }; done <<< "$new"
fi

# ── 3. shipped files shadowed by a stale copy ───────────────────────────────
#
# Not a code fault and never fatal: it is a fact about THIS machine, and a build
# server has no user directory. It is here because it cost three debugging
# rounds in one day — a fix that is installed and not running looks exactly like
# a fix that does not work.
echo
echo "== user copies shadowing a shipped file =="
drift=0
for dir in scripts lenses; do
    udir="$HOME/.local/share/quarry/$dir"
    [ -d "$udir" ] || continue
    for user_copy in "$udir"/*; do
        [ -e "$user_copy" ] || continue
        base=$(basename "$user_copy")
        for shipped in "$dir/$base" "modules/lens/builtin/$base" "optional-lenses/$base"; do
            [ -e "$shipped" ] || continue
            if ! diff -rq "$shipped" "$user_copy" >/dev/null 2>&1; then
                echo "  $base — yours differs from $shipped"
                [ "$shipped" -nt "$user_copy" ] && echo "      the shipped one is NEWER; yours is what runs"
                drift=$((drift + 1))
            fi
            break
        done
    done
done
[ "$drift" -eq 0 ] && echo "  none"

echo
if [ "$STRICT" -eq 1 ] && [ "$fail" -eq 1 ]; then
    echo "FAILED — a call that cannot resolve, or a signal nobody added a listener for."
    exit 1
fi
echo "ok"
