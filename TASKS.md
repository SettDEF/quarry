# Tasks

Ordered by what I would do next, not by size. Each says why it matters, because
a task without that becomes a chore nobody sequences correctly.

`PLAN.md` is the architecture and `PERF.md` the measurements; this is the list.

## 1 — Move the query onto SQL — **done**

`quarryd/src/catalog.rs` contained no SQL at all: every query was a linear scan
over the whole catalogue held in RAM, while `item_fts` was maintained on every
insert and never read. The cost was paid and the benefit was not taken.

Done: predicates compile to a `WHERE`, free text goes through `item_fts MATCH`,
colour and collection membership stay in Rust because neither is a column, and
the working set is the current result rather than every row. **133.5 MB → 11.5 MB
resident, startup no longer proportional to the catalogue.** `PERF.md` has the
numbers, the deliberate change to text search, and the test that keeps the two
engines answering the same question.

## 1b — Reddit, which needs OAuth

Every unauthenticated Reddit JSON endpoint is a 403 now (`www`, `api`, and
`old` redirects to HTML). It is the largest wallpaper source there is and it
carries video, so it is worth the adapter — but it needs the OAuth
client-credentials flow, which no manifest can express. Credentials are already
on this machine at `~/.secure/reddit-app.env`; **never print, log or commit
anything from that directory** — the adapter reads the environment and nothing
else.

**Done when** `search {"source":"reddit"}` returns rows and a token refresh is
covered by a test that does not touch the network.

## 2 — Persist crawl cursors

`cursors: Mutex<HashMap<String, u32>>` lives in the process. After a restart,
endless scroll begins again at page 1 of every source, refetches what it already
has, and adds nothing — silently, and rudely to the sources.

A table keyed by (source, query) with the page reached. Five lines, and it stops
the daemon lying about how much of a source it has seen.

## 3 — A local-folder source

There is still no `local` adapter, so quarry knows about other people's pictures
and nothing about yours. The wallpaper you have had for two years is not in it.

For an app whose premise is *every image slot on your desktop*, that is the
biggest hole in the product, and it is the cheapest source to write: a directory
scan plus `notify` for changes. It also makes import, dedupe against what you
own, and "what am I using" mean something.

## 4 — Evict thumbnails

16,000 files in `~/.cache/quarry/thumbs` and nothing ever removes one. No cap,
no TTL, no LRU: a cache in name only. Bound it by size, drop least-recently-read
first, and report the size in settings where the "open cache folder" row already
is.

## 5 — Batch export

Collections exist and targets exist, and exporting twenty kept wallpapers means
twenty trips through the export sheet. One target applied to a whole collection —
and one picture to every monitor — is the obvious payoff of the two features
that just landed.

## 6 — Tests that touch the UI

All 123 tests are Rust. Every QML regression so far — blank tiles, an invisible
scrollbar, a sheet collapsed to its header, dock buttons wired to nothing — was
caught by a person looking at the screen, which is the least scalable test suite
available.

The IPC surface is already a test harness: `app layout`, `perf scroll`,
`catalog count`, `app crop state`. A script that drives it and asserts on
`perf report` would have caught every one of those.

## 7 — Surface `doctor` in the app

A dead source currently looks like an empty gallery to the user and like a
working app to the developer. `doctor` already knows; nothing shows it. A line
in settings, and a chip on a source that failed its last crawl.

## 8 — Move the perf harness out of the shipped app

`Perf`, the blank counters, the scripted sweeps and the frame budget are
compiled into the product. They earned their place during development and they
do not belong in what a user runs — behind a build flag or a debug config.

## 9 — Duplicate grouping

`phash` is computed for every thumbnail and stored, and the index for it exists.
Nothing reads either. Near-identical rows from three sources sit side by side in
the wall. Group them, show the highest-resolution copy, and let the rest fold
underneath it.

## 10 — Results show up faster (asked 2026-10-21) — **done 2026-10-21**

The user wants search results on screen sooner. Measure first: time from the
keystroke to the first result drawn, and to the full page, for local catalogue
hits and for live source fetches. Then fix the slow part. Likely fixes: show
catalogue hits at once and add each source's results as they arrive instead of
waiting for the slowest one, send the first page before the rest, and show
thumbnails as they decode. Add the numbers to `PERF.md`.

Done: first rows from the sites **12 s → 0.5 s** after typing, 90% of matches
by ~2 s (`PERF.md`, "Search results"). Three waits, none of them the network:
every manifest re-parsed per source lookup (~5 s a round), every source's URLs
built before any page was fetched (one slow tag lookup held all), and
`catalog.changed` documented and listened for but never sent — plus `extend`
queued behind thumbnail fetches for the shared permits.

## Standing rules learned the hard way

- **Shared constants need an owner, like shared files do.** Two migrations
  independently claimed schema version 2 and the second one silently did not
  run. Lane rules stop file conflicts; they did not stop this.
- **Do not add sources or layouts until 1–5 are done.** Breadth is running ahead
  of depth: eight sources and six layouts, no local files, no batch, no dedupe.

---

# What's weak — 2026-09-22

Slice: the **client's query path, the settings layer, the caches on disk, and
the lenses' seams with the daemon**. Not looked at: the board, the export
pipeline, the extension API, the sources' individual adapters. Everything below
was measured or read on this machine today; anything unverified says so.

## 1 — [impact: high · effort: M · risk: low] Applying a result costs more than producing it

WHERE: `services/Catalog.qml:_queryRemote`, the `root.ratios = payload.ratios` line.
EVIDENCE: `app probe` → `catalog.timing`, measured: `kind:wallpaper` daemon 141 ms,
applying it 227 ms of which the ratios assignment is 114 ms. A **21-row** answer
still spends 47 ms there — the cost is the PREVIOUS array of 165k numbers being
collected, not the new one being built.
WHY IT MATTERS: it is now the larger half of every filter change, and it does not
shrink as you narrow the search — which is exactly when a user expects it to feel
instant. The fix is not a faster array but no array: masonry needs a ratio per
item, grid, contact sheet and compact do not, so the daemon should not send them
and the client should not hold them for three of the four layouts.

## 2 — [impact: high · effort: S · risk: low] ~~The thumbnail store never forgets~~ — **wrong, and fixed**

CORRECTION: the claim above was wrong. `trim_cache_dir` has been evicting
thumbnails (3 GB) and media (512 MB) hourly and at startup all along — the
`grep` that "found nothing" was for the wrong words. The 3.1 GB measured is the
cap working, not growth nobody stopped.

What WAS true: none of it was visible or adjustable, and one cache had no cap at
all — **the HTTP body store, 1,007 MB in 8,817 files**, a quarter of everything
quarry keeps, which nothing would ever have removed.

DONE 2026-09-22: `storage` reports every cache with sizes and counts,
`cache_clear` empties one or all of them, `set_budget` saves a limit and trims
to it immediately, the HTTP cache has a 256 MB default, and Settings → Storage
shows the lot. A limit is a setting now rather than an environment variable
compiled into the daemon.

## 3 — [impact: high · effort: S · risk: med] A stored setting can never be changed by a new default

WHERE: `modules/common/Prefs.qml`, `modules/lens/builtin/morse/Main.qml`.
EVIDENCE: two of them bit on the same afternoon. `browserSourceInApp` and Morse's
`autostart` both had explicit values written into `prefs.json` / `lenses.json`, so
flipping the default changed nothing for the one machine that mattered — the one
that had already run quarry. Both needed a hand-rolled one-time flag
(`browserSourceReviewed`, `autostartReviewed`) to lift.
WHY IT MATTERS: every future default change has this trap, and the workaround is
copy-pasted per setting. There is no settings version, no migration list, nothing
that says "this default changed, and here is what to do with an old value".

## 4 — [impact: med · effort: S · risk: low] Test instances write to the real settings file

WHERE: `modules/common/Prefs.qml:21` — ``dir: `${Quickshell.env("HOME")}/.config/quarry` ``.
EVIDENCE: a headless instance launched with `XDG_CONFIG_HOME` pointed at a temp
directory still wrote to `~/.config/quarry/prefs.json` — it changed two of the
user's real settings today.
WHY IT MATTERS: the project's own hands-off testing route cannot isolate config,
so every measurement run risks editing what the user is using. One line: respect
`XDG_CONFIG_HOME`, fall back to `$HOME/.config`.

## 5 — [impact: med · effort: M · risk: low] A source that stops working says nothing

WHERE: `quarryd/src/main.rs` — `doctor` exists and probes every source ON DEMAND;
nothing records a failure that happens while you browse.
EVIDENCE: failures are per-item (`hidden` with reason `fetch`) and forgiven after
24 h; there is no per-source record anywhere — `grep` for last_error/health over
`quarryd/src` finds nothing.
WHY IT MATTERS: a site that starts answering 403 shows up as an empty wall and
nothing else. (Being built now — the validator task.)

## 6 — [impact: med · effort: M · risk: low] First usable screen takes ~1.9 s and nobody measures it

WHERE: cold `qs -p shell.qml` to a catalogue count over IPC.
EVIDENCE: **1,857 ms** headless with the software renderer (so it is a ceiling,
not the number on your GPU). `PLAN.md`'s budget table says first paint < 600 ms
and `PERF.md` has said "not yet instrumented" since Phase 0.
WHY IT MATTERS: it is the budget the project set itself and the only one with no
number against it, which is usually where the regression is hiding.

## 7 — [impact: med · effort: S · risk: low] Pornhub's words only exist on rows crawled since today

WHERE: the catalogue, `source = 'pornhub'`.
EVIDENCE: 30 of 5,505 rows carry tags — the 30 re-crawled after the mapper was
fixed. The other 5,475 have nothing but a title.
WHY IT MATTERS: search by performer or category is the point of the change, and
it is true for 0.5% of the library until something sweeps it. ~184 requests at the
host's rate limit.

## 8 — [impact: low · effort: S · risk: low] quarry-browser keeps a session it cannot clear

WHERE: `browser/Browser.qml` — the `WebEngineProfile` under `~/.local/share/quarry/browser`.
EVIDENCE: cookies now survive a restart (verified); there is no control anywhere
that empties it, and no private-window mode.
WHY IT MATTERS: the window is for adult sites among others. A session that can
only be cleared by deleting a directory by hand is a privacy feature missing its
switch.

## Looked at and fine

- **Daemon idle cost**: 0.0% of one core over 30 s, 32 MB resident. Nothing spins.
- **Dedupe passes**: 12 ms of a 325 ms query — optimising them changed nothing
  measurable, twice. Left alone deliberately (PERF.md Phase 8).
- **The protocol's page model**: `items` answers in 0.1 ms; paging is not a cost.
- **Morse's link state machine**: reaches `ready` with 60 chats in 12 s from a
  cold start, on the real backend.

## Could not check

- **Anything visual on a real display** — everything here was headless or over
  IPC, so nothing says whether the wall LOOKS right at 165k items on the GPU.
- **The board, exports, extensions** — outside the slice, not read.
- **Whether 1.9 s cold start is mostly quickshell or mostly quarry** — that needs
  a QML profiler run, not a probe.

---

# Sources — 2026-09-22

**71 → 169.** Ninety-eight new keyless sources, every one probed live before it
was written and then probed again through the daemon.

Method, because the count is only worth what the check behind it is:

1. A candidate table — endpoint, root path, field mapping — fed to a probe that
   fetches it **with quarry's own User-Agent** (`quarry/0.1.0 …`, not a browser
   string: quarry identifies honestly, and a source that only answers a lie is
   not a source quarry can use). It checks the endpoint answers, the body is
   JSON, the root resolves to rows, and the mapped `id` and `url` resolve on the
   first row.
2. Whatever passed became a manifest.
3. The daemon then probed all 169 itself (`doctor`), which is the real test: its
   fetcher, its parser, its rules.
4. Twenty were crawled for real — **20/20 put rows in the catalogue, 0 unusable**
   — and the fourteen whose picture URL is BUILT from a field had that URL
   fetched to confirm it is an image.

Result: **162 answering, 7 failing** — and all seven were already failing before
any of this (reddit 403, redgifs 401, xnxx/xvideos 500, youjizz 404, tnaflix and
porntrex answering 200 with nothing usable).

## What was rejected, and why

Twenty-six candidates passed the network probe and were still not shipped:

- **needs a second request per row** — the Met's search returns object ids, and
  Wellcome and MangaDex give a record whose picture is a separate lookup;
- **not pictures** — EOL and USGS return page links, EONET events, Open Notify
  names;
- **a duplicate with a filter on it** — wallhaven sorted by hot, openverse
  again, picsum twice, Cleveland sorted by date;
- **an id that cannot become a URL** — NASA EPIC needs a date split three ways;
  Cover Art Archive would be a wall of 404s, since most releases have no cover;
- **mock data** — dummyjson and fakestore are test fixtures, not catalogues.

`artic_search` was written, shipped, and then removed: its IIIF server answers
403 without a Referer, and the existing `artic` manifest already sends one.

## Two changes the additions paid for

- **`tags[].tag_name` and `a + b + c`** in the mapper (added for Pornhub) — a
  list of objects, and several lists at once.
- **`_key`** — a row from an id-keyed object now carries its key as a field,
  which is what makes Poly Haven's three asset types and Tabler's 5,148 icons
  mappable at all.

---

# Round 2026-09-29 — the seams

Slice: **the joins**, not the features — daemon against client, shipped files
against the copies actually running, a signal against its listener. Chosen
because all five bugs found on 2026-09-29 lived at one, and none of them was in
the code anybody would have reviewed.

**The finding behind the findings.** Every one of those five presented as
success. Not one logged an error, moved a counter, or failed a test:

| what was wrong | what the app reported |
|---|---|
| `Catalog.refresh()` did not exist — TypeError aborted the handler | switch saved, wall unchanged |
| `thumbReady` emitted, nothing connected | `thumbsCached` climbing |
| `no-tiny-pictures` hid 19,600 rows | `tileErrors: 0`, `tilesStarved: 0` |
| thumbnails black-on-transparent over a black tile | `tilesReady: 297`, `thumbsFailed: 0` |
| daemon running a deleted binary; user copies of scripts and lenses stale | version endpoint says the new number |

quarry is unusually well instrumented — `scriptHiddenCount`, `Perf.starved`,
`blanksOffscreen`, `lastThumbFail` all exist and are good. The gap is that
nothing READS them and says "this is wrong". That is one missing capability, not
five bugs, and it is what the top entries below buy.

## 1 — [impact: high · effort: S · risk: low] ~~Nothing checks the app against itself~~ — **done 2026-09-30**

WHERE: no such tool; the scans were written ad-hoc on 2026-09-29
EVIDENCE: three greps, one command each, found the shape of three of the five
bugs above. Calls to singleton methods that do not exist (clean today, only
because `Catalog.refresh` was fixed that morning). Signals declared and never
connected — still finds `Dispatch.sent`, `Dispatch.sendFailed`, `Scheme.reloaded`,
all genuinely dead, none extension API. User copies under
`~/.local/share/quarry/` that have drifted from the shipped file.
WHY IT MATTERS: QML resolves names at runtime and swallows the failure, so the
compiler cannot help and neither can the test suite. A `tools/lint-qml.sh` run in
`check()` turns a class of silent bug into a build failure. This is the cheapest
entry here and it pays for the next one too.

## 2 — [impact: high · effort: S · risk: low] The app cannot tell you it is running stale code

WHERE: `hello` response; `services/Lenses.qml`; `services/Scripts.qml`
EVIDENCE: three times in one day a fix was installed and not running — the daemon
held a deleted binary across a pacman upgrade (`exe -> /usr/bin/quarryd (deleted)`),
`~/.local/share/quarry/scripts/no-tiny-pictures.js` shadowed the shipped script
with a copy from 22 Sep, and the pornhub lens was a user copy of the same age.
Each cost a full debugging round that ended at "the code is right".
WHY IT MATTERS: the failure is indistinguishable from a bug in the fix, so it
burns the same time every release. `hello` already carries `version`; it should
carry a build id the client compares against the installed package, and a user
copy of a shipped script or lens should say when the shipped one is newer.

## 3 — [impact: high · effort: S · risk: low] A row hidden by a script is invisible to every diagnostic

WHERE: `services/Catalog.qml:_applyScripts`, `modules/gallery/AssetTile.qml`
EVIDENCE: `item: root.scriptHidden ? null : root.item` — a hidden row is not
merely undrawn, it is never asked for, so no request is made, nothing fails, and
no counter moves. 19,600 rows (a quarter of the catalogue) were hidden by one
script for days. `scriptHiddenCount` exists and is correct; nothing shows it.
WHY IT MATTERS: one line in the UI — "19,600 hidden by No tiny pictures" — turns
a multi-hour hunt into a glance. The counter is already there.

## 4 — [impact: med · effort: M · risk: low] A manifest change cannot reach rows already stored

WHERE: `sources/*.toml`, `quarryd/src/catalog.rs`
EVIDENCE: the fediverse adult mappings added 2026-09-29 (`sensitive`, `post.nsfw`
+ `community.nsfw`) apply only as rows are crawled. 11 instances' worth of stored
rows stay marked safe until a re-crawl. Generalises TASKS #7, which said the same
thing about pornhub's words — the second time this shape has been written down.
WHY IT MATTERS: it makes every mapping fix a half-fix, and the user cannot tell
which rows are stale. A "re-read stored rows against current manifests" pass
would settle both.

## 5 — [impact: med · effort: S · risk: low] Only 36 of pornhub's 243 categories actually push down

WHERE: `sources/pornhub.toml`, `Capabilities::categories`
EVIDENCE: the daemon validates a category name against the manifest's own
`[[sections]]` before sending it, because an unknown name answers HTTP 200 with
`{"message": "Category does not exist!"}` — which parses as "no results". The
manifest lists 36; `/categories` publishes 243. The other 207 silently fall back
to a word search, which is the behaviour this was meant to replace.
WHY IT MATTERS: the lens offers all of them. Needs an accepted-names list in the
manifest separate from the sections that drive the UI.

## 6 — [impact: med · effort: M · risk: med] No source states what it cannot answer about a row

WHERE: the `Item` record
EVIDENCE: 21,802 rows (22%) carry `w = 0`, and the value means two different
things — "an SVG has no pixel size" and "iTunes did not say". Nothing
distinguishes them, which is exactly what made the `>= 400` filter hide a quarter
of the catalogue. Only 356 rows are thumbed and still dimensionless, so the
daemon does fill this in — the gap is that 0 is used as both "none" and "unknown".
WHY IT MATTERS: every future numeric filter has the same trap waiting.

## 7 — [impact: low · effort: S · risk: low] Three signals nobody listens to

WHERE: `services/Dispatch.qml:104-105`, `Scheme.reloaded`
EVIDENCE: `Dispatch.sent`, `Dispatch.sendFailed`, `Scheme.reloaded` — declared,
emitted, never connected. Neither is extension API (`Host.*` and
`Extensions.extensionError` are, and are correctly left alone).
WHY IT MATTERS: small on its own; it is the same shape as `thumbReady`, which
cost a day. Entry 1 finds these automatically.

## Looked at and fine

- **Daemon idle cost** — 0.15% CPU, 19 MB RSS over 20 s with nothing asked of it.
- **Undefined singleton methods** — clean across Catalog, Client, Lenses, Scripts,
  Prefs, Perf, Slots, Toast, Sys, Host.
- **User copy drift** — no shipped script or lens differs from its user copy as of
  2026-09-29 (two were fixed that day).
- **Dimension backfill** — the daemon does measure w/h when it thumbnails.

## Could not check

- **How it feels at the user's DPI.** Every render here is offscreen at DPR 1;
  their wall asks for the 640 rung and this harness asks for 320. Needs their eyes.
- **Scroll performance on the real GPU** — software rendering only here.
- **Whether the 356 thumbed-but-dimensionless rows share a cause.**

---

## Round 2026-09-30 — entry 1 built

`tools/lint-qml.sh`, run by `check()` with `--strict`. Three scans, and building
it found two faults in itself and one new bug in the app.

**It did not catch its own motivating bug at first.** The `Catalog.refresh()`
call was written `root.refresh()` INSIDE Catalog.qml — a singleton calling
itself — and the first version only looked for `Catalog.foo(` from other files.
It reported "none" on a tree with the bug reintroduced. Self-calls are checked
now.

**Then it failed the build over a comment.** The note explaining that bug
contains the words `root.refresh()`, which the scan read as a call. Comments are
stripped before matching (awk, because a block comment spans lines). A linter
that fails on a comment is one that gets switched off.

**A correction to the 2026-09-29 round.** `Catalog.thumbReady` was reported there
as having no listener anywhere. It had three — `optional-lenses/pornhub/skins/
Watch.qml` and both tube skins. The claim came from grepping two files. Adding
the listener to ThumbImage was still right (the wall's own tiles were not
getting it) but the signal was never orphaned, and scan 2 correctly does not
flag it.

**New, found by the tool:** `Catalog.boardChanged_` is emitted when board items
land and nothing connects to it. `GalleryBoard` reconciles membership on a 120 ms
timer started BEFORE the async `refreshBoardItems()` it is waiting for
(`GalleryBoard.qml:648`), and its own comment at :294 describes the signal it no
longer listens to. A board whose fetch takes longer than 120 ms reconciles
against stale data. Baselined with that reason rather than fixed.

Verified by mutation, not by a green tick: reintroducing the `refresh()` bug
fails scan 1; adding an orphan signal to Toast fails scan 2 (exit 1); a drifted
user script is reported by scan 3; the clean tree exits 0.

---

## Round 2026-10-07 — one week on

Entry 1 of the previous round is built (`tools/lint-qml.sh`). 2-7 stand. What the
week added:

**The new top entry: nobody can tell which sources work.** 156 manifests ship;
106 have ever produced a row here. That is NOT 50 broken sources — the crawl
cursor table holds only 2 distinct queries, so most were simply never asked.
Which is the point: broken and never-asked look identical from inside the app,
and they looked identical to me too. Spot-probing three by hand gave three
different answers in under a minute — `artic` 200 and working, `gelbooru` 401
needing a key it does not have, `apod` unreachable. The app shows all three as
nothing at all. `doctor` exists and is still not surfaced (TASKS #7, written
before this backlog).

hqporner is the proof that this costs something real: it was half-broken —
listed, crawlable, thumbnails fine, playback dead — for long enough that the
user found it, not the software, and the cause was two unrelated one-line gaps.

**Failure messages that are plausible and wrong.** Both hqporner causes produced
"no video on that page" while the mp4 was in the markup: once because the URL was
protocol-relative, once because the page 404s without a Referer. Morse autoscroll
reported nothing at all. A negative that names what WAS seen — iframes found,
candidate URLs rejected and why — turns each of these from a debugging session
into a glance. Same shape as entries 1 and 3: the app has the facts and does not
say them.

**Staleness (entry 2) has now bitten four times**, including while writing this:
daemon started 23:11, package installed 23:30, `exe` reading `(deleted)`. It is
still S/low-risk and it is still unbuilt.

## From the shell session (2026-10-20): what the shell's wallpaper buttons need

The shell's Settings › Quick › "Random: Konachan" now goes through quarryd
(`~/.config/quickshell/ii/scripts/colors/random/random_quarry_wall.sh SOURCE`:
`search` a random page, `query`, `items` at a random offset, `export`, then
`switchwall.sh`). It works, but it had to work around four things — in order of
value:

1. **`sort:random` is the same order every time.** `query.rs` shuffles from the
   constant `0x9E3779B97F4A7C15`, so the first row never changes (the shell got
   `konachan:402164` four times in a row). Wanted: a `seed:N` term in the query
   DSL (same seed = same order, for walls that should stay put), and
   `sort:random` without one drawing a fresh seed per query. The shell now picks
   a random `offset` instead; it can drop that once this lands.
2. **`export` cannot say "the file as it is".** `{fit: "none"}` is refused with
   `missing field width`; the caller has to copy `w`/`h`/`ext` from the item into
   a full recipe. Wanted: an `original: true` recipe (or `fit: "none"` without a
   size) that writes the source file through unchanged, like a video's `verbatim`.
3. **A one-shot "random wallpaper" for scripts.** Four requests and a fifo-backed
   socat session in bash, for one picture. Wanted: either a `random` request
   (`{q, source?}` → an exported path) or a CLI, e.g.
   `quarry wallpaper --random --source konachan [--apply]`, so the shell, the
   launcher and keybinds can all call one thing.
4. **An osu! seasonal source.** The shell's second button ("Random: osu!
   seasonal", the osu! site's seasonal backgrounds) still downloads by itself
   because Quarry has no osu source; with one, both buttons go through Quarry.

Also worth a look: the Konachan source answers from `konachan.com` even with
`-nsfw`; the shell's old script used `konachan.net`, the SFW mirror. Check that
`-nsfw` really becomes `rating:safe` on that source.

**Answered 2026-10-20** (quarry side; the shell's scripts can now drop their workarounds):
1. `sort:random` draws a fresh seed per query; `seed:N` fixes the order (PROTOCOL.md grammar). The
   SQL order was also a poor shuffle for small catalogues (insertion order below rowid ~100k) — now a
   seeded permutation mod 2^31−1. Paging is unaffected: a result is stored with its order.
2. `export` takes `"recipe": {"original": true}` (or `{"fit": "none"}` with no size) and writes the
   file through unchanged, answering `verbatim: true` (PROTOCOL.md, export).
3. One request, `random` `{source?, q?, path?, crawl?, pages?}` → the exported path + item, and a CLI:
   `quarry wallpaper --random [--source S] [--query Q] [--path P] [--apply]` (applies with
   switchwall.sh --image). Tested against a private daemon: three runs, three different konachan
   originals (1920×1080 JPEG, 1500×844 PNG, 7680×4320 PNG).
4. `sources/osu_seasonal.toml` (kind wallpaper, one page). NOT probed live: osu.ppy.sh's Cloudflare
   answered 403 to this machine for every user agent on 2026-10-20 — the shell's own osu button fails
   the same way until it lifts. The fixture follows the shape random_osu_wall.sh parsed.
- Konachan: `-nsfw` does reach the site as `rating:s` (test added); live, 40 of 40 posts were `s`.
