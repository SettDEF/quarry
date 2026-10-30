# quarry wire protocol — v1

The contract between `quarryd` (Rust) and the QML front end. **This file is the
authority.** Both sides are written against it independently, so anything not
written here does not exist. If something is missing, it gets added here first.

## Transport

**A unix domain socket, newline-delimited JSON**, at

```
$XDG_RUNTIME_DIR/quarry/sock          (override with QUARRY_SOCK)
```

one JSON value per line, UTF-8, no embedded newlines.

This deliberately differs from Morse, which speaks WebSocket over loopback with
a token in `endpoint.json`. Morse is a plain `qml6` app and has no other option;
quarry runs under quickshell, which provides `Quickshell.Io.Socket`. A unix
socket needs no port, no handshake and no token — `$XDG_RUNTIME_DIR` is mode
0700, so the filesystem already answers the question the token was invented for —
and it drops a framing layer on a path that carries a megabyte of geometry per
query.

The daemon unlinks a stale socket on start, binds, and creates the directory
0700. A client that cannot connect falls back to reading `fixtures/sample.json`
directly and says so in the UI; it never blocks waiting for a daemon.

## Envelope

Three frame kinds, discriminated by `t`.

**Request** (client → daemon). `id` is a client-chosen positive integer, unique
while in flight.

```json
{ "t": "req", "id": 7, "m": "query", "p": { "q": "kind:wallpaper" } }
```

**Response** (daemon → client), one per request, echoing its `id`. **Responses
may arrive out of order** — match on `id`, never on arrival.

The daemon answers `query`, `items`, `item`, `sources`, `stats`, `hello` and
`extend` in order per connection, because `query` replaces the current result and
`items` reads it — and takes no permit for them, so a catalogue answer never waits
behind a thumbnail. Everything else — `thumb`, `export`, `search`, `more`,
`doctor`, `complete` — runs concurrently, bounded by a semaphore
(`QUARRY_CONCURRENCY`, default 24). That is not a detail: filling a screen of twenty thumbnails took
**7.9 s** when requests were answered one at a time and **1.2 s** when they were
not.

```json
{ "t": "res", "id": 7, "ok": true,  "p": { "queryId": 3, "count": 137 } }
{ "t": "res", "id": 7, "ok": false, "err": "unknown method: qeury" }
```

**Event** (daemon → client, unsolicited):

```json
{ "t": "ev", "m": "catalog.changed", "p": { "added": 240 } }
```

An unknown `m` is an error, never a silent no-op. An unknown field in `p` is
ignored, so adding one is backwards compatible.

## Methods — v1

### `hello` → handshake

Request `{ "client": "quarry-qml", "protocol": 1 }`
Response `{ "protocol": 1, "backend": "mock" | "live", "version": "0.1.0", "items": 137, "stale": false }`

`backend` is `mock` while the daemon serves a fixture rather than a crawled
catalog. The UI shows it, because a mock catalog that looks real is worse than
no catalog.

**`stale` means THIS PROCESS IS NOT THE INSTALLED BINARY.** A package upgrade
replaces the file while the old process keeps running from the inode it already
has — on Linux its `/proc/<pid>/exe` then reads `/usr/bin/quarryd (deleted)` —
so `version` keeps reporting the number that was installed, not the one that is
executing. Four separate debugging rounds here ended at "the fix is right and
does nothing", because an installed fix and a running fix look identical from
the outside.

The daemon records its own executable's identity at startup and compares it
against the path on every handshake. `stale: true` means: the answer to anything
you are about to ask comes from older code, and restarting the daemon is what
fixes it. It is advice, not an error — the daemon goes on serving, because
refusing to answer would be worse than answering from yesterday's build.

### `query` → run a query, get geometry

Request:

```json
{ "q": "", "kind": "", "source": "", "family": "", "repeat": 1 }
```

`q` is free text for now; the DSL (Phase 3) parses into the same shape, and
`repeat` exists so the perf harness can ask for a catalog N times the fixture
without anyone materialising one.

Response:

```json
{ "queryId": 3, "count": 752415, "ratios": [1.777, 0.75, ...], "ratiosFrom": 0 }
```

**`ratios` is the whole point of the split.** It is one number per result —
`w / h` — which is everything masonry needs to lay out every tile, and it costs
about 1 MB for 137k rows. Records are ~6.8 KB each in the client's engine
(measured — see `PERF.md`), so they are *never* sent in bulk. A `queryId`
invalidates on the next `query`; a stale `items` request answers `ok: false`.

**`ratios` IS CAPPED AT 100,000 PER FRAME, AND THAT IS NOT A STYLE CHOICE.**
A frame carrying one ratio per row of a 752,415-item catalogue is 10.3 MB of
JSON holding a 752,168-element array, and **QV4 segfaults parsing it**. The
threshold was bisected in pure JS with no socket involved: an array of 500,000
parses, 600,000 crashes the engine. It is not a stack overflow and there is no
JS error to catch — `JSON.parse` returns into a dead process, so the app died
about ten seconds into launch with a catalogue this size and could not be
debugged from inside itself.

So the response carries at most the first 100,000, `ratiosFrom` says where the
slice starts, and the client pulls the remainder with `ratios` below. Measured:
752,168 ratios in 8 chunks parse in **110 ms**, against 875 ms and a crash for
the single frame.

### `ratios` → the rest of the geometry, a slice at a time

Request `{ "queryId": 3, "from": 100000, "count": 100000 }`
Response `{ "queryId": 3, "from": 100000, "ratios": [ … ], "total": 752168 }`

`count` is clamped to 100,000 for the reason above. `total` is how many ratios
the result has in all, so a client knows when to stop asking without counting
on `count` from the query — a crawl can grow the result between slices.

A stale `queryId` answers `ok: false`: the result it described is gone and the
client should query again rather than stitch slices from two different walls
together.

### `items` → materialise a page of records

Request `{ "queryId": 3, "offset": 1500, "limit": 500 }`
Response `{ "queryId": 3, "offset": 1500, "items": [ Item, ... ] }`

`limit` is clamped to 1000. The client keeps a bounded number of pages and
evicts the rest; the daemon holds no per-client page state.

Every ranked result collapses copies of one picture: equal perceptual hashes,
and hashes within 5 bits of each other when the shape matches within 4% (icon
sources excepted — flat glyphs hash alike). They count toward `duplicates`.

### `locate` → where a row sits in a stored result

Request `{ "queryId": 3, "id": "redgifs:anguishedzigzagflies" }`
Response `{ "queryId": 3, "id": "redgifs:anguishedzigzagflies", "at": 17 }`

`at` is the row's offset in that result, or `-1` when it is not in it — an
ordinary answer rather than an error, since a result can legitimately not
contain a row. `queryId` 0 means the current result, as everywhere else.

The client's wall only knows the pages it has loaded, so "reopen this picture"
could only ever find rows near the top; the order lives in the daemon.

### `find` → a query that keeps nothing

Request `{ "q": "kind:photo cat", "kind": "", "source": "", "family": "", "offset": 0, "limit": 60 }`
Response `{ "count": 812, "offset": 0, "items": [ Item, ... ] }`

The same ranking and deduplication as `query`, with the records in the answer
and **no stored result**. `query` keeps one result for the whole daemon, shared
by every client, so a second window calling it silently invalidates the first
window's `queryId` and its paging starts failing with `stale queryId`. `find`
is for everything that is not the gallery — the board's library panel, scripts —
and costs a re-rank per page, which is why it is not the gallery's path.

`limit` defaults to 60 and is clamped to 1000. `thumbLocal` is filled where a
320 thumbnail is already cached, as with `items`.

### The `q` grammar

`q` is the query language, parsed daemon-side so it has exactly one
implementation. UI chips are folded into the same string before parsing, so the
avatar chip and typing `kind:avatar` are the same code path.

| form | meaning | example |
|---|---|---|
| `term` | free text over title, slug, tags, author, source — **from the start of a word** | `anime` |
| `"two words"` | a phrase, matched whole | `"cherry blossom"` |
| `key:value` | equality | `kind:wallpaper` |
| `key:a,b` | any-of | `source:wallhaven,danbooru` |
| `key>=n` `key<n` | comparison — `w h ratio bytes added` | `w>=3440` |
| `ratio:16:9` | aspect written as an aspect | `ratio:21:9` |
| `bytes>2mb` | sizes take `k`/`kb`/`m`/`mb` | `bytes>500k` |
| `flag` / `flag:true` | `animated nsfw tintable vector video moving` | `video` |
| `duration>n` | seconds of video — `secs` and `length` are the same key | `duration>30` |
| `-anything` | negates the term or predicate | `-nsfw`, `-source:danbooru` |
| `color:#rrggbb` + `dist<n` | dominant-colour match, distance 0–100 (default 25) | `color:#7aa2f7 dist<25` |

`video` is `family:video` — a file that has to be played. `moving` is looser and
means what a person means: a video **or** an animated GIF. Both are pushed down
to the sources that can answer them, in each one's own spelling (`video` on
Danbooru, `type:webm` on e621) — video is a fraction of a percent of any board,
so filtering for it locally returns empty screen after empty screen.

Free text is an index lookup, not a substring scan: `sun` finds *Sunset* and
*sunflower*, not *midsummer*. A word written with a leading number is indexed
under both forms, because booru tags are `1girl` and `4koma` and nobody types
the digit — `girl` finds them. Everything else in the table compiles to SQL,
except colour distance and `collection:`, which are applied to the rows the
query returns.
| `sort:…` | `new random large wide title` | `sort:random` |
| `seed:N` | a whole number; fixes `sort:random`'s order (same seed, same order). Without it every `sort:random` query draws a fresh one | `sort:random seed:42` |

With no `sort:`, results are **dealt out by source**: each source's rows stay
newest first, and the sources take turns (the `blend` preference — `round-robin`
one per turn, `weighted` one plus the source's weight, `shuffle` the turn order
from `seed`). Newest-first alone meant the last source crawled filled the whole
wall. `sort:new` is still plain newest first.

`color:` and `dist:` are one predicate, not two clauses: a colour without a
tolerance means nothing and a tolerance without a colour means less. An item
with no `dominant` recorded never matches — it has not been through the
pipeline, and guessing would put grey noise in the answer to "wallpapers that
fit my accent". A **known key with an unreadable value** (`color:blue`) is
reported in `unknown` too, for the same reason an unknown key is.

Clauses are ANDed; any-of lives inside a clause as `a,b`. **An unrecognised key
is returned in `unknown`, never silently dropped** — a query that quietly
matches everything is worse than one that says it did not understand. The rest
of the query still runs.

`query` therefore answers with two more fields:

```json
{ "queryId": 3, "count": 25, "ratios": [...], "sort": "relevance", "unknown": ["colour"] }
```

### `complete` → completion for a half-typed token

Request `{ "prefix": "source:d" }`
Response `{ "prefix": "source:d", "suggestions": ["source:danbooru"] }`

Keys while there is no colon, values from the **catalogue** once there is one —
so `source:` suggests only sources that actually have rows. Capped at 40 values:
a completion list is a menu, not a data dump.

### `item` → one record by id

Request `{ "id": "wallhaven:e82xxr" }` → Response `{ "item": Item }`

### `search` → crawl a source with the query pushed down

Request `{ "source": "wallhaven", "q": "forest w>=2560 ratio:16:9 -nsfw sort:new", "page": 1 }`

```json
{ "source": "wallhaven", "url": "https://wallhaven.cc/api/v1/search?q=forest&purity=100&atleast=2560x1&ratios=16x9&sorting=date_added&page=1",
  "fetched": 24, "added": 22, "duplicate": 2, "filteredLocally": 0, "unusable": 0, "hasMore": true }
```

The query is split: whatever the source can express becomes its own parameters,
and the rest is applied locally with the same matcher the catalogue uses. The
counts are the diagnostic — `filteredLocally` climbing means a predicate is not
being pushed down, and `url` is there because "danbooru: 500" is not actionable
while "danbooru: 500 for `<url>`" is.

**Words go to the site's own search**, never to a filtered front page:

- search APIs (wallhaven, Openverse, Wikimedia, the museums, DeviantArt,
  Iconify, AniList, Yandex, RedGifs `query=`) get the words as typed;
- tag boards resolve them to their real tags first, through the same
  autocomplete their search box uses (manifest key `[request] tag_resolver =
  "danbooru" | "gelbooru" | "moebooru" | "e621" | "philomena" | "eshuushuu"`,
  built-in for danbooru): the phrase as one tag when the site has it
  (`red car` → `red_car`), else one tag per word (`mountain lake` →
  `mountain` + `lake`). A word with no tag is dropped; a query with no tag at all
  is sent as typed and honestly answers nothing, never the front page;
- `bing`, `duckduckgo`, `searxng` and `google` search the whole web for images;
  `-nsfw` turns their SafeSearch on (`adlt=strict` / `p=1` / `safesearch=2` /
  `safe=active`), otherwise it is off. `searxng` is metasearch over Google, Bing,
  Brave and others, keyless, against the instance `$QUARRY_SEARXNG_URL` names;
  `google` is the Custom Search JSON API and only appears in `sources` when
  `$GOOGLE_CSE_KEY` and `$GOOGLE_CSE_CX` are both set — unset, it is absent
  rather than present and always failing;
- reddit: words use Reddit's search; `r/name` is that subreddit's feed, and
  `r/name words` searches inside it;
- a source with no search at all (Peapix) should be skipped for a query with
  words — `sources::text_search::skip_source` names the reason.

### `more` → the next page, for endless scroll

Request `{ "q": "kind:wallpaper", "sources": ["wallhaven", "danbooru"], "pages": 4 }`
Response `{ "added": 34, "fetched": 73, "exhausted": [], "failed": ["e621"], "endless": false }`

**With no words or tags in `q` it is the home feed**, and `endless` is true:
each site is asked for its newest (not a wordless relevance search, which
wallhaven answers with nothing), and a site that ran out starts again from page
one five minutes later, so the feed picks up what was posted since. A client
should never treat an endless answer as the end of the scroll.

`pages` (1–50, default 3) is how many pages each source contributes to this one
call. The per-source `pages` preference does **not** cap it: that preference is
the depth of an explicit `search`, and an endless scroll has no page limit.

`failed` lists sources whose page did not arrive or did not parse this time.
That is not the end of them — the cursor is given back, so the next call asks
for the same page again. Only `exhausted` means a source has nothing left.

The **daemon owns the cursor**, keyed by source and query text, so the client
never tracks pages — it asks for more when the scroll approaches the end and
rows appear. Sources are crawled in parallel, so this is one round trip however
many answer. A source that returns no new rows, or says it has no more pages, is
listed in `exhausted` and its cursor is retired; when every source is exhausted
the scroll is genuinely over.

### `enrich` → fill in what a listing could not say

Request `{ "id": "pfps.gg:97951-19378-wonder-of-u" }`
Response `{ "item": Item, "enriched": true, "related": ["…"] }`

A listing gives an image and an id. The item's own page gives the title, the
uploader, the tags it was filed under, and the site's own "more like this"
strip. That is worth one request when something is opened and forty wasted ones
during a crawl, so it happens on demand. The enriched row replaces the
catalogue's copy in place, keeping its position.

Verified live: `WonderOfU` by `gloomthunder`, tags
`anime, jojo-bizarre-adventure, jojo-manga`, 8 related.

### `doctor` → is every source still answering

Response `{ "sources": [ { "source": "wallhaven", "url": "…", "status": 200, "parsed": 24, "ok": true } ] }`

`ok` requires both a 200 **and** rows that parse: a source that answers 200 with
markup we no longer understand is broken, and must be named here rather than
showing as an empty gallery.

### `cancel` → withdraw requests this connection no longer wants

Request `{ "ids": [41, 42, 57] }` — request ids sent earlier on the same
connection. Response `{ "cancelled": 2 }`. Only `thumb` requests can be withdrawn;
a withdrawn one is never answered, so the client forgets its callback first. The
app sends this when the search changes, so the old screen's thumbnails stop
holding permits the new screen's need.

### `thumb` → cache a thumbnail locally, and answer with its path

Request `{ "id": "danbooru:12091270", "size": 320 }`
Response `{ "path": "~/.cache/quarry/thumbs/danbooru-12091270-320.jpg", "cached": false, "phash": "c3c3c3dbc2c3c7e6", "dominant": "#705050" }`

This is also the fix for hotlink-blocking sources: `cdn.donmai.us` and the Art
Institute's IIIF host both answer **403** to a direct request from the view while
their metadata APIs are fine. The daemon fetches; the view loads a file.

The extension follows the content: JPEG for a photographic (opaque) source,
PNG when the decoded image has an alpha channel (icons, rasterised vectors) so
transparency survives. Decided from the image's own colour type, never from
`kind`/`family` or the source URL. Thumbnails written before this existed are
lossless WebP and are still found and served — nothing is deleted on its own;
see `thumbs_clear`.

### `export` → apply a recipe and write the file

Request `{ "id": "…", "recipe": { "width": 184, "height": 184, "fit": "cover", "gravity": "smart", "format": "png", "quality": 92, "radius": 0, "background": "#00000000" }, "path": "~/Pictures/quarry/{kind}/{slug}-{w}x{h}.{ext}" }`

Response `{ "path": "…/cat-184x184.png", "bytes": 52064, "human": "50.8 KB", "recipe": { … } }`

`fit` is `cover|contain|stretch|none`, `gravity` is
`center|north|south|east|west|smart` (entropy — where the subject is), and the
recipe is echoed back so the UI can print exactly what was applied. An existing
file is never overwritten: the path gains ` (2)`.

**A video is exported as itself.** `fit`, `gravity` and `radius` have no
meaning for something that moves, and re-encoding one would mean writing a
single frame out as a PNG, so the file is written through byte for byte. The
response says so rather than letting the caller assume a crop it did not get:

Response `{ "path": "…/kyoto-1920x1080.webm", "bytes": 15066547, "human": "14.4 MB", "width": 1920, "height": 1080, "duration": 15.82, "verbatim": true }`

`width`, `height` and `duration` are what `ffprobe` read from the file, not
what the source claimed, and they are written back to the catalogue. A caller
that sees `verbatim` should also pick a different apply step: a still wallpaper
is set by a script that regenerates the palette, a moving one by `mpvpaper`.

**Any file can be asked for as itself**: `"recipe": { "original": true }` (or
`{ "fit": "none" }` with no `width`) writes the source file through unchanged,
picture or video, and answers with `verbatim: true` the same way. Pictures land
under `~/Pictures/quarry/{kind}/` unless `path` says otherwise; `width`/`height`
are the catalogue's for a picture.

### `sourcePrefs` / `setSourcePrefs` → what you have decided about each source

Request `{}` → `{ "sources": [ { "id": "wallhaven", "category": "wallpapers", "enabled": true, "pages": 0, "weight": 0, "video": false } ], "blend": "round-robin", "seed": 0, "path": "~/.config/quarry/sources.json" }`

Write with `{ "id": "e621", "enabled": false }`, `{ "id": "wallhaven", "pages": 2, "weight": 5 }`,
or `{ "blend": "shuffle", "seed": 424242 }`.

Deliberately separate from `sources`, which reports what the catalogue *holds*:
a source you switched off still has rows and still belongs in the filter, it
just stops being crawled. Two questions, two methods — and the UI reads the
first constantly and writes the second rarely.

`pages` is the lever that matters: a source set to 1 still appears and still
contributes, it just stops being a quarter of every crawl. `weight` sorts who
is asked first; ties keep their declared order. `blend` is `round-robin`
(each in turn), `weighted` (the weights strictly) or `shuffle` (reordered from
`seed` — the same seed gives the same wall tomorrow).

Preferences can never stop the daemon: an unreadable file is defaults with a
line on stderr.

### `restore` → stop refusing rows the daemon hid on its own

Request `{ "scope": "auto" }` — `auto` (everything the daemon decided),
`fetch`, or `legacy`.
Response `{ "restored": 1032, "scope": "auto", "before": [ … ], "remaining": [ … ] }`

Hiding records **why**: `user` (somebody chose it), `fetch` (the picture would
not come), or `legacy` (hidden before the two were told apart). This forgets
the daemon's own decisions and never touches a person's — no scope reaches
`user`. It cannot un-delete, because hiding deletes the row; what it lifts is
the refusal, so the pictures return as their sources are crawled again.

`stats` reports the same tally under `hidden`, so a client can offer this only
when there is something to offer.

### `thumb_path` → a thumbnail for a file on disk

Request `{ "path": "/home/you/Pictures/dune.png", "size": 256, "spec": "freedesktop" }`
Response `{ "path": "~/.cache/thumbnails/large/<md5>.png", "cached": false, "w": 3840, "h": 2160, "phash": "…", "dominant": "#705a3f", "spec": "freedesktop" }`

`thumb` is catalogue-shaped and takes an item id; a desktop mostly has a path.
Same ladder, same encoder, no network and no catalogue lookup.

`spec: "freedesktop"` files it by the standard's rule — MD5 of the file URI,
under a size-named directory, as PNG — so every other app on the desktop finds
it. Without the flag it goes in quarry's own cache as WebP, keyed on path AND
mtime so an edited file stops serving the old picture. The spec has no mtime in
its name, so that guard is the caller's there, which is what the standard
intends.

### `similar` → the same picture, elsewhere in the catalogue

Request `{ "id": "danbooru:12091270", "limit": 300, "maxDistance": 12 }`
Response `{ "queryId": 4, "count": 22, "ratios": [ … ], "sort": "similar", "scanned": 28498, "hashed": 1253 }`

Answers in the shape of a `query` because it IS one — it replaces the result
index, so paging, ratios and layout work unchanged. A linear scan over the
perceptual hashes already in memory.

With `"web": true` it also asks Yandex for similar images of the picture,
adds those rows to the catalogue, and puts them after the catalogue's own
matches; the answer gains `"web": <n>` and `"webError": "…"` (empty when the web
part worked). A picture with no perceptual hash still gets the web results
rather than an error, because the web does not need one.

`"method"` chooses how to look (default `look`, or `all` when `web` is true):

| method | asks | notes |
|---|---|---|
| `look` | the catalogue's perceptual hashes | re-encodes, resizes, light crops |
| `web` | Yandex look-alikes | a video is shown to Yandex by its thumbnail |
| `native` | the picture's own site | wallhaven `like:` then its tag ids; tag sites the picture's most distinctive tags (rare in the catalogue, seen at least twice), together then alone; text sites the title's words. The first rung with 8+ pictures wins, else the fullest. |
| `all` | all three at once | catalogue first, then the site's, then the web's |
| `dupes` | the same file again | the catalogue at `maxDistance` 2 rather than 12 |
| `sites` | where else it appears | Yandex's "pages that carry this", with the page and the domain |
| `bigger` | a larger copy of it | the same list, kept to copies larger than yours, biggest first |

`sites` and `bigger` answer `copies` and `copiesError` beside the usual fields.
Yandex is asked by URL when the row has a public one, and **by upload** — the
bytes posted raw to its image-download endpoint — when it does not, which is
what makes a local file, a hotlink-protected host or a video's poster frame
work at all.

The answer gains `"native": <n>`, `"nativeHow": "safebooru tagged a + b"` and
`"nativeError"`. With only `web`/`native` and nothing found, it is an error that
names why.

With `"records": true` it stores nothing and answers
`{ "count": 22, "items": [ Item, ... ], "scanned": 28498, "hashed": 1253 }`
instead — the `find` of similarity, for windows other than the gallery.

`scanned` and `hashed` are the honest denominator: an empty answer is "nothing
alike" only if `hashed` is large. Otherwise it is "nothing measured yet".

### `stream` → a playable local URL for a stream the player cannot fetch

Request `{ "id": "pornhub:123", "url": "https://…/720p/master.m3u8" }`
Response `{ "url": "http://127.0.0.1:42371/s/9549e5b1", "upstream": "https://…" }`

The daemon listens on loopback and re-requests upstream with the page's
Referer — which a media player has no way to send, and without which these
hosts answer 410/412. Playlists are rewritten so their segments come back the
same way, keeping their file extension (ffmpeg refuses a segment URL without
one). Playback starts immediately; `media` downloads the whole file instead and
is what "save this" uses.

### `media` → a video as a local file, for a player that could not stream it

Request `{ "id": "wikimedia:123" }`
Response `{ "path": "~/.cache/quarry/media/wikimedia-123.webm", "cached": false, "bytes": 73961974 }`

The viewer streams a clip's URL directly and calls this only when that fails.
The daemon's client sends the source's Referer (cdn.donmai.us answers 403
without it) and waits out 429s. For Wikimedia Commons it tries the site's
720p/480p/360p transcodes before the original. Files stream to disk; originals
over 400 MB are skipped, and the cache is trimmed to 2 GB, oldest first.

### `history` / `history_add` / `history_clear` → what you did

Request `{ "kind": "search", "q": "cat", "limit": 200 }`
Response `{ "count": 2, "entries": [ { "at": 1789650000, "kind": "search", "value": "cat", "item": "" } ] }`

`kind` is `search`, `open` or `export`; `value` is the query or the target;
`item` is the row it happened to, where there is one. `history_add` takes the
same three and moves a repeat up rather than adding a line; `history_clear`
takes a `kind` (empty means everything) and answers how many rows went. The
table is capped at 2,000 entries, trimmed on write — history is a way back to
something, not a second catalogue.

### `renditions` → the qualities a video has

Request `{ "id": "wikimedia:123" }`
Response `{ "id": "wikimedia:123", "renditions": [ { "label": "Original", "url": "…", "w": 1920, "h": 1080, "bytes": 0 }, { "label": "480p", … } ] }`

The row's own file, a playable `sample` beside it, Wikimedia's transcodes
(probed, because 720p exists for some files and not others), and whatever the
page declares for rows that are a still of a video elsewhere. `media` takes the
chosen `url` and caches that file separately, so switching quality does not
overwrite the other copy; a `url` from a different site is ignored.

### `backfill` → hash rows nobody has looked at

Request `{ "limit": 200, "network": true }`
Response `{ "wanted": 200, "hashedNow": 27, "fromCache": 0, "fromNetwork": 24, "failed": 3, "reasons": [ … ], "coverage": 1638, "total": 28686, "remaining": 27048 }`

Hashes are a by-product of making a thumbnail, so a crawled-but-unbrowsed
catalogue has almost none — and `similar` and dedupe can only see what is
hashed. A cached thumbnail costs a decode and no network; the rest fetch the
small preview.

The worklist round-robins BY SOURCE. Taken in order it spent every batch on one
refusing source and never reached one that answered.

### `reverse` → where else this picture exists

Request `{ "id": "danbooru:12091270", "provider": "saucenao" }`
Response `{ "provider": "saucenao", "searched": "…", "matches": [ { "similarity": 87.0, "title": "…", "urls": [ … ] } ], "shortRemaining": 4, "longRemaining": 99 }`

`provider` is `saucenao` (needs `$SAUCENAO_API_KEY`), `iqdb` (no key, form
POST, stricter rate limit) or `yandex` (no key). The image is sent by URL
rather than uploaded: a catalogue row is already hosted.

Pick by what you are searching for. SauceNAO and IQDB index boorus and Pixiv
and are very good at drawn art and blind to everything else; Yandex indexes the
open web, which makes it the one worth asking about a photograph, a screenshot
or a painting. Yandex publishes no similarity score — it ranks rather than
scores — so its matches carry no `similarity` field rather than an invented one.

Yandex costs two requests, which is a fact about the site and not a workaround:
`rpt=imageview&url=…` returns a page carrying a `cbir_id` and an EMPTY result
list, because the matches are fetched afterwards by its own JavaScript. Asking
again with `cbir_id=…&cbir_page=similar` renders them server-side, in the same
`serpList.items.entities` shape the text search already parses.

Deliberately NOT a `Source`. That trait answers a text query and `SourceQuery`
has nowhere to put a picture — see `SOURCE_TRAIT_PROPOSAL.md`.

For SauceNAO the remaining quota is part of the answer: zero matches with zero
`shortRemaining` is "used up", not "nothing alike". For IQDB a genuine no-match
carries `noMatchReason`, distinct from a parse failure, which is an error.

### `boards` → pictures arranged, not just kept

Request `{ "action": "list" }` · `{ "action": "items", "name": "Colour study" }`
Response `{ "boards": [ { "name": "Colour study", "items": 5, "viewX": 0, "viewY": 0, "viewZ": 1 } ] }`

`action` is `list`, `create`, `items`, `place`, `remove`, `view`, `rename`,
`delete`, `container` or `uncontain`.

A collection is a set; a board is a set WITH A LAYOUT. `place` writes one
picture's whole row — `x`, `y`, `w`, `h`, `angle`, `hflip`, `vflip`, `z`,
`sharp`, `container` — so a field left out of the payload is written as its
default, not left unchanged.

Geometry is in BOARD units, not pixels: the view carries its own offset and
zoom, so a board laid out on a 4K screen opens correctly on a laptop. Rows are
keyed by quarry id, which is what makes a board survive the catalogue being
re-crawled underneath it.

`container` groups pictures inside a named outline. Deleting one sets its
members loose rather than deleting them — changing your mind about a grouping
must not cost you the pictures.

Every write emits `board.changed`, so the board application and quarry stay in
step without either polling.

### `adopt` → take in a file already on this machine

Request `{ "path": "/home/you/pic.png", "nsfw": false, "tags": ["4chan-wg"], "title": "…", "page_url": "…" }`
Response `{ "item": { "id": "local:/home/you/Pictures/ref.png", … } }`

The row a dropped file becomes: the same `file://` shape the `local` source
produces, so it gets a thumbnail, a dominant colour and a perceptual hash like
anything else and can be found again by searching. Percent-encoded paths are
decoded, since a drag from a file manager sends a URI.

### `sources` → what can be queried

Response `{ "sources": [ { "id": "wallhaven", "label": "Wallhaven", "kinds": ["wallpaper"], "items": 24 } ] }`

### `sourcePrefs` / `setSourcePrefs` → what is enabled, and the adult switch

`sourcePrefs` answers
`{ "sources": [ { "id", "category", "enabled", "pages", "weight", "video" } ], "blend", "seed", "adult", "path" }`.

`setSourcePrefs` takes any of `{ "id", "enabled", "pages", "weight" }` for one
source, and any of `{ "blend", "seed", "adult" }` globally.

#### `adult` is enforced here, not asked for per query

**`adult: false` is a promise the daemon keeps, not a filter the client applies.**
While it is off:

- every `query`, `find`, `items` and `similar` answer excludes rows flagged
  `nsfw`, whatever the query text says — a `nsfw:true` typed into the bar
  returns nothing rather than overriding it;
- `more` and `search` will not crawl a source declared `adult`, so nothing new
  arrives either.

It is a daemon setting because the alternative was a client one, and that was
not safe. The app used to append `-nsfw` to the query string when the switch
went off: a predicate like any other, in a box the user can edit, which any
later `Catalog.query = …` silently dropped. Turning the switch off hid what was
on screen and nothing more — the next chip, lens or history entry brought it
straight back, out of the LOCAL catalogue, with no network involved. A switch
whose promise can be undone by clicking a tag is not a switch anybody should
trust.

Rows already crawled are hidden, not deleted: turning it back on restores them
without re-crawling. `adult` defaults to **false**.

### `purge` → delete matching rows, and the files cached for them

Request `{ "q": "nsfw:true" }`
Response `{ "rows": 606452, "files": 812, "bytes": 24117248 }`

Hiding and deleting are different promises, and both are wanted. The adult
switch HIDES: it appends `nsfw:false` to every query, so the rows stay and come
back intact when the switch goes back on. `purge` DELETES: the rows go from the
catalogue, their text index entries go, the rows referencing them in boards,
collections, slots and history go, and the thumbnails cached for them are
removed from disk. Only a fresh crawl brings them back.

It takes a QUERY rather than a flag, because "adult" is not the only thing
anyone wants gone — a source that turned out to be junk, a botched import, one
tag. `nsfw:true` is then simply the query the settings panel sends, and the DSL
stays the one way to say which rows are meant.

**The adult gate is lifted for the match, and only for it.** Every query is
normally rewritten with `nsfw:false` appended while the switch is off, so
`purge` with `nsfw:true` would otherwise match nothing at all — the one request
that must see the hidden rows is the one asking to delete them.

**An empty query is refused** (`ok: false`). `purge` with no predicate means
"delete the catalogue", which is never what a caller meant to type, and the one
case where guessing is unrecoverable. Callers that really want that use
`forget`.

### `thumbs_clear` → reclaim disk from an old thumbnail format

Request `{ "ext": "webp" }` (default `"webp"` if omitted)
Response `{ "ext": "webp", "removed": 15573, "bytesFreed": 1366571008 }`

Explicit and opt-in — nothing is removed unless this is called. Deletes every
file in quarry's own thumb cache ending in `.<ext>`; a matching row is simply
re-fetched and re-encoded the next time it is asked for. Meant for `"webp"`,
the format every thumbnail was written as before JPEG/PNG-per-image landed.

### `stats` → daemon-side counters

Response `{ "items": 137, "queries": 12, "uptimeMs": 40213, "backend": "mock" }`

## `Item`

Exactly the record in `ITEM.md`; the daemon validates the fixture against it on
load and refuses to start on a malformed one, so a contract violation is a
startup error rather than a blank tile.

## Events — v1

| `m` | `p` | when |
|---|---|---|
| `catalog.changed` | `{ "added": int, "source": str }` | a crawl (`more`, `search`) filed new rows — sent per page as each site answers; the client grows its open result (`extend`) |
| `index.progress` | `{ "source": str, "page": int, "found": int }` | a crawl is running (Phase 6) |
| `index.done` | `{ "source": str, "added": int, "error": str? }` | a crawl finished |

## Not in v1, and named here so nobody invents them

`export.*`, `targets.*`, `collections.*`, `subscribe`. They arrive with the
phases that need them, in this file first.

## Lenses — a contract inside the client, not on the wire

A source adapter fetches rows; a **lens** is a screen built for one site. It is
what quarry called an *extension*, plus the two things an extension needed and
did not have: the sources it applies to, and **skins**. `services/Lenses.qml` is
the registry, `modules/lens/Lens.qml` the base type, `modules/lens/LensHost.qml`
the surface it draws on. Nothing here crosses the socket — it is written down
beside the wire because both sides of the app read it.

### What a lens ships

A directory with a manifest and the QML it names:

```json
{ "id": "fourchan", "name": "4chan", "version": "1.0",
  "description": "…", "author": "…", "icon": "forum",
  "entry": "Main.qml",
  "sources": ["4chan"],
  "rail": true,
  "defaultSkin": "quarry",
  "skins": [ { "id": "quarry", "name": "Quarry", "entry": "skins/Quarry.qml" },
             { "id": "yotsuba", "name": "Yotsuba", "entry": "skins/Yotsuba.qml" } ],
  "enabledByDefault": false }
```

`lens.json` is read **on its own, before a line of QML loads**, so a lens is
listed, described, its skins named and its rail row drawn while it is switched
off. `sources` is which adapters it claims — `["*"]` for any, `[]` for a lens
nothing auto-opens; `Lenses.openFor(sourceId)` is how a result row reaches its
site's own reader. `rail` asks for a row in the navigation rail.

Search paths, later winning on an id collision:

| path | |
|---|---|
| `<config>/modules/lens/builtin/` | shipped |
| `<config>/extensions/` | legacy packs, `manifest.json` |
| `~/.local/share/quarry/extensions/` | legacy, user |
| `~/.local/share/quarry/lenses/` | user |

### The lens object

`entry` declares a `Lens` as its root. It holds the **state** — where you are,
what has been fetched, what it is doing — and the app fills in `lensId`, `name`,
`version`, `lensDir`, `skinId` and `settings` from the manifest and from disk.

| member | |
|---|---|
| `open(ctx)` / `close()` | the host calls these; `ctx` is whatever sent you here |
| `isOpen`, `screenTitle`, `canGoBack`, `backRequested` | what the host chrome needs |
| `settings` / `saveSettings(obj)` | persisted per lens, beside the enabled list |
| `menuItems`, `contextMocks`, `overlay`, `settingsPage`, `shortcuts` | contributions, unchanged from the extension API |

A lens reaches the app through `Host`, `Catalog`, `Client`, `Sys` and `Toast`,
never into views — delegates are recycled and layouts swap at runtime.

### Skins

A skin is a named look, a `LensSkin` created with `lens` already set and filled
to the content area. **Skins draw; they never fetch.** The one that is on is
destroyed and another built when you switch, so everything you had navigated to
survives it — which is what makes a second skin cheap, and why a skin is free to
look nothing like the app. The default skin uses `Appearance.colors.*`,
`elementMoveFast` and ii surfaces; a site skin may use literal colours, and that
is the point rather than a lapse.

Chosen with `Lenses.setSkin(id, skinId)`, persisted per lens, falling back to
`defaultSkin` and then to the first declared. A skin that will not load falls
back to `defaultSkin`; if that fails too the lens is closed and said out loud.

### Failure is contained

A manifest that is not JSON, a component that will not compile, a `createObject`
that returns null and a skin that errors are each caught, recorded on the entry
as `error`, and reported once. A broken lens is listed with its reason and never
takes the window with it.

### `Extensions` is a shim

`services/Extensions.qml`, `modules/widgets/Extension.qml` and
`ExtensionHost.qml` now forward to the lens system so the call sites that still
say `Extensions` keep working. Nothing new should be written against them.
