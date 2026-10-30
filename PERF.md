# PERF.md

Append-only. Every phase re-measures the budget table from `PLAN.md`.

## Phase 0 — 2026-08-29

Fixture: 137 real items (wallhaven 24, pfps.gg 30, danbooru 20, met 11,
iconify 36, polyhaven 16) across raster / vector / model.
Window 1902×1022 on HDMI-A-1, wall layout, ~24 tiles visible.

| budget | target | measured |
|---|---|---|
| scroll | 60 fps | **60 fps** steady, in-app FrameAnimation counter |
| decode in flight | ≤ 8 | **5/8**, 206 served, queue draining |
| gate leaks | 0 | **1 reclaimed** by the watchdog — see below |
| first paint (cold `qs -c quarry`) | < 600 ms | not yet instrumented |

Not yet measured: the ×10/×100/×1000 scale-up (1.4k / 14k / 137k items) — the
harness is wired into the overflow menu, but the run needs a window nobody is
using. Next session.

### Two bugs the harness caught, both worth remembering

**The gate leaked slots.** A tile retargeted or destroyed while its load was
still queued never handed the slot back, so after `maxInFlight` recycles the
whole wall stopped loading — a screen of placeholders that looks exactly like a
network fault. Fixed in `AssetTile` (a stale start callback returns the slot
itself, and `root` is null-checked because the tile can be gone by then), plus a
watchdog in `ThumbGate` that reclaims anything in flight over 4 s and counts it.
The counter read `reclaimed 1` in this run, which is the watchdog doing its job.

**Two sources 403 hotlinked images.** `cdn.donmai.us` (danbooru thumbs) and the
Art Institute's IIIF host both refuse requests that do not come from their own
page — the AIC-User-Agent header does not help. Their metadata APIs are fine.
This is not a bug to fix in the view: it is the argument for the daemon owning
the thumbnail ladder. Until it does, those tiles show the family placeholder.

## Phase 1 — 2026-08-29

Same machine, measured over IPC with the window on an unused workspace — no
window is ever raised to run a test, because raising one steals focus from a
fullscreen game. `tools/dev-run.sh` installs `no_initial_focus` + `float` +
`workspace N silent` rules at runtime (nothing in `~/.config/hypr` is edited),
and `qs -c quarry ipc call perf scroll 5000` sweeps 20000px while `perf report`
returns frame statistics.

### The budget at 137,000 items

| | target | measured |
|---|---|---|
| scroll, 137k items, 20000px sweep | 60 fps, no frame > 32 ms | **900 frames, avg 5.01 ms, worst 11.87 ms, zero over 16.6 ms** |
| masonry placement, 137k items | — | **65 ms** once; an appended page is **1–2 ms** regardless of catalog size |
| `windowFor` (per scroll step) | — | **7 µs** at 137k (headless harness) |
| catalog index resident | — | **+19 MB** for 137k items over a 324 MB baseline |
| after a sweep decoding 1011 thumbs | — | **434 MB**, pages resident capped at 1–2 |

Baseline note: a fresh mapped window is ~324 MB on this stack before quarry does
anything, and the desktop's own `ii` shell sits at 764 MB. The `< 300 MB`
absolute figure in the original budget was not reachable by any Qt app here, so
the budget is now stated as a **delta**: the catalog must cost single-digit
megabytes per 100k rows, and resident records must be bounded by what is on
screen. Both hold.

### Three bugs the harness caught

**1. Records in memory, not ratios.** Materialising the catalog as JavaScript
objects cost **~6.8 KB an item**: 137k items took the process from 33 MB to
**965 MB with image loading switched off entirely**, so it was the records, not
the pixmaps. `Catalog` now keeps one *ratio* per item — all masonry needs, about
1 MB for 137k — and materialises full records **by page (500), keeping at most 8
pages**, evicting the rest. Same catalog: **+19 MB**. This is the measurement
that justifies the daemon owning the catalog, and it arrived before a line of
the daemon was written, which was the point of building the UI first.

**2. A binding storm.** `item: Catalog.itemAt(slot)` reads catalog state inside
a binding, so it re-ran for every tile on every frame — **201,066 lookups** in a
three-second sweep, average frame **131 ms**, worst **1053 ms**. Records are now
*assigned* on slot change instead of bound, and tile priority is quantised to the
scroll step rather than recomputed per frame: **4,122 lookups**, average frame
**5.01 ms**. A lookup counter that was itself a QML property made it worse, since
every call then notified — hot-path counters live in plain JS now.

**3. The gate leaked slots** (fixed in Phase 0, still holding: `reclaimed 0–2`
per run, and the watchdog reports rather than hides it).

### Not yet measured

Grid layout under a scripted sweep (only the wall is wired to `perf scroll`),
and cold start to first paint.

## Phase 2 — 2026-08-29

`quarryd` (Rust, tokio) now serves the catalog over the v1 protocol; the front end
reads the socket instead of the file, and falls back to the fixture when no
daemon is up.

| | measured |
|---|---|
| 137k rows of geometry over the wire | **1.1 MB** JSON (`{count, ratios[]}`) — versus ~930 MB had records been sent |
| scroll, 137k items, over the socket | 900 frames, avg **5.05 ms**, worst **11.83 ms**, **zero over 16.6 ms** |
| resident after the sweep | **427 MB** (baseline ~324 MB) |
| pages resident | 1–2 of 8, evicting as designed |
| daemon build | 8.5 s debug, 15 tests in 0.12 s |

**Transport: unix socket, not WebSocket.** Morse uses a loopback WebSocket with a
token because a plain `qml6` app has no other option. quarry runs under quickshell,
which has `Quickshell.Io.Socket`, so it uses a unix socket in
`$XDG_RUNTIME_DIR/quarry/` — mode 0700, which is the question the token was
invented to answer — and drops a framing layer from a path that carries a
megabyte per query. Written down in `PROTOCOL.md` as a deliberate divergence.

**A query landing is the one hitch left.** Parsing 1.1 MB of ratios and placing
137k slots costs ~90 ms on the UI thread — measured as a single 135 ms frame when
a sweep overlapped a query. Scrolling after it settles is clean. Chunked
placement is the fix if it ever becomes visible at realistic page sizes; at 500
rows a page it is 1–2 ms.

## Phase 3 — 2026-08-29

The query DSL, parsed in the daemon (`quarryd/src/query.rs`), with completion
served from the catalogue. 41 Rust tests, all offline.

Verified end to end through the app, over the socket:

| query | rows |
|---|---|
| `kind:wallpaper w>=1900` | 25 |
| `vector tintable` | 36 |
| `kind:avatar animated` | 6 |
| `ratio:16:9` | 14 |
| `sort:large` | 137, sorted |
| `colour:blue kind:avatar` | 49, **`unknown: colour`** reported rather than ignored |

**Two bugs the tests caught, both mine.** An assertion claimed 3440×1440 was a
banner — it is a 2.39:1 ultrawide *wallpaper*; a banner is a 3:1 strip like an X
header. And a test corpus built a square 24×24 "icon" that `normalize` had
labelled `kind: avatar`, because the helper handed it a `.png` URL. Fixed the
fixtures, not the thresholds.

**The IPC harness reported stale counts** once queries became a round trip:
`catalog query` answered with the *previous* result's count. It now returns
`queued:` and `catalog count` reads the landed result — a harness that prints a
quietly-wrong number is worse than one that prints nothing.

## Phase 6 (early) — 2026-08-29

Pulled forward because the toolkit was asked for: the scraping helpers, the
image pipeline, filter pushdown, and two real adapters.

- **`quarryd/src/scrape.rs`** — 27 helpers (HTTP with per-host rate limiting,
  disk cache, transient-only retry; regex/CSS/RSS/JSON-path parsing;
  normalisation that always fills `ratio`).
- **`quarryd/src/util.rs`** — 14 helpers (sizes, aspects, ages, hex/colour
  distance, WCAG contrast, export path templates, atomic writes).
- **`quarryd/src/image.rs`** — decode/rasterise (raster + SVG via resvg), fit,
  smart crop by entropy, rounded corners, encode, thumbnail ladder, perceptual
  hash, dominant colour, placeholder.
- **`quarryd/src/sources/`** — filter **pushdown** plus wallhaven and danbooru.

Verified live: `wallhaven` `q=forest atleast=2560x1 ratios=16x9 purity=100
sorting=date_added` → 24 fetched, 22 added, **0 filtered locally** — the source
did all the work. `danbooru` `tags=cat+rating:general` → 50 fetched, 41 added,
**9 filtered locally**, which is the `w>=1200` danbooru could not take because of
its two-tag anonymous limit. That split is the whole point of pushdown, and the
counts make it visible.

`thumb` and `export` both work end to end: a danbooru image cached locally as
WebP with its phash and dominant colour, and a 184×184 PNG written with smart
crop (52 KB), the second run landing as `(2).png` rather than overwriting.

### Bugs found, all by tests or `doctor`

1. **danbooru rejected our URLs outright.** `width:>=1920` sent raw makes its
   HTTP parser answer 500 — the tag string must be percent-encoded. Caught by a
   fixture that came back as an error page rather than JSON.
2. **danbooru times out on an unfiltered `order:`.** `order:id`, `order:id_desc`
   and `order:score` each answer 500 `ActiveRecord::QueryCanceled` alone, while
   `rating:general order:score` is fine. The adapter now only orders alongside a
   real filter, and never emits `order:id` at all since newest-first is the
   default. Found by `doctor` — the exact failure it exists to catch, since the
   app would have shown an empty gallery.
3. **`doctor` itself was pointed the wrong way**, probing wallhaven with an empty
   *relevance* query, which returns nothing and reported a working source as
   broken.
4. **Two test assertions were wrong, not the code**: an ultrawide is a wallpaper
   rather than a banner, and `west` gravity pins x, not y.
5. **Warnings: 56 → 0.** Most were toolkit not yet called; the fix was to call it
   (`search`, `doctor`, `thumb`, `export`), and the remainder carry a documented
   module-level allow with the phase that consumes them.

## Packaging — 2026-08-29

`PKGBUILD` + `tools/install.sh` build the daemon in release mode, run the test
suite as `check()`, and install through pacman so upgrades and removal work like
anything else on the system. Verified by extracting the built package and
running it from the packaged layout: `qs -p /usr/share/quarry/qml/shell.qml`
loads, and the packaged `quarryd` answers `hello` with 137 items.

Package: 3.6 MB, 39 QML files, one ELF daemon, desktop entry, icons at eight
sizes, a systemd **user** service, and `PROTOCOL.md`/`ITEM.md` under
`/usr/share/doc/quarry`.

**One build bug worth remembering:** `ring` — rustls' crypto backend — compiles C
next to its Rust, and Arch's default `-flto=auto` makes the two unlinkable
(`undefined symbol: ring_core_*`, hundreds of them). `options=('!lto')` is the
fix, and costs nothing measurable for this workload.

The QML import path works unchanged in the installed layout because quickshell
derives its `qs.` module prefix from the config root, and `Catalog`'s fixture
path is relative — `qml/../fixtures/sample.json` resolves to the packaged
fixture without a single path special-case for "installed" versus "checkout".

## Phases 5 & 7 (partial) — 2026-08-29

Export from the UI, the launcher actions, and the scroll flicker.

**The flicker is gone.** Reported as "images blinking, completely blank while
scrolling — it was in Morse too". The cause is the tile pool: one `Image` whose
`source` is reassigned when a tile is recycled clears to nothing the instant the
source changes, and stays empty until the next decode finishes. A wall of those
blinks. Tiles now hold **two layers** — the incoming picture loads into the
hidden one and they cross-fade only when it is `Ready` — and local ladder
thumbnails are `cache: true` again, since a bounded 160–1280px step is cheap to
keep and re-decoding it on every scroll-back was the other half. Measured after:
**900 frames, avg 5.0 ms, worst 8.09 ms, zero over 16.6 ms** at 18k items.
Resident 492 MB with the cache on, against ~430 MB without — the trade is
visible and worth it.

**Wallpaper targets were the wrong size.** `screen.width` is the compositor's
*logical* size: on a 2560×1600 panel at 1.67 scale it reads 1536×960, so every
wallpaper export was soft. Targets now multiply by `devicePixelRatio` —
`wallpaper-eDP-1` is 3072×1920, `wallpaper-HDMI-A-1` is 1920×1080.

**`color:` landed**, which is what the colour pipeline was always for:
`color:#424153 dist<30` returns 14 of 137 fixture rows, and the *Match my
desktop palette* button fills the bar with the live accent. wallhaven ships a
palette per row, so this costs no decoding on that source.

**Launcher actions**, the way Steam's entry offers Store and Library: Wallpapers,
Avatars, Icons, Banners and Surprise me, each `quarry --kind …` or
`quarry --query …`. A second launch hands the query to the running instance over
IPC rather than starting a rival copy.

### Bugs

1. **`FloatingWindow` has no `raise()` or `requestActivate()`** — calling them
   throws. Presenting the window can only map it; stacking belongs to the
   compositor.
2. **A known key with an unreadable value was dropped silently.** `color:blue`
   matched everything and said nothing. It is reported in `unknown` now, and an
   older test caught it by failing when `colour` stopped being an unknown key.
3. **wallhaven browsing returned zero rows.** `sorting=relevance` with an empty
   `q` matches nothing, so an unsearched browse came back empty — the same trap
   that had fooled `doctor` earlier, this time in the app.

## The scroll, properly — 2026-08-29

Reported as "images blinking, completely blank while scrolling", then "laggy
while scrolling", then "RAM grows over long scrolling". All three were real, and
two of them were caused by the same design.

### The blink was architectural, not a race

The wall drew through a **fixed pool of tiles re-pointed at new items** as the
window moved, so every visible tile changed its content on every scroll step —
and each change is a decode you can watch happen. Three rounds of patching
(double-buffered layers, path prefetch, a decode warmer ring) took a measured
125 blanks per sweep down to 7 and never to zero, while costing frames.

The fix was to stop re-pointing visible tiles: **one ListView per column**, each
virtualising its own column against a shared Flickable, `reuseItems: false`, a
screen and a half of `cacheBuffer`. Qt creates a delegate before it is looked at
and destroys it after it is left, and a tile never changes what it is.

| | pool | one ListView per column |
|---|---|---|
| visible blanks per 6 s sweep, 137 items | 13 | **0** |
| visible blanks, 13.7k items | 10 | **0** |
| RSS across three consecutive sweeps | climbed | **404 / 403 / 404 MB** |
| worst frame | 20–27 ms | **6–8 ms** |

Counting the blink directly was what made this tractable: `Perf.blanks` counts a
tile that *was* showing a picture and stops while still having an item, split
from the offscreen case so neither could hide behind the other. Frame timings
cannot see a blink — a wall can blink at a perfect 60 fps.

### The budget is the display, not 60

This panel runs at **180 Hz**: 5.56 ms a frame, not 16.6. "Average 5.0 ms" read
fine against the wrong budget while missing frames against the real one. The
harness now reports `missedBudget` against `1000 / refreshHz`; the sweep sits at
12–19 missed frames per 1080, about 1.5%.

Qt's own guidance was measured rather than assumed. Turning clipping off in the
delegates — "never enable clipping on delegates", since a clipped item cannot be
batched — moved the sweep from 18 missed frames to 12, inside the run-to-run
noise. It is a `Prefs` knob now (`tileClip`, `tileRadius`, `tileSmoothing`) so
the next person can re-measure instead of arguing.

### The lag was the daemon answering one request at a time

The renderer was idle at full frame rate while the app felt slow, which pointed
away from the UI. `serve()` read a frame, awaited the handler and wrote the
answer — so every `thumb` (a network fetch) blocked the next, and a `query`
issued mid-scroll waited behind all of them.

Requests now run concurrently, bounded by a semaphore, with `query`/`items`
still ordered per connection because one replaces the result the other reads —
a distinction discovered by breaking it: with everything concurrent, `items`
overtook its own `query`.

**Twelve cold thumbnails: 7947 ms → 1162 ms. 6.8×.**

### Endless scroll

The wall asks for the next page two screens from the bottom, and the daemon owns
the cursor per source and per query, crawling every source in parallel for one
round trip. Verified live: scrolling to the end took the catalogue from 205 to
244 rows without a click. Appended rows cost 1–2 ms to place, whatever the
catalogue already holds.

## Endless scroll, pfps.gg, and the grid — 2026-08-29

**Pages come in batches.** One page per scroll meant the wall grew by less than a
screen and immediately asked again. `more` now takes a `pages` count (default 3,
the app asks for 4) and fetches them **in parallel**, so four pages cost what the
slowest one costs: 5 pages returned 120 rows in one call where one page returned
24. Live through the app: 257 → 395 items in a single load.

**pfps.gg is a real adapter now**, not just a fixture: listing and category
pages (`/pfps/<tag>?page=N` — the site's own search is a category, which is a
better answer than a title match), plus **detail-page enrichment**. The id
triple in the CDN filename *is* the address of the item's page, so a row is
linkable without an extra request. `search q=anime` → 32 fetched, 30 added;
`enrich` on a crawled row → title, uploader, three real tags and eight related
items.

**The grid was still blinking** — 78 blanks in a sweep — because `GridView` had
`reuseItems: true`, which is the same "re-point a visible delegate" that the
wall had already been rewritten to avoid. Turning it off: **0 blanks**. It costs
some jitter (122 frames of 1080 over the 5.56 ms budget at 180 Hz, none over
16.6 ms), which is the right trade against visible flicker.

### Bugs behind "some entries are blank"

Three, all the same shape — **a mutated JavaScript object notifies nobody**:

1. `Catalog._pages` is mutated when a page lands, so `item: Catalog.itemAt(slot)`
   as a *binding* never re-ran: delegates created before their page arrived
   showed nothing for ever. Records are assigned now, with a `pageEpoch` counter
   as the one notification.
2. `SlotGeometry.colIndex` is appended in place — that is what makes a page cost
   O(added) — so the columns' `model: slots.length` never learned rows existed.
   **The wall built four tiles in total.** A `revision` counter fixes it.
3. A ListView's `contentY` cannot be *bound* to the outer Flickable: the list
   owns that property, and the binding lost, so the columns never scrolled and
   never created delegates past the first screenful. It is pushed imperatively.

Also fixed: the client now puts a **deadline on every request** and reconnects
when several expire together. A daemon restarted under a running app left the
socket looking connected while every reply vanished — no error, just a gallery
that quietly stopped filling in.

## The all-blank gallery, and memory — 2026-08-30

A screenshot of every tile empty, "loading more…" stuck on, 790 thumbnails
"served", nothing drawn. Three bugs stacked, and the first is the one that made
it permanent.

**A failed thumbnail was cached forever.** On any error the empty string was
stored against that item, so one blip — a daemon restart, a timeout — left every
tile that was loading at that moment permanently empty, and nothing ever asked
again. Failures are no longer remembered: only a row the daemon calls *broken*
(its thumbnail and its original both fetched fine and neither was an image) is
retired, and a `pageEpoch` bump nudges the visible tiles to ask again after a
transient one.

**The client never reconnected.** Two mistakes in one small timer. It fired once,
so a daemon back after more than a second was missed; and it set the socket's
`connected` false and true inside a single handler, which the property system
collapses to no change, so even that attempt did nothing. Worse, Quickshell's
`Socket` does not reopen at all once its peer is gone — setting `connected = true`
is accepted and silently does nothing. The socket is now **rebuilt** through a
Loader, retried until it works, with the handshake deferred one turn because the
`connectionStateChanged` signal arrives while `Loader.item` is still null.

Verified: connected → daemon killed (falls back to the offline fixture) → daemon
restarted → reconnects, `backend: mock`, thumbnails resume.

**The scroll ended early.** `more` was called with two hardcoded source names, so
it stopped when those two ran out while other adapters still had pages; and a
page that added nothing — duplicates, or a local filter rejecting all of it —
was treated as the end. It now asks every adapter the daemon has, and stops only
when all of them report exhausted.

### Memory over a long session

Four rounds of "load four more pages, then sweep the whole wall":

| | items | RSS |
|---|---|---|
| start | 137 | 458 MB |
| round 1 | 549 | 526 MB |
| round 2 | 549 | 534 MB |
| round 3 | 914 | 533 MB |
| round 4 | 914 | **514 MB** |

Flat: it climbs while the first screens decode and then plateaus, and it goes
*down* as often as up. The bounds that make that true are the eight resident
record pages, the 3000-entry thumbnail path cache, `cache: false` on tile
pixmaps, and delegates that are destroyed a screen and a half outside the view.

Still rough: a `more` landing mid-scroll costs a 22–36 ms frame, because the
query result and the masonry placement both land on the UI thread at once.
Scrolling between loads stays clean.

## "On launch it doesn't load" — 2026-08-30

A grid of empty cells at startup, 1156 items, `served 3447`, nothing drawn. Four
separate faults, and the measurement that finally exposed them was **counting
tiles that ever became ready** — "0 blanks" had been vacuous, because a tile
cannot blink if it never showed anything.

1. **A page that lost its race was never asked for again.** Startup changes the
   query three or four times in a few milliseconds (fixture loads, socket
   connects, a launcher action applies its query), so the first `items` request
   came back `stale queryId 5` — correctly, since the result had moved on. But
   the tiles that asked had been marked pending, nothing re-asked, and the grid
   stayed empty for ever. Queries are now debounced (40 ms) so the first page
   request is made against a query that will survive, and a stale or failed page
   bumps the epoch so the tiles ask again.

2. **A remote page landed into a grid that never looked at it.** `_store` — the
   path a page from the daemon takes — did not bump `pageEpoch`, so delegates
   created while it was in flight never re-read the catalogue. One line, and the
   difference between a full gallery and an empty one.

3. **One round trip per tile.** Ninety tiles a screen, each its own `thumb`
   request holding a network fetch: the gallery filled a handful of cells at a
   time and looked broken. The daemon now sends `thumb_local` **with the record**
   when the file is already on disk — no request at all for anything seen before
   — and a new `thumbs` method warms a whole page in one call, fetching in
   parallel.

4. **A failed thumbnail was cached as empty for ever** (see above), so any blip
   during that slow fill left those cells permanently blank.

After: **605 tiles ready, 0 errors, 0 blanks** across 865 items, 435 MB, worst
frame 22 ms during a load-and-sweep. On launch the first screen fills with no
round trips at all.

## The detail page, and the death of the ⋮ — 2026-08-30

**A real 3D view.** Opening a model now loads it: `View3D` + `RuntimeLoader`,
orbit by dragging, wheel to zoom, a turntable toggle, and framing computed from
the model's own bounds — a chandelier and a drill are not the same size in
metres. The daemon resolves Poly Haven's manifest and downloads the `.gltf`
**with everything it references** into one directory, relative paths intact
(5 files, ~700 KB), because a glTF is JSON plus a buffer plus textures and a
runtime loader can only open the complete set. Exactly one View3D exists at a
time; the wall keeps using baked thumbnails, or it would be a renderer per cell.

**The ⋮ is gone, from both places it appeared.** Exporting *is* this app, and it
was behind an overflow menu — the main verb made the least reachable thing on
the page. The detail page now shows what you would actually do as labelled
buttons: the target you used last, "Export as…", one button per monitor at that
monitor's real pixel size, copy image, copy link, source page, find similar, and
"Hide" as the only quiet, destructive one. The header's ⋮ held nothing but a
test harness, which lives in IPC where it belongs; that button is now "load more
from every source".

**The overlay was not actually modal.** A scrim over a Flickable stops clicks and
nothing else, so the wheel went straight through and scrolled the gallery behind
the picture being looked at. The wheel is taken by the overlay now and does the
obvious thing — steps through the results, one notch per picture.

Also on the page: file size and age, the source's own "more like this" strip
(from `enrich`), and every action reachable from a terminal (`app act …`) so the
page can be exercised without a pointer.

## "Bad quality?" — 2026-08-30

Yes, and twice over. Both were the same mistake: asking for a size and then not
honouring it.

**The detail view was shown a grid thumbnail.** The daemon sends `thumb_local`
with every record — the 320px ladder step tiles use — and `thumbFor` returned it
whatever size was requested, so a 320px file was stretched across a 1200px pane.
The cache told the story: 834 files at 320, exactly one at 1280. The record's
path is now only used when 320 is what was asked for, and the detail view sizes
its request to the pane in real pixels: **2048×1365 instead of 320**, six times
the pixels.

**Tiles asked in logical pixels on a 1.67× display.** A 330-wide tile is 550
actual pixels, and it was requesting a 320 step — every tile upscaled by two
thirds, on every screen with a scale factor. The ladder step is chosen from
`width × devicePixelRatio` now, in the tiles, in the wall's prefetch, and in the
per-page warm — they have to agree or the warm fetches files nothing will use.
On this machine that means 640s, and 136 of them appeared on the first sweep.

There is a one-time cost: switching steps invalidates the 320s that were already
cached, so the first pass after the change refetches. After that the cache holds
both and neither is fetched again.

## Phase 5 — the catalogue is real — 2026-08-30

Proven by the failure first: the daemon held **2,620 items**, was restarted, and
came back with **137**. Everything crawled lived only as long as the process,
because the "catalogue" was a `Vec` seeded from a fixture. That is why the status
line said `mock` for so long — honestly, as it turns out.

Now: **SQLite via `rusqlite` (bundled), WAL, migrations, FTS5.** FTS5 was
verified compiled in before anything was built on it — the Phase-0 spike item
that had never been checked.

- `item` with indices on kind, source, family, added_at, and a partial index on
  `phash` for the duplicate detection that comes next
- `item_fts` (unicode61, `prefix='2 3'`) maintained on every insert, so moving
  the text path into SQL is a query change rather than a migration
- `hidden` as its own table, so a hidden row survives a re-crawl that would
  otherwise add the same picture straight back
- the database is the store of record, memory is the working set: rows are
  written through on insert and read back once at startup, so the query language
  keeps running in Rust over a slice

Measured end to end:

| | |
|---|---|
| crawl, restart, count | **443 → 443** |
| hide, restart, re-crawl | **442 rows, 1 hidden, still hidden** |
| catalogue on disk | `~/.local/state/quarry/catalog.db`, 405 KB for 443 rows |
| backend reported | `live` (it says `mock` only without a database) |

Two smaller things fixed alongside. `size_bytes` reported 4 KB while half a
megabyte of rows sat in `catalog.db-wal`; it counts both now, and a checkpoint
runs every minute so an hour-old crawl does not depend on the next write to
become durable. And the UI has had a **Hide** button since the detail page
existed with nothing behind it — there is a `hide` method now, and it persists.

---

## The query moves into SQLite

`catalog.rs` had no SQL in it. Every query was a linear scan over every row,
held in memory, filtered in Rust — while `item_fts` was maintained on every
insert and never read once. The cost of the index was already being paid.

It reads from SQLite now. A query compiles to a `WHERE` clause, free text goes
through `item_fts MATCH`, and the answer comes back as three small columns per
row — id, ratio, hash — which is exactly what the wire protocol sends anyway.
Records are read one page at a time. Two predicates stay in Rust because
neither is a column: colour distance, and collection membership.

Measured against the real catalogue, 31,964 rows:

| | before | after |
|---|---|---|
| daemon resident, idle | **133.5 MB** | **11.5 MB** |
| resident after querying everything | — | **24 MB** |
| startup to accepting connections | proportional to the catalogue | **5 ms** |
| `kind:wallpaper` (7,356 rows) | — | **32 ms** |
| everything (31,662 rows) | — | **47 ms** |
| `sunset kind:wallpaper w>=1920` | — | **8 ms** |

The millisecond figures include `socat` and a shell round trip, and the floor
of that harness is ~8 ms — an empty result costs the same as a small one. What
the timings actually show is that the work now scales with the size of the
*answer* (serialising 31,662 ratios) rather than the size of the catalogue.

**Two engines for one grammar is the risk**, and it is not a hypothetical: the
matcher still runs, for the fixture path and for the residue a source cannot
filter server-side. A wrongly translated predicate does not throw, it quietly
answers a slightly different question. So `sql_and_the_matcher_answer_the_same_query`
runs 25 queries — every predicate that has a column, negated and combined —
through both and asserts the same row ids come back. It passed first run, which
is worth writing down honestly: the bug it exists to catch is the one that
appears six months from now when someone adds a predicate to one engine.

It did catch two things while being written. `ratio` in SQL was the column,
but the matcher falls back to `w/h` when the column is 0 — which older rows
have — so `ratio:16:9` would have answered differently depending on which
engine ran it; SQL uses the same fallback expression now. And `len()` had
quietly changed meaning from "rows you can see" to "rows on disk", which are
different numbers once anything is hidden.

### The one deliberate behaviour change

Free text used to be a substring scan; it is now a token-prefix match. That is
what an index buys, and for a query bar it is the right semantics — but the
difference is not free, and on this catalogue it was severe:

| query | substring | FTS, as first written | FTS now |
|---|---|---|---|
| `sunset` | 11 | 11 | 11 |
| `forest` | 41 | 39 | 39 |
| `cat` | 536 | 443 | 434 |
| **`girl`** | **11,102** | **754** | **10,954** |

Booru tags are written `1girl`, `2boys`, `4koma`. FTS5 matches from the start
of a word, and the start of that word is a digit — so the single most common
tag in an anime catalogue became unfindable by the word anybody would type.
The tokenizer is not wrong; the token is not the word. `index_text` now indexes
such a word twice, once as written and once with the leading digits stripped,
and the remaining 148-row gap is genuine mid-word matches (`bobcat` for `cat`)
that a prefix index is not supposed to find.

That needed schema v5, which rebuilds the text index on first open — the
existing index was built by the old rule, and it had drifted anyway: 32,261
index rows against 31,964 items, the difference being entries left behind by
deleted rows. The rebuild reads in keyset batches of 2,000 rather than all at
once (`OFFSET n` re-walks n rows, which is quadratic in the catalogue) and
costs **414 ms once, at 17.7 MB peak** — a migration must not re-create the
allocation the release exists to remove.

---

## Video, and four more sources

A picture engine that cannot open a video is one that hands back a broken tile
for a growing fraction of what the boards hold. `video` is a **family** now,
beside `raster`, `vector` and `model` — not a flag on a raster, because nothing
in the image pipeline can open one: it cannot be decoded, cropped or
re-encoded, its thumbnail is a frame rather than a resize, and applying one to
a wallpaper slot runs a different program.

The whole of it hangs on one change. `image::load` — which every other path
already went through — now recognises a video container and returns a frame
from it. Thumbnails, the perceptual hash, the dominant colour and the detail
preview all work on video with nothing else taught. Measured on a real
danbooru mp4, through the daemon: **633 ms** to fetch, poster, hash and
persist, and the row came back `1280x720, 27.63s` with a colour and a phash
like any other.

Details that are not incidental:

- **The poster is taken a tenth of the way in, not at frame zero.** The first
  frame of a video is very often black or a title card, and a wall of black
  tiles is worse than no thumbnails. The seek goes *before* `-i`, making it a
  container seek to a keyframe rather than a decode of everything up to that
  point. A clip too short to seek into falls back to the first frame rather
  than failing.
- **ffmpeg needs a seekable file**, so the bytes are spooled to a temp file and
  removed on every path out, failures included. An mp4 with its index at the
  end — which is most of them — cannot be decoded from a pipe.
- **The duration is measured, never believed.** Sources describe video badly;
  only e621 publishes a length at all. It is read by `ffprobe` at the one
  moment the daemon holds the file, and written back with the real dimensions.
- **Exported verbatim.** `fit`, `gravity` and `radius` mean nothing for
  something that moves, so the file is written through byte for byte and the
  response says `verbatim` rather than letting the caller assume a crop.
- **A moving wallpaper is `mpvpaper`, with `-p -a FULL`.** That pauses the
  video the moment anything goes fullscreen. A wallpaper that keeps decoding 4K
  behind a game is a frame rate you spent on wallpaper.
- **The GIF hover-preview is disabled for video.** `animated` is true for both,
  and `AnimatedImage` would sit there pulling a whole mp4 to draw nothing.

### The sources

| source | what it adds | verified |
|---|---|---|
| **yandex images** | an index of the whole web — no library of its own | 30/page keyless, no API: the results are JSON in the page's `data-state` |
| **wikimedia commons** | the largest CC photo library, at true original size | 40/page, 5898x3443 for the first `landscape` hit |
| **openverse** | CC and NC-licensed photography with the licence attached | 20/page (the anonymous cap — 40 is a 401) |
| **peapix** | the Bing daily, as the real 3840x2160 file | 7 rows x 14 markets, refreshed daily |
| **e621** | adult art, and the best keyless source of video | 1080p VP9 with a poster, and a published duration |
| **rule34.xxx** | adult photo and video | ships disabled, with the key it needs named |

Two of those needed the manifest format to learn something, and both were
worth it because they generalise:

**An object is a list.** MediaWiki answers with `query.pages` keyed by page id
rather than as an array — a store, not a list, which is a common shape for an
API that expects to be merged into a client-side cache. Refusing it would have
meant a hand-written adapter for a source whose mapping is otherwise eight
lines.

**Not everything is paged by number.** Peapix ignores `page` — and, measured, a
date range too: it is always the last seven days. It is not one list with
pages, it is fourteen small lists, one per Bing market. `page_values` cycles a
fixed list as the page grows, which is the right shape for any source paged by
section rather than by offset. Page one is `us` (7 new rows), page two is `jp`
(7 fetched, **2 new** — five of them are the same pictures, and the dedupe
caught it).

The Yandex adapter is the one that is not declarative, and the reason is worth
recording: **a search engine's results are only as good as the size filter you
push down**. Unfiltered, `cyberpunk city` returned 4 rows of 30 at 1920px or
wider, nearly all Pinterest re-uploads at 736px. With the bucket pushed down,
30 of 30 came back at exactly 4K, from varied hosts, all 16 tested fetchable.
Its size buckets are coarse and its exact filter (`isize=eq`) is too precise to
use — asking for exactly 3840x2160 drops the 3840x1600 ultrawide the query was
probably about — so the push-down is deliberately approximate and the residue
filter is exact.

It also fails in a way worth naming: Yandex answers a scraper it dislikes with
**a 200 and a captcha page**, which parses to zero rows and looks exactly like
"no results for that query". Two string searches tell them apart, and the
adapter raises "yandex asked for a captcha — it is rate-limiting this address"
instead of shrugging. Tested from this machine it does not gate quarry's honest
User-Agent: 30 results, no captcha.

---

## A rate limit was deleting pictures

Verifying the new sources turned up something worth more than the sources.

A thumbnail that could not be fetched marked its row **broken** — which hides
it from every query, permanently, surviving restarts *and* the re-crawl that
would otherwise add it back. That is right when a picture is genuinely gone. It
was being done on **any** failure, including a `429` from a host that was
merely busy. Wikimedia's upload host says 429 readily when ninety tiles open at
once; the same file answered `200` twelve seconds later.

So `ScrapeError` can now say whether a failure is the last word — 404, 410, 403
and a parse failure are permanent; 429, 5xx, connection resets and timeouts are
not — and a row is hidden only when **every** candidate URL failed
permanently. `fetch_bytes` also raises `RateLimited` for a 429 rather than
folding it into a bare status, which is what the variant was written for and
was never constructed.

That left the rows the bug had already hidden, and there were **1,032** of them
in a 32k-row catalogue — 3%. Hiding could not tell "you chose this" from "the
picture would not come", because both wrote the same table. It records a
`reason` now (`user`, `fetch`, or `legacy` for everything hidden before the
distinction existed), and a `restore` method forgets the daemon's own decisions
while never touching a person's. Measured: 1,032 restored, 0 remaining, and a
re-crawl adds the rows again — where before they were refused forever.

It cannot un-delete: hiding deletes the row, so what restore lifts is the
*refusal*, and the pictures come back as their sources are crawled. The UI says
exactly that rather than implying the pictures reappear on the spot.

**A deadlock, in the method that fixes the deadlock's own bug.** The first
version read `match self.catalog.lock().await.unhide(scope) { Ok(n) => … }` and
locked again inside the arm to build the reply. A guard from a match scrutinee
lives until the end of the whole match, so the daemon answered nothing at all
until the client gave up. One lock, taken once, released before the reply is
built.

## The setting that did nothing

`Prefs.blurNsfw` has defaulted to true since the setting existed, and **nothing
read it** — not the tile, not the thumbnail, not the detail view. Survivable
while every source was safe; not survivable the same day adult boards shipped.
A promise in a settings panel that the pictures do not keep is worse than no
setting.

It blurs now, on the tile and in the detail view, with one tap to reveal and
the reveal reset when the tile is recycled or the shown item changes — a wall
that stays uncovered after you scroll past is not what tapping one picture
meant. The effect is on the picture only, so badges, the title strip and the
hover ring stay sharp and the tile still reads as a tile.

`blurMax` is 48 on a tile: below about 24 you can still read the picture, which
defeats the point.


---

## Two layouts that measured nothing

Both found from screenshots, both the same mistake in different clothes: a
component asking for its size from something whose size depends on it.

**The search box was 4 pixels wide.** `QueryBar`'s root declared an
`implicitHeight` and no `implicitWidth`. In a RowLayout competing with a
`fillWidth` spacer, an item with no implicit width can be handed almost none —
and it was: measured at **4px**, against **620px** once it declares one. That
does not look like a broken layout. It looks like there is no search box: the
field's own background is 4px of nothing, and the two icons that live at its
edges — the leading magnifier and the filter button — collapse on top of each
other at the far right of the bar with the field's border as a hairline between
them. Which is exactly what the screenshot showed. The competing spacer is gone
too; the heading is a fixed width and the buttons are their own size, so the
search simply takes what is left.

**The filter panel opened at 70px with 73 filters in it.** `surfaceHeight` was
`layout.implicitHeight + 28`, and the only thing in that layout with any height
is a ListView with `fillHeight`, whose implicit height is **0**. So the panel
measured its own title bar and nothing else, and drew the word "Filter" over an
empty box. It counts its rows now — 26px for a group label, 36 for a facet, 96
for the category cloud — and opens at **605px with 75 rows**.

The export sheet had this exact bug once already. Three times is a pattern
worth naming: **a sheet must never take its height from a layout that takes its
height from the sheet.** Count what is going in it.

Verified by measurement rather than by looking, which is the point: both of
these render without a single warning. There is an `app filter` IPC call now
that opens the panel and reports its row count and height, so this class of bug
has something that can fail a test instead of needing a screenshot.

---

## Why the round things were not round

Reported as "the rounding button doesn't look round, it is not smooth". Two
causes, and the second one is general enough to be a rule.

**`antialiasing: false` on four badges**, one of them carrying the note "a 22px
badge does not need the extra geometry". That has it exactly backwards: the
smaller the curve, the larger each stair-step is as a fraction of it, and at
22px an aliased circle does not read as a circle at all. Qt enables this by
itself for any rounded rectangle, so switching it off was spending nothing in
order to look worse.

**Layers render at logical size.** A rounded button clips its ripple with
`layer.enabled` + `OpacityMask`. An offscreen layer is rendered at the item's
*logical* size and then scaled to physical pixels — on this display, 1.67× —
with `layer.smooth` defaulting to false. So the curve arrives stair-stepped
however well Qt drew it, and the mask compounds it: `OpacityMask` multiplies by
the mask's alpha, so the edge is only ever as smooth as the mask's own edge,
and the mask was a bare `Rectangle` with no antialiasing at all.

`layer.textureSize` at the device pixel ratio and `layer.smooth: true`, on the
layer *and* on the mask. The same fix applies to the three masked previews in
the context view.

**The rule: any `layer.enabled` on a fractionally-scaled display needs
`textureSize` and `smooth`, or it is a resample of a texture that is too
small.** It is the same family as the `sourceSize` bugs in the thumbnail path —
something is being drawn at one size and displayed at another, and nobody said
which one wins.

## The corners, and the setting that fought itself

`clip: true` clips to an item's **rectangle** — it has never respected
`radius`, and nothing says so out loud. So the wall painted square into all
four corners of a rounded panel, straight over the curve and the border: "there
is a shape but the image gets through". The usual fix renders the whole gallery
into an offscreen texture every frame to hide four wedges of about 300 pixels
each, which is not a trade a frame budget can make. `RoundedCorners` draws four
`Shape` wedges instead — the corner square minus the quarter circle, filled
with the colour behind the panel — plus the border over the top. Static
geometry, no offscreen pass.

And the blur shipped earlier was wrong in a way only a screenshot shows: with
adult results switched **on**, every tile was blurred with a "Tap to reveal"
button on it, and the wall read as broken low-resolution pictures. Two settings
contradicting each other — switching them on *is* asking to see them — so that
switch now clears the blur, the blur has its own control in the menu (it had
none), and blurring reveals on **hover**, which is what the settings panel had
promised all along.


---

## The search bar, and the rail that was not information

**The rail.** Colouring the scrollbar was right and I did it twice over: the
handle got a colour *and* a full-height track appeared down the side of the
window. The track is the wrong half — a permanent pale rail competing with the
pictures to say something the handle's own position already says. The part you
can grab is the part that carries information. It is opaque now, always there
while there is anywhere to scroll, and the rail behind it is nothing.

**The bar.** Three things it did not have, all of which became more obvious
once filters started writing themselves into it:

- **No way to clear it.** Emptying it meant holding backspace — and with the
  filter panel now typing `source:wikimedia` into the query, the bar
  accumulates and "start again" is a common thing to want. A clear button
  appears only when there is something to clear, so the resting bar still shows
  one control.
- **A placeholder that was a specification.** It read `search, or
  kind:wallpaper ratio>=2.3 -nsfw` — the grammar, correctly, and also the first
  thing anybody sees: three operators and a negation before you have typed
  anything, which says "you need to learn this". It offers one real example
  now, and names how many sources are behind it — the sources that actually
  have rows, not the ones that exist, because a number that is a promise rather
  than a fact is worse than no number.
- **`/` landed the cursor at the end of the last search.** So the first thing
  you typed was appended to a query you meant to replace. It selects now, and
  Ctrl+F does the same thing for everyone who does not press `/`.


---

## Correct, and too small to see

Three controls in a row turned out to be present, correctly wired, and sized
into invisibility. It is worth naming as a class, because styling never fixes
it and looking at the code does not reveal it.

**The scrollbar handle was about two pixels.** `ScrollBar` draws its handle at
`size × height`, where `size` is the fraction of the content on screen — and at
37,472 items that fraction is 0.002. Every attempt to fix the scrollbar by
styling it (colouring the handle, then adding a track) was fixing the wrong
thing: the handle was already opaque and already the right colour, and it was
two pixels tall. The fraction is clamped to whatever makes 40px now, measured
at **40px of an 806px rail**. The cost is that travel no longer maps exactly to
the content, which it could not anyway.

**The completions dropdown was a 12px sliver.** Two independent reasons, both
fatal on their own. Its height was `min(count, 6) × 32 + 12`, so with no
suggestions it was still 12px of visible chrome. And it was a child of the
search bar with `z: 100` on it — but `z` orders an item among its own
siblings, and the gallery is a sibling of the entire header, so the pictures
painted over it; what did draw was cut off by the header's clip. It renders in
an overlay above everything now, positioned by mapping the field's corner, and
it is 0px tall when there is nothing to say. Measured: **204px for five
completions, 128px for three, 0px for none.**

The daemon's `complete` had been answering correctly the whole time —
`kind:` → five kinds, `source:d` → danbooru, derpibooru, deviantart.

While it was open the rows got something to distinguish them: an icon per axis
(a tag, a cloud, a shape), the `key:` dimmed against the value it qualifies so
a column of `source:` prefixes stops being the loudest thing in the list, and a
return mark on the row that Enter will take.

**How this class gets caught in future.** `app chrome` reports the scroll
handle's real pixel height, the search bar's width and the dropdown's height,
and `app type` puts text through the *field* rather than setting the query
directly — which is the difference between exercising the completions and
skipping them entirely. Neither of these bugs is visible in the code and
neither would fail a unit test; both are one line of terminal output.


### …and then it was a menu that happened to appear nearby

Fixing the dropdown's geometry left it correct and still wrong: a narrower box
floating six pixels below the search bar, in a different surface colour, with
its own border. A completions list is not a menu near the search — it is the
search bar with more of it showing.

So it is exactly the field's width, hard against its bottom edge, in the
field's own colour, wearing the field's border (including the accent it takes
while focused, so the outline runs around both halves). The field squares its
bottom corners while the list is open and the list squares its top ones, which
is what turns two rectangles into one control that grew. Per-corner radii
(`bottomLeftRadius` and friends, Qt 6.7+) rather than a mask: no layer, no
offscreen pass, and the animation between pill and squared-off is a number.


## The search bar, taken seriously

Built against Baymard's autocomplete research and the command-palette pattern
work rather than by taste, because one of their findings is the opposite of
what instinct produces.

**Emphasise what you have NOT typed.** The instinct is to bold the match — and
it is measurably wrong: you already know what you typed, so bolding it makes
every row identical at the front and buries the one thing that distinguishes
them. The typed prefix is dimmed and the remainder is not, so a column of
`source:` completions reads as *danbooru, derpibooru, deviantart* instead of as
three source-somethings.

**Arrowing copies the row into the field.** This is what makes an autocomplete
feel like typing rather than like picking from a menu: you arrow to
`source:danbooru`, it is in the bar, and you carry on with ` w>=3440` from
there. Escape gives back what you actually wrote, which is why the text before
the preview is kept — dismissing a list must not leave you holding a suggestion
you were only looking at.

**Eight rows, expanding, never scrolling.** Past about ten, people stop reading
suggestions and start ignoring them; a scrollbar inside an autocomplete is a
list that has given up on being scannable.

**Counts, styled as supporting information.** Monospace and dim, aligned down
the column: it is the difference between guessing a source name and choosing
one with a size attached.

**Recent searches in the zero state**, labelled — a scope label, visually
apart, because a past search and a completion are the same shape and opposite
acts: one replaces the query, the other narrows the token. Only searches that
were actually *run* are kept, which needed the history to hang off submit
rather than off `_apply` — that fires 160ms after every keystroke, so
remembering there fills the list with `s`, `su`, `sun`, `suns`.

**A stale-answer guard.** Completion requests go out per keystroke and return
whenever they return; the protocol promises no ordering. A slow reply for `so`
landing after a fast one for `source:d` would replace the right list with an
old one, and it would read as the dropdown lagging a character behind rather
than as a bug. Each request carries an epoch and a late answer is dropped.

Sources: Baymard's autocomplete design patterns, and the command-palette
pattern write-ups listed with them.


---

## One socket, four tabs

The shell reached quarry by spawning `bash -c` with a helper script per page:
a process, a `socat`, a JSON parse and a pipe teardown on every scroll —
request/response only, with no way for the daemon to say anything on its own.
It worked, and it was ceremony where the actual query takes single-digit
milliseconds.

`ii/services/Quarry.qml` is quarry's own client ported into the shell: one
long-lived unix socket for the life of the session, newline-delimited JSON,
every call answered by id so a slow `items` can never be mistaken for the answer
to a later `query`. The awkward parts came with it because each one was learned
the hard way — the socket is **rebuilt, not reopened** (Quickshell's Socket does
not come back once its peer is gone); the retry is driven by `running` rather
than by toggling a property twice in one handler (which the property system
collapses into no change); the handshake is sent via `Qt.callLater` because the
connected signal arrives while the Loader is still creating the object; and
every call carries a deadline, because a unix socket whose peer has died does
not always report itself closed and the symptom is a tab that quietly stops
filling in.

**The tab is now a query.** Wallhaven had its own URL builder and colour codes,
Reddit an OAuth script and a download directory, Videos read files off disk,
Local scanned a folder — four mechanisms, four failure modes, one carousel. They
are one query language with the tab as the scope: `source:wallhaven
kind:wallpaper`, `family:video`, `source:local`. Adding a source to quarry adds
it to every tab that wants it.

Thumbnails come back as local `file://` paths from quarry's cache, already the
right size and already decoded once, fetched for a whole page in one `thumbs`
call rather than one request per row.

### Two bugs that made the search useless

**Wallhaven rows carry no text at all.** A search result has an id, a size and a
purity rating — `title=''`, `tags=['general']`. So a crawl for "nature" fetched
exactly the right pictures and the catalogue could then never find them again:
3,354 rows, and searching the word that fetched them returned **0**, forever.
The terms that fetched a row are the truest thing anyone knows about it — the
source itself said this picture answers that word — so they are written down as
tags. Operators are excluded by allowing words rather than forbidding syntax:
blocklisting `:` and a leading `-` let `w>=3440` through, which would have been
stamped on every row a size filter ever fetched.

**And a known row could not learn one.** `insert_many` skips an id it has
already seen, which is right — a crawl must not trample enrichment — but it
meant the fix only reached rows that happened to be new. Re-crawling "nature"
reported `added: 0, duplicate: 24` and changed nothing. Tags merge into an
existing row now, as a union and never a replacement, with the text index
rebuilt for that row: `24 known rows learned a new tag` → **the same search
returns 24**.

## Your own pictures, at last

There was no `local` adapter, so quarry knew about a million pictures and
nothing about yours — for an app whose premise is *every image slot on your
desktop*, the biggest hole in the product.

It is a `Source` like the others, which is the whole design: same push-down,
same crawl loop, same dedupe, same tagging, rather than a second way to get rows
into the catalogue with its own bugs. What makes that possible is that it names
itself with a `file://` URL — `build_url` returns a directory and a page, the
daemon lists the disk instead of fetching the network, and `parse` reads the
listing. Dimensions come from the file header rather than a decode, so scanning
a picture folder is not a minutes-long job, and the walk is paged so it cannot
block a crawl on the first call.

One thing had to learn about it: **`fetch_bytes` now reads `file://`**. reqwest
rejects the scheme outright, so without that every local tile would have failed
to load and then been marked broken — the local source would have indexed your
library and shown you nothing. Measured end to end: 200 of your own pictures
indexed with folder tags, and one thumbnailed, hashed and colour-extracted
through the ordinary pipeline.

---

## Reddit, and two hours inside a TLS handshake

The last tab. Reddit has answered 403 to every unauthenticated path since 2024
— `www`, `api`, and `old` which now redirects to HTML — so this is the OAuth
API or nothing.

The straightforward parts were straightforward: a password grant against a
script app, credentials read from the environment file the user already keeps
(never printed, never logged, never stored here), and the token cached in **the
same file the user's own shell scripts use**, so quarry crawling and a shell
script cannot race each other into the rate limit with two separate sessions.
Reddit pages by an `after` cursor rather than a page number, which no other
source here does, so the adapter remembers the cursor per listing and updates
it from each response — in memory only, because it is a position in a feed that
reorders constantly and a restored cursor would point into a listing that no
longer exists.

Then it returned **403** with a body that was Reddit's *website* block page.

The same token, the same URL and the same User-Agent returned **200** from
curl. Ruled out, one at a time: the User-Agent (200 with quarry's own), the
`Authorization` capitalisation, `Accept: */*` present and absent, gzip, HTTP/2
versus 1.1, and `limit=100` versus `limit=5`. Every variant of the request was
fine. Python's urllib returned 200 with the identical headers.

What curl and Python share is OpenSSL. **Reddit's edge fingerprints the TLS
handshake and refuses rustls before it reads the request** — which is why no
header changed anything, and why the failure looked like a permissions problem
on an endpoint that had just accepted the credentials.

So the Reddit client, and only the Reddit client, is built on `native-tls`.
Everything else keeps rustls and its no-OpenSSL-at-runtime promise; `openssl` is
now a package dependency for one source's handshake. Measured after: **81 rows
on page one, +84 on page two, +76 on page three**, with real titles, real
dimensions from the preview metadata, and the subreddit as a tag.

That is all four tabs on one socket and one query language: `source:wallhaven
kind:wallpaper`, `family:video`, `source:local`, `source:reddit`. Four clients,
four cursor schemes and four failure modes became one connection — and Reddit
posts are now searchable next to everything else rather than living in a
download folder.


## `mapToItem` is not a binding

The completions list drew at the far left of the window, under the heading,
while the search bar it belongs to sat nine hundred pixels away on the right.

The position was written as `x: field.mapToItem(overlay, 0, field.height).x`,
which looks like a binding and is not one. `mapToItem` **reads** geometry; it
does not **depend** on it, so Qt evaluates the expression once — during the
first layout pass, while the RowLayout has the field at x≈0 — and never again.
Nothing in QML warns about this: the property has a value, the value is a
number, and it is the right number for a moment that has passed.

So it is assigned rather than bound, and recomputed on everything that can move
it: the popup becoming visible, the bar resizing, the overlay resizing. A
binding on `width` alongside assigned x/y was left in at first, which is worse
than either — a list that half-follows its field.

The check that would have caught it is one line of output, and is now part of
`app chrome`: **`field x=176 w=383 · popup x=176 w=383`**. Before the fix the
popup read `x=0`. Nothing about that is visible in the code; it is visible the
moment the two numbers are printed next to each other.

---

## Launch: 477 ms → 348 ms, and why 100 ms is not on the table

Asked for under 100 ms. That number is not reachable, and the measurement says
why in one line: **an empty quickshell config — `ShellRoot {}`, zero lines of
ours — takes 131 ms.** The runtime, the QML engine and the Wayland handshake
cost more than the budget before any of this app exists.

Measured end to end, launcher to window on screen, best of several runs because
a busy-wait poller competes with the thing it is timing (single samples were
reading 200 ms high):

| | |
|---|---|
| launcher → window, before | **~477 ms** |
| launcher → window, now | **348 ms** |
| quickshell floor (empty config) | 131 ms |
| daemon cold start, first answer | 71 ms |

**Where the 129 ms came from: the launcher started a second copy of the
application in order to find out whether the application was running.** The
probe is `qs -c quarry ipc call app open`, which spawns a whole `qs` process,
looks for instances, finds none and exits — paid on every cold start, where the
answer is always "no". A look at the process table answers that case in about a
millisecond. The IPC probe still runs when something *is* running, because a
live instance with a closed window has to be raised and only IPC can do that.

**And one optimisation that made it 60% worse.** Five gallery layouts are
instantiated at startup and four are immediately hidden, which looks exactly
like the thing to fix — so they went into `Loader`s keyed on the current layout
mode. Result: **624 ms against 377 ms eager.** Two reasons, both worth
remembering. An inline `Component` inside a `Loader` is still *compiled* at
load, so nothing was saved there; and `active` depends on a preference that
arrives from a file asynchronously, so the real layout was built *after* the
window would otherwise have mapped, pushing the visible moment later. Reverted.

What is left is ~215 ms of compiling 70 QML files and 14,577 lines, on every
launch, because nothing caches it: quickshell loads QML through its own engine,
so Qt's disk cache stays empty even with `QML_FORCE_DISK_CACHE=1` (verified:
zero `.qmlc` files written), and `qmlcachegen` cannot compile these sources —
it requires versioned imports and cannot resolve the `qs.*` modules.

Cutting that further means less QML reachable from `shell.qml` at startup, which
is a real refactor rather than a flag: `source:` URLs instead of type
references, with every property and handler rewired through `Connections`. For
the four unused layouts that is about 1,150 lines of 14,577 — perhaps 20 ms —
which is not worth what it does to the code. The honest floor for this app is
somewhere near 300 ms.


### Launching from the applications menu

The number that matters is the one the menu produces, and it was worse than the
one a terminal produces — for a reason that had nothing to do with the app.

**The launcher waited for the daemon before starting the window.** It spawned
`quarryd`, then polled for its socket in fifty-millisecond steps for up to two
seconds. The daemon binds in about 70ms, so most of that wait was the polling
granularity, and every millisecond of it was time with nothing on screen. They
start together now: the window draws while the daemon binds, which is safe
precisely because the client reconnects on its own.

That exposed a second thing. The client's retry was a flat 1.5 seconds — right
for "the daemon died, keep trying", badly wrong for a cold start where the
socket appears 70ms in. It now retries every 120ms for the first eight
attempts and then backs off to 1.5s, so the gallery fills as soon as there is
something to fill it with rather than up to a second later.

**And `cargo metadata` ran on every daemon start.** Launched from a menu the
PATH is `/usr/local/bin:/usr/bin` — no cargo, no jq — so it paid for two failed
process spawns before falling back to the installed binary, on the launch that
was already the slowest. It only asks cargo where its target directory is when
cargo is actually there.

| launched from the menu | before | after |
|---|---|---|
| cold — no daemon running | **710 ms** | **372 ms** |
| warm — daemon already up | ~490 ms | **336 ms** |

Best of five in each case. Single samples on this machine vary by 150ms, which
is more than several of the things being measured — every number above that is
a minimum, not a mean, and the earlier figures in this file that were single
samples read high.

## The warm queue that never ran

Reported as: scrolling fills the tiles in visibly, row by row, like a wave
travelling down the wall.

Pages of records arrive with a list of thumbnails the daemon has not cached
yet, and those go on a warm queue drained by a timer. The timer was **restarted
every time a page landed** — and while you are scrolling, pages land more often
than its 500ms interval, so the countdown was reset before it ever fired. The
queue grew and never drained. The only thumbnails being fetched were the eight
that visible tiles requested for themselves, which is precisely the cascade:
the wall could only fill as fast as the tiles you were already looking at.

Two lines. `restart()` became "start it if it is not already running" — the
timer's `running` is bound to the queue being non-empty, so it starts on its
own and must not be told to begin again on every enqueue. And the interval went
from 500ms to 150ms, because half a second is four or five rows at scrolling
speed: the batch size and the concurrency are what bound the competition with
visible tiles, while the interval only decides how far behind the eye the queue
runs.

Measured on cold content — a query whose thumbnails were not on disk:

| | |
|---|---|
| warm rate while scrolling, before | **0/s** (timer never fired) |
| warm rate now | **48/s**, sustained |
| decode gate during a scroll | idle — `inFlight` 0–1 of 8 |

That last row is the part worth keeping in mind. The decoder was never the
bottleneck and neither was the gate; making either bigger would have done
nothing. What remains is a network fetch per uncached thumbnail, bounded by the
rate limiter each source gets — so scrolling faster than about fifty pictures a
second through material nobody has looked at will still fill in behind you.
Nothing in the client can make a cold remote thumbnail instant; what it can do
is stop being the reason it is slow.


---

## Shelves, four more boards, and two things that loaded twice

**Sources are on shelves now.** Twenty-two of them in one alphabetical list is a
phone book rather than a filter — wallhaven sat between a museum and a furry
booru, and choosing meant already knowing every name. Each source declares a
category (`wallpapers`, `photography`, `art`, `video`, `icons`, `local`,
`adult`) and the panel groups by it. The shelf comes from the adapter, not from
the catalogue, so a source with no rows yet still appears in the right place
instead of moving as you use it.

**Four more boards**, all verified live before shipping: **hypnohub** (gelbooru
dapi, still keyless), **twibooru** (the third Philomena board, on the newer v3
API where `media_type` says webm without guessing at extensions),
**sakugabooru** (moebooru, and a video source in practice — it is a board *of
animation*), and **e-shuushuu** (1.5M hand-tagged images, whose API gives a
filename and an extension rather than a URL, so the map templates earn
themselves again).

Tested and rejected, so nobody repeats them: ponybooru (504 for an hour),
tbib / rule34hentai / atfbooru / danbooru's safe mirror (Cloudflare),
realbooru (answers XML whatever you ask for), coomer and kemono (unreachable),
rule34.us (HTML), nekos.moe and nekosapi (**no dimensions published** — rows
with no ratio are dropped as collapsed tiles), yiff.rest (works, but serves
e621's own CDN — the same library behind a second API), mspabooru (its dapi
refuses the empty `tags=` the crawler sends).

That is **six keyless adult sources** — derpibooru, e621, furbooru, hypnohub,
twibooru, xbooru — plus rule34.xxx and gelbooru, which are the two largest and
both want a free key. Ten was the ask; six that answer honestly is what the open
web has left, and padding the count with a board that returns nothing would have
been the worse answer.

**And two things really did load twice.** Opening a picture fetched a *ladder
step* sized to the pane — so the wall's tile appeared, then a slightly better
version of the same image arrived on top of it. It asks for the original now:
the ladder never upscales, so a request above the source's own size returns the
source. One fetch, the best there is, with the already-cached tile behind it as
an instant backdrop that never re-fetches.

**Video plays in the wall.** A video tile showed a poster and nothing else, so
the only way to judge a clip was to open it — the same mistake as a still GIF
tile, which was fixed by playing it on hover. This is that, for the family where
it matters most. The shape is Rodded's `WallTile`: the player is *created* by a
Loader rather than paused (a paused MediaPlayer still holds a decoder, and a
wall can hold forty), nothing plays while the viewer is open, and it is always
muted here — sound belongs to the thing you chose to look at, not to whatever
the pointer crossed.


---

## Settings became a screen; the dock became useful

**Settings was a 480x600 sheet with three sections** — the wall, what you see,
diagnostics — while the app had grown twenty-three sources, four families,
video, extensions, a catalogue with its own storage and a daemon with its own
state. Everything that did not fit went into the ⋮ menu instead, which is how
that menu came to be doing four jobs at once.

It is the shape Morse uses now: a rail of six pages down the left — Appearance,
Content, Video, Sources, Storage, About — and one page of titled sections on the
right, wide enough that a footer explaining a setting is a sentence rather than
a paragraph. The rail is the part that makes it legible: six words to scan
instead of forty rows.

**The menu it was hiding behind got the same treatment.** Sections have names
(*Tiles*, *What is shown*, *Settings*, *Diagnostics*, *Catalogue*, *Extensions*,
*Status*) rather than hairlines — a hairline says "these are apart" without
saying what either side IS. A checked row is a quiet tint with an accented icon
and check, not a saturated bar: with one selected item a filled bar reads as
confident, and with five it is a stack of stripes where the row under your
pointer no longer stands out. And the menu is capped at 82% of the window and
scrolls, because it had grown past the bottom of the screen with no view around
it to scroll.

**The dock was showing the one thing you choose least often.** It listed
destinations — every slot a picture can be sent to — which is a decision made
once, at the end, while the choice you make constantly (pictures, video, or
both) was not on screen at all. They have swapped: **Mix · Images · Video** now
lives in the dock, and it reads its state from the query rather than holding its
own, so typing `family:video` by hand lights the same button.

**And the black flash on load** had the same cause as the shouting menu: a
colour with nothing to do with the picture. Every tile sat on flat dark grey, so
a load read as "dark, then image". The daemon already computes each row's
dominant colour while making its thumbnail — the ground is that colour now,
dimmed, and a picture settles into itself instead of out of a hole.


---

## Sources you can actually configure

Twenty-six sources is past the point where "all of them, always" is a policy.
Someone browsing wallpapers does not want a furry booru taking a quarter of
every crawl, and someone who has added a key for gelbooru probably wants it
asked first — and neither is expressible by editing manifests, because a
manifest describes what a source IS and this describes what you want from it.

So there is a preferences file beside them (`~/.config/quarry/sources.json`),
and settings lists every source with a switch, its shelf, how many rows it has
contributed, whether it carries video, and what you have tuned. Off means the
crawler skips it — the rows it already gave you stay, because throwing away
work over a preference is not what a switch should do.

`pages` is the useful lever rather than the on/off: a source capped at one page
still appears and still contributes, it just stops crowding out the rest.
`weight` decides who is asked first, ties keeping their declared order.

**And the mix has a seed.** "Everything at once" is not one behaviour — asking
each source in turn, following the weights strictly, and shuffling all produce
different walls from the same catalogue. The shuffle is an xorshift from a seed
you can change, so the same number gives the same wall tomorrow and a new one
asks for another. One line, no dependency, and a test that asserts both halves:
the same seed reproduces an order, a different seed does not, and neither loses
or duplicates a source.

The whole file is defaults if it cannot be read, with a line on stderr.
Preferences must never be able to stop the daemon starting.


## The grid is a way in, not a dashboard

It took three attempts, and the last two were the same mistake getting fancier.

First it was full-width cards holding a title and a sentence — a list with
rounded corners, which says less per screen than the list while taking more of
it. Then it was a bento: cards of different spans carrying live switches, big
statistics and a preview of the tile radius. That looked considerably better
and was still wrong, because a grid at the front of a settings screen is asked
exactly one question — *where do I go* — and putting the controls on it means
reading a layout before you can act, while duplicating every row that already
exists one click away.

What it is now: one tile per category, all the same size, large enough to hit
without aiming, with a single line under each label — `25 of 26 on`,
`48259 pictures`, `adult shown` — because that is the one fact that helps you
choose between them. Tapping one goes there; the grid is a front door rather
than a second place to read the same rows.

The note below is kept because the reasoning in it is right for a dashboard and
was simply the wrong thing to build here.

## (superseded) A grid that is not a list with rounded corners

Asked for a grid view of the settings, the first attempt made every page a
full-width card holding a title and one sentence. That is a list with rounded
corners, and it is *worse* than the list, because it says less per screen while
taking more of it.

A grid earns its place only when the cards are not equivalent. A column count
is a number you glance at; a source list is something you read; a set of
switches is something you operate. So the cards differ in three ways at once:

- **Span.** Content and Video take two columns of four and Content takes two
  rows; the two statistics take one each; the daemon line runs the full width.
- **Content.** A statistic card is a big number and a caption. A control card
  carries the actual switches, operable without leaving the grid — adult
  results, blur, hover-play, autoplay, sound. The Appearance card draws five
  rectangles at the tile radius you have set, because a preview says more than
  "12px" does.
- **Type.** A statistic is set at 1.6× the title scale in bold, because on that
  card the number IS the content; its heading is dropped to the subtext colour
  because it is a label on the number rather than a thing to read. On a control
  card the relationship inverts.

That difference is the entire argument for drawing a grid rather than a list. A
wall of identical tiles asserts that these things are equivalent, and they are
not.

## Phase 8 — 2026-09-20 — filtering

"quarry loads and updates slowly if we use the filters." Measured rather than
guessed at, against the live catalogue: **165,663 items, 167 MB**.

Three places the time could be, so all three were instrumented: the daemon's
own phases (`QUARRY_TIMING=1`), the client's split between waiting and applying
(`app probe` → `catalog.timing`), and sqlite's own timer on the exact SQL.

| phase | before | after |
|---|---|---|
| `query ""` (everything) | 173 ms | **117 ms** |
| `query "kind:wallpaper"` | 119 ms | **96 ms** |
| `query "family:raster"` | 152 ms | **120 ms** |
| `query "family:raster kind:wallpaper"` | 78 ms | **52 ms** |

Medians of three runs each, same catalogue copy, old binary vs new.

### What it actually was

**The default ordering was a sort nothing could index.** The catalogue is dealt
in a deterministic shuffle so a launch does not open on whatever the crawler
added last — written as `ORDER BY (rowid * 2654435761) % 4294967296`, a value
computed per row at query time. Every filter change therefore sorted all 165k
rows by a number sqlite had to calculate first: **176 ms** against 72 ms for the
same query with no ORDER BY.

Stored as a column with an index, the same order is a scan. Two attempts, both
measured:

| index | `everything` | `kind:wallpaper` |
|---|---|---|
| computed in the ORDER BY (before) | 176 ms | 296 ms |
| `item(deal)` alone | 140 ms | — |
| covering `item(deal, kind, family, source, id, ratio, dominant, phash)` | **49 ms** | **60 ms** |

Indexing `deal` alone made it *worse*: ordering by that index then fetches every
row's other columns by rowid — 165,000 random lookups across a 168 MB file. The
index has to carry what the query reads AND what it filters on. It costs disk:
**167 MB → 182 MB**.

### Two "obvious" optimisations that did nothing

Before measuring the SQL, the per-row allocations in `rank` were removed: a
`Vec<u64>` built per row in the near-duplicate pass, and a `HashSet<String>`
that cloned every phash to test it. Both are real waste and both are gone — and
the A/B showed **no measurable difference**, because the two dedupe passes
together are 12 ms of a 325 ms query. That is why the phase timers exist now.

### What is left, and where

Client side, unchanged by any of this and now the larger half:

| query | daemon + parse | applying it | of which `ratios =` |
|---|---|---|---|
| `kind:wallpaper` | 141 ms | 227 ms | 114 ms |
| everything | 237 ms | 205 ms | 67 ms |
| `source:wallhaven` (21 rows) | 28 ms | 84 ms | 47 ms |

**The cost does not follow the result size** — a 21-row answer spends 47 ms in
that assignment. It is the *previous* array being collected: one number per item
for 165k items, replaced on every filter change. The next lever is not making
that array faster to build but not rebuilding it — sending ratios only for the
layouts that need them (masonry does; grid, sheet and compact do not), or
keeping them in a form the engine does not have to walk.

## Search results: keystroke to first rows (2026-10-21)

TASKS #10. A private release daemon (`--socket`, own HOME/XDG dirs, a ~17–27k-row
catalogue), 46 sources asked, 2 pages each; app headless (`headless-qt.sh qs -p`),
timed by setting `catalog query` over IPC and polling `catalog count` every 50 ms.
New words every run so no cursor or cache helps.

| | first catalogue hits | first rows from the sites | ~90% of matches | daemon answers `more` |
|---|---|---|---|---|
| installed r20261016 | ~0.1 s | **12.1 s** (2 runs) | 18 s | 34 s (debug) |
| now | ~0.1 s | **0.5–0.65 s** (3 runs) | 1.4–2.2 s | 15–20 s |

Daemon side alone (`more` on a socket, time to the first `catalog.changed`):
15.5 s → 6 s → **0.19–0.38 s** as each of the first two fixes landed.

Where the time was — none of it was the network (pages arrived in 0.2–0.5 s):

- **~5 s: `sources::by_id` parsed all ~160 manifests per call** (and leaked each
  id), and the `more` loop looked up every source by id. `Declarative::load_all`
  now caches, re-reading only when a manifest file changes (looked at ≤ 1/s).
- **~10 s: every source's URLs were built before any page was fetched**, so one
  board's tag-autocomplete lookup held up all 46. Each source now fetches as soon
  as its own URLs exist.
- **The app only looked every 4 s.** `catalog.changed` was in PROTOCOL.md and the
  client listened for it, but the daemon never sent it. Now sent per filed page;
  the client's `extendSoon` starts (not restarts) so a stream cannot starve it.
- **`extend` waited 4+ s behind thumbnails.** Catalogue requests shared the
  permits that thumbnail fetches hold while waiting on image hosts; the ordered
  ones (`query items item sources stats hello extend`) now take none.

The 15–20 s total is the per-page 20 s timeout on the slowest host; nothing waits
for it any more.

### Round 2 (same day): the real catalogue size, and pictures rather than rows

A copy of the real catalogue (55,212 rows, `sqlite3 .backup`), release daemon.

**`extend` re-ranked the whole query per page.** On the home feed (nothing typed,
~44k rows) that was **57 ms median, 124 ms max**, under the catalogue lock, four
times a second while a search ran. It now asks the query of only the rows the
crawl touched since the last extend — new ones and known ones that learned the
search words (`Catalog::touched`): **0 ms median, 1–4 ms p90**. A grown result
was compared row for row with a fresh query afterwards: 517 = 517, none missing.
A page of known rows that learned words now also sends `catalog.changed` — it
used to send nothing, and only the 4 s poll ever showed them.

**Thumbnails, not just rows** (`perf report` `tilesReady`, polled with the count):
with an idle daemon the first pictures follow the first rows within ~0.2 s, but a
search typed while the last one's screen was still loading drew rows at 0.56 s
and its first picture at **2.5 s** — the old tiles' `thumb` requests held the 24
permits. The app now sends `cancel` for them when the query changes: four
back-to-back searches drew their first pictures at **0.18–0.92 s**, with every
tile filled afterwards (screenshot checked) and no failed or stuck requests.

Also: the 4 s polling refresh stands down while `catalog.changed` events arrive,
and a declarative page is no longer parsed twice to learn whether it was empty.
