# Not-finished backlog — the video player's control bar

Round 1, 2026-09-18. Angle: **the bar as a control surface** (layout, hierarchy,
ergonomics) plus the correctness sweep that came with reading the file.

## Measured, before and after

The complaint was "the timeline is too short". It is measurable: the scrubber's
width as a share of the bar it sits in, taken from `app videoBar` on a real
1244px video pane.

| | before | after |
|---|---|---|
| scrubber width | 84 px | 1016 px |
| share of the bar | 13 % | 86 % |
| visible track | 12 px (XS) | 18 px (S) |
| bar | 642 × 56, sized to its contents | 1180 × 92, sized to the pane |
| a 10:50 clip | 7.7 s per pixel | 0.6 s per pixel |

The cause was not the breakpoints. `implicitWidth: min(pane - 32, bar.implicitWidth + 28)`
sized the pill to its own contents, so the scrubber's `Layout.fillWidth` had
nothing to fill and sat at its 80px floor no matter how wide the pane was.

## Done this round

- Timeline moved to a row of its own at the full width of the bar; the bar takes
  its width from the pane.
- Track up a weight (XS → S); volume stays XS, so the two no longer read alike.
- Buttons regrouped: transport + sound on the left, what the clip is FOR on the
  right (frame grab, speed, loop, quality), with a real gap between the groups.
- Hit targets unified at 36 (40 for play) — they were 30/32/34/40.
- The frame grab no longer disappears first as the pane narrows; generic
  transport goes before the one tool a gallery's player has.
- Speed chip keeps an outline at 1× so it reads as a control, not a caption.
- Both time labels use one colour role; the duration was using the outline role.
- Shortcut hints added to the loop and speed tooltips.
- **Every player shortcut was dead** — `s`, `,`, `.`, `l`, `]` — because the pane
  asked for focus and the viewer above it held focus. The key map moved into
  `handleKey()`, which the viewer now offers each key first. Verified: `s` writes
  a frame file, `space` pauses.
- Quality switching kept its place only in its comment: the seek ran before the
  new source existed. The position is remembered and applied when the file loads.
- Frame grab guarded on `ready` (it could write a fully transparent PNG) and
  against the item changing mid-grab (it could save the new clip under the old
  clip's name).
- Volume slider no longer loses its binding to `Prefs.videoVolume` on first drag.
- `synchronous = FULL` on the catalogue — see "needs deciding" below.
- New probes and assertions: `app videoBar`, `app key`, `app videoHold`,
  `app resize`, and four checks in `tools/qml-test.sh` that fail if the timeline
  drops below 60% of the bar or the player stops receiving its keys.

## Found while measuring, not asked for

- **Search is dead on the live catalogue.** Every word answers 0 while the empty
  query answers 15,174. The FTS index is damaged: `SELECT … FROM item_fts WHERE
  item_fts MATCH 'girl'` returns "database disk image is malformed". Same
  corruption event; a fresh catalogue fixes it.
- **The navigation rail has no groups** for the same reason — `source_tally()`
  runs a query that touches the damaged trees, gets an error, and returns an
  empty list, so families, kinds and sources are all empty behind a full library.
- **A failed query still answers "ok, 0 rows".** `catalog.rs` prints the failure
  to stderr under a comment saying a query that cannot run "must say so rather
  than answer 0 items" — and then answers 0 items. The client cannot tell a
  broken index from an empty catalogue. Worth a `damaged` field in the response.
- **Pornhub is healthy**: a search for "blonde" fetched 30 and added 29, nothing
  unusable, more pages available. But its posters arrive 320×180 tagged
  `kind: wallpaper`, so the viewer offers "Save the original, full size" for a
  thumbnail nobody can use as a wallpaper.

## Round 2 — angle: failure behaviour

Two reviewers swept the daemon and the app for failures that display as normal
states. Verified and fixed:

- **The daemon now says when the catalogue is the problem.** `Db` latches any
  corrupt-class error the read helpers used to swallow (`damage()`), and
  `hello`, `query` and `sources` all carry it. A new strip in the app
  (`DamagedBar.qml`) says so and offers a restart; the empty state now reads
  "The catalogue is damaged" instead of "Nothing matches".
- **`backup_user_data()` was completely silent** — both failure arms threw the
  reason away, on the one file that holds boards and collections. It logs, it
  latches, and the same strip says "your boards are not being saved".
- **The filter panel told people to wait** ("No sources have reported yet")
  while the facet call was failing. It shows `facetError` now.
- **"Search every source" failed silently** — the report was written and read by
  nothing but the CLI probe. Failures toast.
- **A failed thumbnail looked like a loading one** in the wall, grid and compact
  list, for ever. `ThumbImage.failed` was computed and ignored everywhere except
  the detail view; all three layouts now draw a broken-picture mark.
- **The export sheet left a stale preview on screen** when a render failed, next
  to a crop box that no longer described it. It clears and says so.
- **History said "Nothing here yet"** when the call had failed. It says which.
- `records()` failures on a page no longer answer with silence against a count
  that was already sent.

Not fixed, reported as-is: the `let Ok(..) else { return Vec::new() }` shape
still covers ~9 read helpers in `db.rs` (boards, collections, slots, distinct,
hashed/unhashed rows); the latch catches the corrupt-class case for all of them,
but a non-corrupt failure there is still silent. `"thumbs"` batch warming drops
per-id failures with no count. `"more"` reports which sources failed but not why.

## Round 3 — per-layout options (asked for, not found)

Each layout now keeps its own answer to what a tile shows: kind badges, video
length, hover outline, the caption and its title/detail lines, and which of the
eight quick actions appear as buttons on a hovered picture — plus its own sort,
applied to the query on switch. Edited from "What the wall shows" at the bottom
of the layout menu; stored per layout id, defaults per layout (the compact list
ships without the caption it already prints in the row). The compact list only
offers what a row can honour, rather than toggles that would do nothing.

Measured: wall defaults to export+open with a caption; compact to
export/keep/copy/hide with none. A toggle survives a restart. Switching to a
layout with a saved sort rewrites the query (`forest` → `forest sort:new`).

## Ranked next moves

- `[impact: high | effort: M | risk: med]` **The catalogue is corrupting on unclean
  shutdowns.** Verified today: `quick_check` on the *fresh* catalogue reports cells
  pointing at pages 4219–4223 of a 3149-page file, after one reboot. `synchronous
  = FULL` is now set, which closes the mechanism, but it has not yet survived a
  real crash to prove it. Worth a deliberate test: kill the machine mid-crawl in a
  VM and check the file.
- `[impact: high | effort: S | risk: low]` **Install the new package.** Every
  protection written last night — quarantine a wrecked catalogue, restore boards
  and collections from the JSON mirror, one daemon per catalogue — is in the built
  package, not in the `/usr/bin/quarryd` currently running.
- `[impact: med | effort: M | risk: low]` **Hover-scrub preview.** Now that the
  timeline is full width, hovering it could show the frame under the cursor.
  mpv's thumbfast model (decode on demand, throttled) fits what `grabFrame` already
  does; YouTube's sprite-sheet model does not fit a gallery.
- `[impact: med | effort: M | risk: low]` **`IconButton` is not keyboard reachable**
  — a bare Rectangle + MouseArea, no focus, no `Accessible.name`. Affects every
  button in the app, not just this bar.
- `[impact: med | effort: S | risk: low]` **`loadQualities()` never retries** if the
  daemon was not connected when the pane opened, so that clip has no quality menu
  for the rest of its life.
- `[impact: low | effort: S | risk: low]` **Frame grabs overwrite silently** — the
  path is `<id>-<ms>.png` with no uniqueness check, against the project's own
  "never silently overwrite an export" rule on the Rust side.
- `[impact: low | effort: S | risk: low]` **`bufferProgress` is meaningless for local
  files**, so the buffered band shows something arbitrary for a file that is
  entirely on disk.
- `[unverified]` `skip_previous`/`skip_next` for single-frame stepping borrows the
  "previous/next track" glyphs, and the viewer uses the same vocabulary for
  prev/next picture at the screen edges. Worth a second opinion, not a fix.
- `[unverified]` Seek-on-release depends on `onPressedChanged` running before the
  `Binding` restores `value`. Documented as a hazard in both files, never proven
  either way; needs a rapid click-release repro.

## Angles

Covered: the bar as a control surface, correctness of the player's own code,
prior art (players and libraries), real-runtime measurement of the layout.

Open: failure behaviour (what the bar does when the stream stalls or the daemon
dies mid-clip), scale (a 3-hour clip, a 4K source, a 30fps scrub on a slow disk),
first-run and empty states, repeat use (does anything leak across a hundred
opens), someone else's eyes (accessibility, naming, discoverability).

## Prior art looked at

YouTube, mpv's uosc and ModernZ, VLC, Jellyfin, Plex, IINA, Netflix. The
convention they all share is the one that was missing: **the scrub bar gets its
own strip**, decoupled from the buttons. uosc separates the visible line width
from the interactive height (2px vs 40px); `StyledSlider` already did this
(12px visible, 33px grabbable), so that part needed nothing.

Libraries: nothing worth adopting. media-chrome, Vidstack and Plyr are all MIT
but are web components with no QML path — read as specifications, not code. No
maintained, permissively-licensed QML scrub bar exists that does more than bind a
slider to a position, which is the naive pattern this file had already moved past.
Haruna (KDE, Qt/QML) is GPL: technique only, and not copied.

## Still not pushed down (was task #52)

Text, tags, author, kind, minimum size, exact ratio, video and adult all reach the
source now. These are still filtered locally, each for a reason:

```
- [impact: low | effort: S | risk: low ] `w<=` / `h<=` maxima. Most APIs express a
    floor and no ceiling, so a maximum can only be applied to what came back.
- [impact: low | effort: M | risk: med ] `ratio>=` / `ratio<=`. Only `ratio:` exactly
    is pushed; the comparisons have no server-side equivalent anywhere checked.
- [impact: low | effort: S | risk: low ] `ext:`. Several boorus can express it and
    none is asked — a cheap win if someone wants one.
- [impact: —   | effort: — | risk: —  ] Negations, deliberately. These APIs say
    "must have", not "must not", and a half-applied negation is worse than none.
    `-nsfw` is the single exception and it is handled.
```

## A tile that is empty and should not be

`Perf.starved` counts tiles that are on screen, have a row, have a path and are
drawing nothing — live, not cumulative. "Empty tiles" has been reported four times
and every counter looked healthy each time, because they all record EVENTS and a
tile that was never asked to load raises none. Read it in `perf report` as
`tilesStarved`; a healthy wall sits at zero.
