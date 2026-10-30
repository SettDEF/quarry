# quarry — plan

**Find, fit and apply pictures for every image slot on your desktop.**
See `README.md` for what the app is; this file is how it gets built.

The unit of work is the **slot**, not the picture: a size, an aspect, and a
background the result will be seen against. Finding a picture is easy; fitting
it to the slot is the work, and it is what everyone currently does by hand.

```
   sources        ──►  catalogue      ──►  query        ──►  slots
   wallhaven           sqlite + FTS5      a real DSL        wallpaper (per monitor,
   pfps.gg             + phash + colour   kind:/ratio:      real pixels)
   reddit (any sub)    + thumbs           w>= h>= color:    steam avatar 184/512
   deviantart                             source: -nsfw     discord avatar/banner
   danbooru                               sort: fuzzy       twitch / x / github
   museums, AniList                                         icons, favicons, covers
   Iconify, jsDelivr                                        anything you define
   Poly Haven, BlenderKit
   local folders
   (extensions)
```

Two pluggable contracts hold the whole thing up: a **source adapter** and an
**export target**. Both are data or a single file. Adding "my NAS" or "Mastodon
header" is never a refactor.

## Which template

**The app is Rodded.** `../Rodded` is the template — its QML module, its widget
vocabulary, its palette plumbing, its extension system, its `run.sh`/`PKGBUILD`.
Fork it and delete Reddit.

`../Morse` contributes exactly one thing and nothing else: the shape of its Rust
daemon (`morsed` — tokio + WebSocket + a `PROTOCOL.md` that both sides are
written against). None of Morse's UI comes near this project.

## The name

**quarry** — you quarry pictures out of many sources, and *query* is sitting
inside the word. It started as `pfpql`, which said "Steam profile picture" about
an app that turned out to be a picture engine for every image slot on the
desktop.

The query language is the product, and it is the same bar whether the answer is
a wallpaper or a 184px avatar:

```
anime kind:wallpaper ratio:21:9 w>=3440 -nsfw sort:new
cat kind:avatar source:pfps.gg animated:true
kind:wallpaper color:#7aa2f7 dist<25 sort:random      # matches my current accent
```

The `color:`+`dist:` predicate is worth building early: the daemon stores a
dominant colour per image, so "wallpapers that fit the palette tinct currently
has on screen" is one query. On a wallpaper-themed desktop that is the feature
people notice.

## Front end: Rodded, hosted by quickshell

`../Rodded` is 80% of the UI already — a Material 3 QML gallery that follows the
tinct palette, with masonry wall, theater view, filters, search, settings and an
extension system. Copy the module, delete Reddit.

| copy verbatim | becomes |
|---|---|
| `Appearance`, `Scheme`, `ColorUtils` | live palette that recolours with the wallpaper |
| `Prefs` | persisted settings |
| `MediaWall`, `WallTile` | the gallery — masonry, real aspect ratios, GIFs on hover |
| `TheaterView`, `MediaOverlay` | full-screen preview and stepping |
| `FeedHeader`, `PillTabBar`, `FilterSheet`, `SearchView` | query bar, chips, source tabs |
| `SettingsView` + `SettingRow/Card/Slider/Switch/TextField` | target + profile editor, free |
| `Host`, `Extension`, `Extensions`, `ExtensionsView` | third-party **sources** drop in as extensions |
| `Toast`, `Snackbar`, `LoadingIndicator`, `PagePlaceholder` | feedback |
| `SmoothWheel`, `StyledScrollBar`, `Appearance.scroll.*` | the scroll feel, already tuned |
| `run.sh`, `PKGBUILD`, `packaging/*.desktop` | install story |

Drop: `Auth`, `Api`, `PostCard`, `CommentDelegate`, `VoteBar`, `PostDetailView`,
`SubredditList`. New: `Client` (the WebSocket, modelled on Morse's `Client.qml`),
`Catalog`, `QueryBar`, `GalleryView`, `DetailView`, `TargetPicker`, `ExportSheet`,
`CropBox`, `ProfileEditor`, `ImportDrop`, `Sys`.

**Runtime: `qs -c quarry`** (Quickshell 0.3.1 is installed; `FloatingWindow` is
already used in `ii/modules/ii/sidebarLeft`). The daemon does the file and
process work, so quickshell is needed only for desktop integration — global
shortcut, instant IPC toggle, and a layer-shell overlay picker mode. That also
means a bare-`qml6` build stays viable: keep host access behind one `Sys.qml`
facade and let no view file `import Quickshell` directly.

## Layouts

Rodded's layout switcher is the model: one content model, several views, the
active one publishing itself through `Host.claimView(flickable, owner)` so
extensions and keyboard nav keep working across a swap. quarry ships seven, and
the default is remembered **per `kind`** — avatars open in Grid, wallpapers in
Wall, because that is what each one is for.

| layout | what it is | when it wins |
|---|---|---|
| **Wall** | masonry, real aspect ratios, edge to edge (Rodded's `MediaWall`) | mixed-shape browsing, wallpapers |
| **Grid** | uniform squares, tile-size slider | avatars — they are all 1:1 anyway |
| **Compact** | one row each: thumb, title, source, dimensions, tags | scanning metadata, bulk selection |
| **Contact sheet** | 96px thumbs, hundreds on screen | triaging a fresh 5k-item crawl |
| **Theater** | one image filling the pane, arrow/scroll stepping, auto-advance | deciding between finalists |
| **Compare** | 2–4 up, synced zoom, keep/discard keys | "which of these four" |
| **In-context** | the candidate composited **into its target slot** | the one that makes this app |

*In-context* deserves the emphasis: a mock Steam profile header, a Discord member
row, a browser tab favicon, or your actual desktop screenshot with the real bar
and widgets over it — the image drawn at its true final size. Judging a 184px
avatar from a 400px tile is how you pick the wrong one. The daemon already has
the export pipeline, so the preview is a real export at preview quality, not an
approximation.

All seven share one windowed model and one selection model. A layout is ~150
lines because the expensive parts — geometry, windowing, decode gating — live in
shared components (`SlotGeometry`, `ThumbGate`), not in each view.

## Context menus

Right-click is where a gallery app either feels finished or feels like a demo.
Rodded already ships the right machinery: `MenuPopup`, `MenuRow` (leading icon,
label, trailing hint or check, `destructive` styling, separators) and
`PostContextMenu`, which is **one window-level instance every layout points at** —
a menu per tile would mean hundreds of popups in a wall, and recycled delegates
would tear an open menu down mid-click. Positions arrive in scene coordinates and
flip back inside near an edge. Keep all of that; generalise what it opens on.

**Every element gets one**, and rows carry Material Symbols icons — the icon is
what makes a 12-row menu scannable, so rows without a natural icon get a blank
slot rather than a shifted layout:

| right-clicked | rows |
|---|---|
| **tile** | `open_in_full` Open · `crop` Export as… ▸ (recent targets, then all) · `wallpaper` Set as wallpaper ▸ (per monitor) · `content_copy` Copy image · `link` Copy source URL · `download` Save original · `bookmark_add` Add to collection ▸ · `label` Edit tags · `search` Find similar · `palette` Match this colour · `open_in_new` Open source page · `visibility_off` Hide forever *(destructive)* |
| **multi-selection** | the same, pluralised — "Export 24 images as…", "Add 24 to…" — plus `select_all` Invert / clear selection |
| **source tab** | `refresh` Reindex now · `tune` Source settings · `schedule` Crawl schedule · `visibility_off` Hide source · `bug_report` Doctor this source |
| **collection / board** | `edit` Rename · `crop` Export whole board ▸ · `sync` Make smart… · `download` Archive originals · `delete` Delete *(destructive)* |
| **tag chip** | `add` Add to query · `remove` Exclude from query · `push_pin` Pin tag · `label_off` Rename/merge tag |
| **query bar** | `history` Recent queries · `bookmark` Save as smart collection · `notifications` Subscribe to this query · `content_copy` Copy as CLI command |
| **layout header** | `grid_view` Switch layout ▸ · `density_medium` Density · `sort` Sort ▸ · `fullscreen` Immersive (F11) |
| **export profile** | `content_copy` Duplicate · `star` Set default for kind · `code` Show op chain · `file_download` Export profile file |
| **monitor** (in wallpaper target) | `wallpaper` Set here · `select_all` Set on all · `open_with` Span across |

Two rules that keep it coherent: **submenus for anything with a list** (targets,
monitors, collections, layouts) so the root menu never grows past ~10 rows, and
the same action always keeps the same icon and the same wording wherever it
appears — the tile menu, the overflow menu and the command palette are three
views of one action registry.

That registry is the point: actions are declared once as
`{ id, label, icon, hint, scope, enabled, destructive, run }`, and menus, keyboard
shortcuts and extension contributions all read from it. Rodded's extension
`menuItems` already uses exactly this record shape, so `Host.registerAction` and
`Host.registerContextMenu(scope, provider)` let an extension add a row to *any*
element's menu without touching a view.

## Performance — the budgets, and how the layouts meet them

This is a catalog app, not a feed reader. Rodded's wall says so itself: its
wholesale column rebuild is cheap "at feed-page sizes (25–200 items)". quarry
targets **100k rows and 5k-item scroll sessions**, so three things change.

**Budgets** (regressions are bugs, and there is a harness to catch them):

| | target |
|---|---|
| query p95, 100k rows | **< 10 ms** in the daemon, < 30 ms to first tile on screen |
| scroll | **60 fps** (16.6 ms frames) with a 5k-item window, no frame > 32 ms |
| first paint, warm process via IPC | **< 120 ms**; cold start < 600 ms |
| thumbnail generation | **≥ 200 images/s** on this box (parallel, SIMD resize) |
| resident memory | **delta, not absolute**: < 10 MB per 100k catalog rows, and resident records bounded by what is on screen. A mapped window on this stack costs ~320 MB before quarry does anything (the desktop's own shell is 764 MB), so an absolute figure measures Qt, not us |
| export, 4K source → 184² PNG | **< 30 ms** |

### What changes from Rodded

1. **Incremental masonry.** Keep running column heights; a new page places in
   `O(added)`, not `O(all)`. Full rebuild only on width or column-count change,
   still behind the existing 90 ms debounce.
2. **No `Item` per slot.** Rodded creates a fixed slot Item for every post so the
   layout stays stable; at 50k that is 50k QObjects before a single image
   decodes. Instead the geometry lives in a flat typed array
   (`Float32Array`-style `[y, h, id]`), and the Repeater's model is a **computed
   visible window** (~40 slots) recomputed on the quantised `viewTop` step
   Rodded already has. Constant object churn regardless of catalog size.
3. **Never materialise the catalog.** Measured: a catalog record costs ~6.8 KB
   as a JavaScript object, so 137k items is ~930 MB with image loading off
   entirely. The view holds **one ratio per item** — all masonry needs, ~1 MB
   for 137k — and fetches full records **by page (500 rows, 8 pages resident)**,
   evicting the rest. Same catalog, **+19 MB**. This is also why the wire
   protocol has a cheap bulk `geometry` stream (id + ratio) separate from record
   fetches.
4. **Never call a state-touching function from a binding on the hot path.**
   `item: Catalog.itemAt(slot)` re-ran per tile per frame — 201k lookups and
   131 ms frames in a three-second sweep. Records are assigned on slot change;
   tile priority is quantised to the scroll step. Hot-path counters stay in plain
   JS, because a counter that is a QML property notifies on every increment.

### The rest of the performance story

- **Images never cross the socket.** The daemon returns *paths*; QML loads
  `file://` thumbs directly. Only metadata is JSON on the wire, batched ~200
  items per frame.
- **A thumbnail ladder** — 160/320/640/1280 WebP, generated once at index time —
  so every tile decodes a small file and `sourceSize` matches the draw size
  exactly. Full-res is loaded only in Theater/detail, with `cache: false` so a
  4K pixmap is never pinned.
- **Decode gating.** `ThumbGate` allows at most ~8 image loads in flight,
  prioritised by distance from the viewport centre and cancelled when a tile
  scrolls out. Unbounded `asynchronous: true` loads are what actually stutter.
- **Animation only on hover.** Index time extracts frame 0 into the thumb ladder;
  the grid shows a still. `AnimatedImage`/video is a `Loader` that exists for the
  hovered tile only — Rodded's `Host` video registry already does exactly this,
  reuse it unchanged.
- **No offscreen layers in tiles.** `layer.enabled` / `MultiEffect` is one FBO per
  tile; keep it for NSFW blur only, and cache the blurred result.
- `Loader.asynchronous: true` on tiles so instantiation spreads over frames;
  `pixelAligned: false`; QML disk cache on for startup; no rich text in delegates.
- **Daemon side:** SQLite in WAL with prepared statements and one transaction per
  crawl page; FTS5 with `prefix='2 3'` for as-you-type; covering indices on
  `(kind, w, h)` and `(source, added_at)`; decode on `spawn_blocking`, thumbs
  across a rayon pool, `fast_image_resize` SIMD; phash dedupe over a BK-tree.
- **Measure, don't assume.** `quarryctl seed --items 100000` fills a synthetic
  catalog so any of this is testable without crawling anything; criterion
  benchmarks cover query + pipeline; `QSG_RENDER_TIMING=1` plus a scripted flick
  produces the frame histogram. Numbers land in `PERF.md` per phase.

## Extensions

Rodded's extension system comes over **intact** — it is one of the better parts
of it, and the whole design already assumes third-party contributions.
Unchanged: a folder with `manifest.json` + an `Extension { }` root; the manifest
read *before* any code runs, so an extension can be listed, described and left
off without loading; instances created on enable and destroyed on disable; a
failed load listed with its error rather than vanishing; user extensions in
`~/.local/share/quarry/extensions/` overriding a built-in of the same id; and the
iron rule that an extension talks to the app only through `Host`, never into
views.

What quarry adds to the contribution points:

| declares | effect |
|---|---|
| `source` | a source of its own — see the two tiers below |
| `layout` | a whole new view in the layout switcher, fed the same windowed model |
| `target` | new export targets and post-actions, merged into the target picker |
| `queryOps` | new DSL predicates (`mine:`, `similar:`, `used:`) resolved by the extension |
| `menuItems`, `overlay`, `settingsPage`, `shortcuts`, `onActivated/onDeactivated` | exactly as Rodded |

**Sources come in two tiers**, and this is the important design call given a Rust
core:

- **Declarative** — a `source.toml` the daemon *interprets*: URL template,
  pagination, rate limit, and a field mapping expressed as JSON paths or CSS
  selectors. A new booru or any JSON gallery API becomes a 20-line file with **no
  recompile**. Most sources should be this, including several of the built-ins.
- **Native** — a Rust module, for the ones with real logic (reddit's OAuth,
  SCE's odd payloads). Compiled in, registered in the same table.

A QML-side source (XHR, like Rodded's `redgifs` extension) stays possible for
throwaway experiments, but it does not get catalog indexing — say so in the docs
so nobody builds a serious source there.

Shipped examples, each also a template to copy: **slideshow** (Rodded's
autoscroll, ported), **colour-match** (re-query by the hovered item's dominant
colour), **steam-preview** (the in-context layout for Steam), **folder-watch**
(index a directory live), **wallhaven-collections**.

## Backend: `quarryd`, a Rust daemon (the Morse pattern)

`../Morse/morsed` already establishes the house pattern, and it is the right one
here: **Rust daemon + local WebSocket + `PROTOCOL.md` as the authority + a token
in `endpoint.json`.** Reuse it wholesale rather than inventing a second shape.

Why a daemon rather than QML doing the work: HTML/RSS parsing, rate limiting,
incremental crawl, SQLite, image decoding/encoding, perceptual hashing and
folder watching are all things QML cannot do at all or cannot do without
blocking the UI thread. And a daemon can run from a systemd timer with no UI up.

```
quarryd/
  src/
    main.rs          endpoint.json (0600, port + token), tokio runtime
    server.rs        WebSocket, request/response/event envelopes
    protocol.rs      serde types mirroring PROTOCOL.md
    catalog.rs       rusqlite: schema, migrations, FTS5, query compiler
    query.rs         the DSL → SQL + FTS5 match
    index.rs         crawl scheduler, per-host rate limit, dedupe by phash
    sources/         one module per adapter, registered in a table
    image.rs         decode → ops chain → encode; thumbs; phash; dominant colour
    export.rs        target + profile → op chain → file → post-actions
    actions.rs       wallpaper via switchwall.sh, wl-copy, xdg-open (tokio::process)
  tests/fixtures/    saved HTML/JSON/RSS per adapter — parsers tested offline
```

Crates, and why each: `tokio` + `tokio-tungstenite` + `futures-util` (same as
morsed), `reqwest` (rustls, gzip), `scraper` for HTML, `quick-xml` for RSS,
`serde`/`serde_json`, `rusqlite` (`bundled`, FTS5 — **confirm the bundled build
enables FTS5 in the Phase-0 spike**), `image` + `fast_image_resize` for the
pipeline, `webp`/`ravif` for modern encodes, `image_hasher` for dedupe, `notify`
for watched folders (morsed already depends on it), `tracing`.

**No ImageMagick shell-out.** The pipeline is Rust ops, so an export is
deterministic, fast, and describable as JSON — which the UI shows in *Advanced*,
and which is how you debug an export. `ffmpeg` stays an optional escape hatch for
video→GIF only.

### Wire protocol — written, and now the authority

`PROTOCOL.md` v1 exists and both sides are built against it. Two decisions worth
carrying forward:

- **Unix socket, newline-delimited JSON**, not a WebSocket with a token. Morse
  needs the WebSocket because a plain `qml6` app has no alternative; quickshell
  has `Quickshell.Io.Socket`, and `$XDG_RUNTIME_DIR` is mode 0700.
- **`query` answers with a count and one ratio per row; records come by page.**
  Measured: 137k rows of geometry is 1.1 MB on the wire, where the records would
  have been ~930 MB in the client's engine. The split is the protocol's whole
  shape.

The original sketch, kept because the later methods still follow it:

Transport as in Morse: `ws://127.0.0.1:<port>`, JSON frames, `hello` with the
token from `$XDG_RUNTIME_DIR/quarry/endpoint.json` first or the socket closes.

| request | answers |
|---|---|
| `query` `{q, limit, cursor}` | `{items[], total, cursor}` — parsed DSL, FTS5 + predicates |
| `sources.list` / `sources.categories` | what can be crawled |
| `index.start` `{source, category, pages}` | streams `index.progress` / `index.item` events |
| `item.get` `{id}` | full record + local thumb path |
| `targets.list` | the target pack, including monitor-derived wallpaper sizes |
| `export.preview` `{id, target, profile}` | a preview PNG path, no side effects |
| `export.run` `{id, target, profile}` | `{path}` + post-actions performed |
| `import.add` `{paths[]}` | pulls local files into the catalog |
| `collections.*`, `history.*` | favourites and export log |
| events | `index.*`, `catalog.changed`, `palette.changed` |

## Beyond raster: vectors, 2D and 3D

A picture is what comes *out*; it is not what has to go *in*. The catalog holds
four families of item, and every non-raster one gets a **renderer** that turns it
into an RGBA buffer. Downstream — thumbnails, previews, crop, export targets —
nothing changes, because everything downstream already consumes a buffer.

| family | items | renderer |
|---|---|---|
| **raster** | png/jpg/webp/avif/gif | decode (`image`) |
| **vector** | svg | `resvg` + `usvg` + `tiny-skia`, pure Rust |
| **2D packs** | sprite sheets, icon sets, clipart | slice by grid or atlas metadata, then raster |
| **3D** | glTF/glb, obj, stl + HDRIs and PBR materials | Qt Quick 3D offscreen render, baked once |

### Vectors are the best possible avatar source

An SVG has no resolution, so it exports *perfectly* at 184², at 32², and at
3440×1440 — the crop box operates on the viewBox, and the rasteriser runs at the
final size instead of resampling someone else's PNG. Given that Iconify alone is
~200k icons, this is a large fraction of the catalog.

What SVG adds to the pipeline:

- **Rasterise at target size, always.** `resvg` renders each thumbnail-ladder
  step and each export from the original — never scale a rendered raster.
- **Tinting.** Detect single-fill/monochrome art at index time (`tintable`), then
  recolour to any hex — or to a **role from the live tinct palette**. Exporting an
  entire icon set recoloured to your current accent is one batch job, and the `ii`
  config's `CustomIcon` already has `colorize: true` waiting for it.
- **SVG-native export targets.** Not everything wants a PNG: a target can emit
  `.svg` straight into `~/.config/quickshell/ii/assets/icons/`, alongside the 34
  symbolic icons already there.
- **Icon ladders in one shot** — 16/32/48/128/256/512 plus `.ico`, from one source,
  each rendered rather than resampled.
- **Cleaning.** `usvg`'s normalised output doubles as an optimiser, and as
  sanitisation: scripts, external references and remote fetches are dropped on
  ingest. An SVG is code, and it is never handed to a renderer that could execute
  it — Qt's own SVG support is static Tiny SVG 1.2 anyway, which is a second
  reason the daemon rasterises rather than shipping vectors to the view.
- Query gains `vector:true` and `tintable:true`; size predicates always match a
  vector (its nominal viewBox is recorded, and `nominal:` targets it explicitly).

### 3D turns "find a picture" into "make one"

Qt Quick 3D **6.11.2 with `AssetUtils`/`RuntimeLoader` is installed on this box**,
so the app can load a glTF at runtime, orbit it, light it, and render the result
to an image. That is an avatar studio hiding inside a gallery app:

- **Camera is part of the item.** Orbit, zoom, field of view, three-point lighting
  preset, background (transparent / solid / an HDRI from Poly Haven) — saved with
  the item, so the same model re-renders at 184² for Steam and 1024² for a print
  without re-posing it.
- **Turntable export** — the same camera path as an animated WebP or GIF, for the
  places that accept animation.
- **HDRIs and PBR materials are wallpapers too.** A Poly Haven HDRI rendered as an
  equirectangular panorama, or an ambientCG material tiled and lit, is a genuinely
  good ultrawide wallpaper that nobody else has.
- **Thumbnails are baked, not live.** A 3D tile in the grid is a cached PNG keyed
  by `(asset, camera hash)`; the live `View3D` exists only in the detail/studio
  view, one at a time. Grid performance is unchanged — which is the only way this
  feature is affordable.
- 2D packs work the same way: slice a sheet once at index time, and every sprite
  becomes an ordinary item with its own tile.

## Sources — all probed 2026-08-29

Every row below was hit from this machine today; the status column is what it
actually answered, not what its docs claim. **Keyless** is the bar for a built-in:
anything needing a key ships disabled with a "add your key" card.

### Wallpapers and photography

| source | endpoint | status |
|---|---|---|
| **wallhaven** | `api/v1/search?q=&categories=&purity=&atleast=&ratios=&sorting=` | **200**, 24/page, keyless. Resolution, ratio and purity in the payload — its filters map 1:1 onto the DSL. The anchor wallpaper source |
| **reddit** | `oauth.reddit.com/r/<sub>/<sort>`, any sub list | creds already at `~/.secure/reddit-app.env`; `Rodded/Auth.qml` documents the grant |
| **openverse** | `api.openverse.org/v1/images/?q=&page_size=` | **200**, keyless, CC-licensed, licence metadata per item. **Shipped 2026-08-31.** `page_size` may not exceed **20** anonymously — more is a 401 that says so |
| **wikimedia** (video) | the same search with `filetype:video` | **200**, keyless. **Shipped 2026-08-31.** The best SFW video source there is: 3840x2160 CC-licensed webm, with MediaWiki rendering the poster frame. Reached through the existing manifest's `video_tag`, so it is a query rather than a second source |
| **cleveland** | `openaccess-api.clevelandart.org/api/artworks/?q=&limit=&skip=` | **200**, keyless. **Shipped 2026-08-31.** The whole open-access collection with three rendered sizes per work already on a CDN — unusually complete for a museum API: no URL to construct, no second request to learn how big anything is |
| ~~art institute of chicago~~ | `api.artic.edu` + IIIF | **API 200, images 403.** 132,681 artworks searchable and every image request — including `info.json`, with a browser UA and a Referer — is a Cloudflare JS challenge. A source whose metadata works and whose pictures do not is not a source. **Not shipped** |
| **reddit** | `oauth.reddit.com/r/<sub>/<sort>` | **200**, OAuth. **Shipped 2026-09-03.** Password grant against a script app, sharing the token cache the user's own scripts use so the two do not race into the rate limit separately. Pages by `after` cursor rather than by number, which the adapter remembers per listing. See PERF.md for the TLS fingerprinting that made this a two-hour bug |
| ~~reddit, unauthenticated~~ | `/r/<sub>/hot.json` | **403 on every host** (`www`, `api`; `old` now redirects to HTML). The unauthenticated JSON endpoints are closed — it needs the OAuth client-credentials flow, which is an adapter, not a manifest. See TASKS |
| **wikimedia** | `commons.wikimedia.org/w/api.php?generator=search&gsrnamespace=6&iiurlwidth=` | **200**, keyless. **Shipped 2026-08-31.** The largest CC photo library there is, and the originals are the real ones (5898x3443 for the first `landscape` hit). Answers `query.pages` as an object keyed by page id, which is why manifests accept an object root |
| **yandex images** | `yandex.com/images/search?text=&p=&isize=&iorient=` | **200**, keyless, no API — the results are JSON inside the page's own `data-state`. **Shipped 2026-08-31.** An index of the whole web rather than a library: 30/page, originals on third-party hosts (16/16 fetchable when tested). Its quality lives or dies on the size push-down — unfiltered, `cyberpunk city` gave 4 of 30 at ≥1920px; `isize` gave 30 of 30 at 4K |
| **peapix** | `peapix.com/bing/feed?country=` | **200**, keyless. **Shipped 2026-08-31.** The Bing wallpaper of the day, and `imageUrl` is the true 3840x2160 original. Measured: ignores `page` *and* a date range, so it is paged by market instead — 14 feeds x 7 rows, different tomorrow |
| **bing daily** | `bing.com/HPImageArchive.aspx?format=js&idx=0&n=8` | **200**, keyless. Eight days of 4K dailies — superseded by **peapix**, which carries the same pictures across fourteen markets |
| **picsum** | `picsum.photos/v2/list` | **200**, keyless. Placeholder/testing source, and handy for seeding |
| unsplash / pexels / pixabay / alphacoders | — | keys required (`400`/`404` bare); optional adapters |

### Art, museums, illustration

| source | endpoint | status |
|---|---|---|
| **deviantart** | `backend.deviantart.com/rss.xml?type=deviation&q=&offset=` | **200**, 60/page, keyless. The `/api/v1` route 401s without OAuth — RSS skips the dance |
| **Art Institute of Chicago** | `api.artic.edu/api/v1/artworks?fields=id,title,image_id` | **200**, keyless, IIIF images at any size — genuinely beautiful wallpapers and avatars |
| **Met Museum** | `collectionapi.metmuseum.org/public/collection/v1/search?q=&hasImages=true` | **200**, keyless, public-domain scans |
| **Wikimedia Commons** | `commons.wikimedia.org/w/api.php?generator=search&prop=imageinfo` | **200**, keyless, effectively unlimited breadth |
| artstation / pixiv | — | unofficial or auth-walled (`400`); extension territory, not built-in |

### Anime, characters, boorus

| source | endpoint | status |
|---|---|---|
| **danbooru** | `posts.json?tags=&limit=&page=` | **200**, keyless, full tag strings |
| **safebooru** | `index.php?page=dapi&s=post&q=index&json=1` | **200**, keyless — same declarative shape as danbooru |
| **yande.re** | `post.json?limit=` | **200**, keyless, high-res scans |
| **konachan** | `post.json?limit=` | **200**, keyless, wallpaper-shaped anime art |
| **AniList** | GraphQL POST to `graphql.anilist.co` | **200**, keyless. Character and cover art by name — the best source for "I want a Gojo avatar" |
| jikan (MAL) | `api.jikan.moe/v4/characters?q=` | **504 today** — MAL upstream was down, not us. Keep it, mark transient |
| gelbooru / nekos.best / waifu.im | — | `401`/`403` — key or Cloudflare. Skipped, documented |

### Feeding somebody else's wallpaper picker

`quarry-fetch <query> <sort> <after> <dest>` fills a folder and prints
`AFTER=<cursor>` then one path per file — deliberately the same contract as the
`fetch_reddit.sh` in this machine's quickshell setup, so the shell around it
needs no changes at all: the cursor bookkeeping, the sort cycle and the rescan
keep working. Reddit's sort names (`hot`, `top?t=all`, `new`) are accepted and
mapped rather than rejected.

The difference is what the first argument means. For Reddit it is a subreddit;
here it is anything the query bar accepts — `nature`, or
`kind:wallpaper w>=3440 -nsfw`. A short page triggers a live crawl before
answering, so a query the catalogue has never seen still returns a full page
instead of the two rows it happened to hold.

### Adult, and where the video is

Marked `adult = true` in the manifest, which is what makes every row `nsfw` and
therefore what makes `-nsfw` — the filter that keeps the rest of the catalogue
browsable — actually work. These are also the best keyless sources of **video**
there are: video is a fraction of a percent of any board, so it has to be asked
for by tag, never filtered for locally.

| source | endpoint | status |
|---|---|---|
| **redgifs** | `api.redgifs.com/v2/gifs/search` + `/v2/auth/temporary` | **200**, keyless. **Shipped 2026-09-05.** Adult video, and the cleanest video API here: every row is an mp4 with a rendered poster, real dimensions and a duration the site measured — nothing to probe, nothing to guess from an extension. The token is a formality: `/auth/temporary` hands one to anyone and it lasts about a day |
| ~~sex.com~~ | — | **Cloudflare JS challenge.** 322 KB of HTML with zero image markers behind it; not reachable without a browser engine. Not shipped |
| **e621** | `e621.net/posts.json?tags=&limit=&page=` | **200**, keyless. **Shipped 2026-08-31.** `type:webm` returns real 1080p VP9 with a rendered poster, and it publishes `duration` — the only source that does. Verified end to end: post 6668920, 1920x1080, 15.8s |
| **e926** | same API, `e926.net` | **200**, keyless. **Shipped 2026-08-31.** The same board with the adult half removed *by its operators* — a safe-by-construction art catalogue, and video on the same `type:webm`. Shipped separately rather than as a `rating:s` filter, because that would be quarry deciding what is safe instead of the site |
| **derpibooru** | `derpibooru.org/api/v1/json/search/images?q=&per_page=&page=&filter_id=56027` | **200**, keyless. **Shipped 2026-08-31.** 2.4M images and **36,142 webm**. The filter id IS the source: anonymously the same query answered **111** results by default and **21,104** with `filter_id=56027` ("Everything") — a source silently returning 0.5% of itself is worse than one that fails |
| **furbooru** | same Philomena API, `furbooru.org` | **200**, keyless. **Shipped 2026-08-31.** 272k images, 2,011 webm |
| ~~tbib~~ / ~~rule34.paheal~~ | gelbooru and danbooru API shapes | **403 (Cloudflare)** and **XML with `count='0'`**. Not shipped |
| **xbooru** | `xbooru.com/index.php?page=dapi&s=post&json=1` | **200**, keyless. **Shipped 2026-08-31.** The one adult board of its shape still answering without credentials — gelbooru and rule34 both want a key, realbooru's API is off. Stills only: its `webm` tag returns GIFs |
| **danbooru** (video) | `posts.json?tags=video` | **200**, keyless. Its `video` metatag covers webm and mp4 and excludes animated GIFs, which are rasters here |
| **rule34.xxx** | `api.rule34.xxx/index.php?page=dapi&s=post&json=1` | **200 with no rows** without credentials — "Missing authentication", which looks exactly like an empty catalogue. Ships with an `[auth]` block so quarry says why it is skipped and where the free key is |
| realbooru | same dapi shape | **API offline** — "API offline because a" (its own truncated message). Not shipped |

### Avatars, emotes, icons, gaming

| source | endpoint | status |
|---|---|---|
| **pfps.gg** | server HTML: `/?page=N&sort=`, `/pfps/<tag>`, `/banners`; `cdn.pfps.gg/pfps/<id>-<n>-<slug>.{png,jpeg,gif}` | **200**, one regex. No JSON API. `.gif` ⇒ animated |
| **emoji.gg** | `emoji.gg/api` | **200**, keyless — a **2 MB** single-shot dump of the entire catalogue. Index once, query locally forever |
| **7TV** | `7tv.io/v3/emote-sets/global`, plus search | **200**, keyless. Emotes make excellent small avatars |
| **BetterTTV** | `api.betterttv.net/3/cached/emotes/global` | **200**, keyless |
| **Iconify** | `api.iconify.design/search?query=` | **200**, keyless, ~200k icons across every icon set — the `icon` kind, solved |
| **Simple Icons** | `cdn.jsdelivr.net/npm/simple-icons/icons/<name>.svg` | **200**, keyless brand logos |
| **Steam store** | `store.steampowered.com/api/appdetails?appids=` | **200**, keyless — capsules, headers, screenshots and library art per game |
| **steamcardexchange** | `/api/request.php?<Get…>` | **200** (1.2 MB). Honest caveat: card and background art, *not* avatars — labelled that way in the UI |
| **local** | folder scan + `notify` watch, raster/svg/glTF/sprite-sheet alike | ten lines, and it is what makes this a wallpaper manager *and* an asset library |
| steamgriddb | `api/v2/…` | `401` — free key, optional adapter |

### Vector / SVG sources

| source | endpoint | status |
|---|---|---|
| **Iconify** | `api.iconify.design/search?query=`, plus `/collections` | **200** both; the collections call returns **200+ icon sets** in 97 KB — one adapter, ~200k icons |
| **jsDelivr npm** | `data.jsdelivr.com/v1/package/npm/<pkg>` file tree, files from `cdn.jsdelivr.net` | **200**. This is the sleeper: **one declarative source covers every npm icon set** — lucide, tabler, phosphor, bootstrap-icons, remixicon, feather, heroicons, openmoji, twemoji — by changing a package name in a `.toml` |
| **Material Symbols** | `fonts.google.com/metadata/icons` (2 MB), SVGs from `fonts.gstatic.com` | **200**, keyless — and it is the icon font this desktop already renders with, so an icon picked here matches the shell exactly |
| **Simple Icons** | `cdn.jsdelivr.net/npm/simple-icons/icons/<name>.svg` | **200**, keyless brand marks |
| **Wikimedia Commons** | the same API, filtered to `filetype:svg` | **200**, keyless |
| SVGRepo · openclipart · freesvg · publicdomainvectors · unDraw | — | **no usable API** today (429, 302→HTML, 404). Import their CC0 packs as folders; `local` indexes SVG like anything else |

### 3D, materials and 2D packs

| source | endpoint | status |
|---|---|---|
| **Poly Haven** | `api.polyhaven.com/assets?t=models` (also `t=hdris`, `t=textures`) | **200**, keyless, CC0 — **521 models** with categories and tags in one call, plus the HDRI library that lights them and doubles as ultrawide wallpaper |
| **ambientCG** | `ambientcg.com/api/v2/full_json?type=Material` | **200**, keyless, CC0 PBR materials |
| **Smithsonian Open Access** | `api.si.edu/openaccess/api/v1.0/search?q=3d` | **200** on `DEMO_KEY` (own key is free) — museum 3D scans, public domain |
| **Sketchfab** | `api.sketchfab.com/v3/search?type=models` | **200** keyless *for search and preview*; downloads need OAuth — so it browses without a key and asks for one only when you export |
| **BlenderKit** | `blenderkit.com/api/v1/search/?query=` | **200**, keyless search — models, materials, HDRIs and brushes in one catalogue |
| **Objaverse** | `huggingface.co/api/datasets/allenai/objaverse` | **200**, 6.5 MB of metadata — **800k+ CC-licensed objects**, the largest 3D corpus there is |
| **Khronos glTF Sample Assets** | GitHub contents API on `KhronosGroup/glTF-Sample-Assets` | **200**, keyless — the canonical models, and the right fixture set for testing the renderer |
| **Printables** | `api.printables.com/graphql/` (POST) | **200** to a POST; a GET is 400. Print models, keyless |
| **Three D Scans** | `threedscans.com` HTML | **200** — public-domain museum sculpture scans. A classical bust, posed and rendered at 184², is a genuinely great avatar |
| Thingiverse · MyMiniFactory · Quaternius · Kenney | — | key-walled (401) or static packs. Fold the CC0 packs in as folders via `local` |

Vector-bearing sources already in the tables above — **Iconify** (~200k icons),
**Simple Icons**, and much of **Wikimedia Commons** — feed the vector pipeline
directly.

That is **32 keyless built-ins** spanning every family the pipeline renders —
plus reddit (credentials you already have) and Smithsonian (a free key). Most of them are the same
shape — a URL template, a page parameter, and a field mapping — which is exactly
why sources are declarative by default (see *Extensions*); only pfps.gg's HTML,
reddit's OAuth and SCE's payloads need native Rust.

**Hotlink blocks are real and they shape the design.** Measured 2026-08-29:
`cdn.donmai.us` (danbooru) and the Art Institute's IIIF host both answer **403**
to a direct image request while their metadata APIs answer 200 — the documented
`AIC-User-Agent` header does not lift it. A view can never load those URLs
directly, which is the concrete argument for the daemon owning the thumbnail
ladder rather than the UI pointing `Image.source` at a remote URL.

Manners: real User-Agent, per-host delay, conditional GETs, cache hard, personal
scale. The catalog stores URLs, thumbnails and metadata — never a rehosted copy
of someone's art, and licence/attribution fields are carried through and shown
(Openverse, the museums and Wikimedia all provide them; the export sheet can
stamp attribution into a sidecar file).

## Catalog

`~/.local/state/quarry/catalog.db`, thumbs in `~/.cache/quarry/thumbs/`.

- `item` — `source, source_id, url, page_url, title, slug, ext, w, h, ratio,
  bytes, animated, nsfw, author, kind, added_at, seen_at, phash, dominant_rgb`
- **family** — `raster · vector · sprite · model · hdri · material` — plus the
  fields each one needs: `nominal_w/h` from an SVG viewBox, `tintable`, `tri_count`,
  `camera_json` for a posed model, `sheet_json` for a sliced sprite sheet.
  `w`/`h` stay populated (nominal for vectors, render size for models) so one
  query language covers everything
- `tag`, `item_tag`
- `item_fts` — FTS5 over title/tags/author/source, so the query bar is instant
- `collection`, `collection_item` — favourites and named sets
- `export_log` — what was exported, from what, with which target and profile

`kind` is the spine of the generality: `avatar · banner · wallpaper · icon ·
cover · emote · sticker`, inferred from the source and the aspect ratio, and
overridable per item.

## Targets and profiles — the export side

A **target** is data (`targets.json`, shipped + user overrides): a name, one or
more sizes, an aspect, format constraints and notes. A **profile** is the
adjustable pipeline applied to reach it. Both editable in the UI, both plain JSON
on disk.

Shipped pack (a starting list, not a limit):

| group | targets |
|---|---|
| desktop | wallpaper **per connected monitor, sizes read from `hyprctl monitors`**, lockscreen, SDDM/GRUB background, quickshell avatar |
| Steam | avatar 184² and 512², profile background, artwork showcase |
| chat | Discord avatar 512² + banner 600×240, Telegram 512², Matrix, Slack 512² |
| social | X 400² + header 1500×500, Mastodon 400² + 1500×500, GitHub 500², Twitch 256² + offline 1920×1080, YouTube 800² + banner 2048×1152 |
| small | favicon 16/32/180, app icon 256/512, waybar/dock icon |
| none | keep original — just crop and convert |

Every knob is per-profile and persisted: output W×H with aspect lock and preset
chips; fit (cover/contain/stretch/crop-only); an interactive pan-zoom crop box on
the live preview with gravity presets and a *smart* option (entropy crop in Rust,
or the existing `ii/scripts/images/least_busy_region.py`); contain-fill
(transparent / solid / blurred source); mask (corner radius, circle, border);
format png/jpg/webp/avif with quality and metadata strip; animation (keep, pick a
frame, cap frames/fps/loop, or flatten); adjustments (brightness/contrast/
saturation/unsharp/grayscale); an output path template
`~/Pictures/quarry/{kind}/{source}/{slug}-{w}x{h}.{ext}`; and post-actions — copy
path, copy image (`wl-copy`), open, **set as wallpaper** via
`ii/scripts/colors/switchwall.sh` so the whole desktop rethemes, or run a custom
command with `{out}`.

Batch export is nearly free once this exists: apply one target to a whole
collection, or every monitor at once.

### "Upload", stated plainly

No platform in that table has a public avatar-upload API worth automating —
Steam included; doing it means replaying session cookies, which is brittle and
ToS-grey. So **upload = import**: drag-drop or a file dialog pulls local images
into the catalog as the `local` source, and they run through the identical
pipeline. The outbound path is export → image on the clipboard → the target's
settings page opens → paste. Two clicks, nothing to break. A cookie-based
uploader can exist later behind an explicit opt-in flag; not the default.

Also worth saying in the UI: animated avatars on Steam only come from the Points
Shop, so an animated export there gets a chip explaining why it will flatten.

## Desktop integration

- App at `~/.config/quickshell/quarry` (symlink to this checkout), `qs -c quarry`.
- `IpcHandler`: `qs -c quarry ipc call app toggle|open`, `ipc call export run <id> <target>`,
  `ipc call wallpaper random <query>` — that last one makes the daemon a wallpaper
  rotator with a *query* behind it, which the current `switchwall.sh` cannot do.
- Hyprland bind in the style of `~/.config/hypr/hyprland/keybinds.conf`:
  `bind = Super, P, exec, qs -c quarry ipc call app toggle || qs -c quarry &`
- Overlay mode: the same gallery as a layer-shell full-screen picker for
  wallpaper switching, so it feels like part of the shell rather than a window.
- `packaging/quarry.desktop` + `PKGBUILD` forked from Rodded's; a systemd user
  timer refreshes the index nightly.

## Features

Core is what ships in the phases below. *Ext* means it is a shipped extension —
same capability, but it proves the extension API carries real weight.

### Library

- **Collections and boards** — named sets, drag between them, one target applied
  to a whole board at once.
- **Your own tags, ratings and notes** on top of source tags; they survive
  re-indexing because they key off the perceptual hash, not the URL.
- **Smart collections** — a saved query that re-evaluates on every index, so
  "3440×1440 dark wallpapers added this week" is a folder that fills itself.
- **"Used on" tracking** — quarry remembers which image is currently your
  wallpaper, your Steam avatar, your Discord banner. That gives you a
  *what am I wearing right now* view across every platform, which nothing else
  on the desktop knows.
- **Personas** — a named bundle (avatar + banner + wallpaper + accent colour)
  applied everywhere in one click. Switch your whole identity — desktop palette
  included, since the wallpaper drives tinct — between "work" and "not work".
- **Near-duplicate grouping** via perceptual hash: "you already have this",
  collapsed into one tile with the highest-resolution copy on top.
- **Blocklist** — hide-forever by hash, so a bad tile never comes back from any
  source.
- **Offline archive** — favourites keep their full-resolution original on disk;
  everything else stays thumbnail + URL, so a 100k catalog is still small.

### Discovery

- **The query DSL** with completion, history and saved queries.
- **Similar-to-this** — hash + colour neighbourhood, from any tile.
- **Colour matching** — `color:#7aa2f7 dist<25`, and the one-click *matches my
  current palette*, reading the live tinct scheme.
- **Subscriptions** — watch a query; the daemon notifies over D-Bus when new
  matches land (`zbus`, already a morsed dependency). A quiet feed of exactly the
  images you asked for.
- **Surprise me**, seeded and constrainable, plus a daily pick.
- **Stats** — items per source, disk used, top tags, index freshness, what broke.

### Preview and editing

- **In-context previews** — the candidate composited into a mock Steam header, a
  Discord member row, a browser favicon, or your real desktop screenshot with the
  actual bar over it. Judged at final size, not tile size.
- **Interactive crop** with pan/zoom, gravity presets and entropy-based smart
  crop; per-target crops remembered per image, so one source image can hold a
  square avatar crop *and* a 21:9 wallpaper crop at once.
- **Contrast check** — an avatar previewed against the light and dark backgrounds
  the target platform actually uses, with a pass/fail readout.
- **Palette preview before applying** — see the desktop recoloured by a candidate
  wallpaper before committing it.
- **Animation tools** — frame picker, GIF→WebP, trim, loop and fps caps, plus
  turntable renders from a posed 3D model.
- **Tint any vector** to a hex or to a live palette role, and batch-recolour a
  whole icon set to your current accent.
- **Icon ladders** — 16/32/48/128/256/512 and `.ico` from one SVG, each rendered
  at size rather than resampled.
- **3D studio** — orbit, lighting preset, HDRI or transparent background, saved
  with the item so it re-renders at any target size later.
- **Upscale hook** (*Ext*) — hand off to `realesrgan-ncnn-vulkan` when installed,
  for a 400px source that has to become a 1024px avatar.
- **Background removal** (*Ext*) — optional model, opt-in download, never a
  default dependency.

### Export and automation

- **Batch export** — a board to a target, or one image to every connected monitor.
- **Profiles are files** — shareable, diffable, version-controlled.
- **Attribution sidecars** for sources that carry licence metadata.
- **Wallpaper rotation by query** — `quarryctl wallpaper next --query '…'` on a
  timer; the rotation pool is a query, which `switchwall.sh` cannot express.
- **Full CLI parity** — anything the UI does, `quarryctl` does, so it scripts.
- **Drag out** to any app (XDND file drop), **paste-URL import**, and a clipboard
  watcher offering to import an image URL you copied.
- **Export history** with re-export under a new profile.

### Desktop

- Keyboard-first: vim-style navigation, multi-select, marks, quick-look, batch
  ops, undo.
- Layer-shell overlay picker for wallpaper switching, plus a quickshell panel
  widget showing what is currently applied.
- NSFW gate with per-source purity and blur-until-hover.
- Session resume, per-`kind` default layout.

## Phases — UI first, then the backend behind it

The order is deliberate: **fork Rodded and get the app on screen before a line of
the crawler exists.** The UI is the part with taste in it and the part that
decides what the data has to look like; the daemon is a known quantity once the
shape is fixed. Morse already proves the seam works in this direction — `morsed`
ships a `mock` backend by default and the real one arrives behind the same
protocol.

Two things are written in Phase 0 and are binding from then on: the **`Item`
record** (the normalised fields every source produces and every view consumes)
and, from Phase 2, **`PROTOCOL.md`**. Building the UI against a fixture is only
safe because the fixture is that record.

| # | deliverable | done when |
|---|---|---|
| 0 | **Fork the template.** Copy `../Rodded/Rodded` → `quarry/`, rename the module, strip Reddit, keep Appearance/Scheme/Prefs/Toast/SmoothWheel/Extensions. Define the `Item` record. Ship `fixtures/catalog.json` + a `seed.py`-style generator producing **100k synthetic rows over a handful of local images**. `qs -c quarry` opens a themed FloatingWindow showing fixture tiles | the window opens, matches the desktop palette, and renders real tiles |
| 1 | **The gallery, for real, on fixtures.** `SlotGeometry` + `ThumbGate`, Wall and Grid, sliding page window, detail view, nav, per-`kind` default layout | **60 fps scrolling the 100k fixture** — measured with `QSG_RENDER_TIMING`, logged in `PERF.md`, before any backend exists |
| 2 | **`PROTOCOL.md` + a mock daemon.** Rust, tokio + WebSocket + token in `endpoint.json`, serving the same fixtures over the wire. `Client.qml` swaps from file to socket | the UI is unchanged and does not know the difference |
| 3 | **Query bar + filters** against the mock: DSL with completion, chips for kind/source/ratio/size/animated/nsfw, sort, saved queries | one bar answers both "wallpaper" and "avatar" |
| 4 | **The remaining layouts** — Compact, Contact sheet, Theater, Compare, In-context — and the **action registry + context menus** on every element, icons included | switching keeps position, selection and 60 fps; right-click works everywhere and reads the same registry as the shortcuts |
| 5 | **Real catalog.** rusqlite + FTS5, the DSL compiled to SQL, migrations, `quarryctl` (`query`, `seed`, `doctor`), criterion benches | query p95 **< 10 ms at 100k rows**; the mock is deleted |
| 6 | **Sources.** The declarative `source.toml` runtime, then wallhaven, pfps.gg, danbooru + the booru family, deviantart, AniList, Iconify, emoji.gg, local watch — plus native adapters for reddit and SCE. Thumbnail ladder, phash, dominant colour, fixture tests per adapter | `doctor` is green across 19 keyless sources; the catalog fills itself |
| 6.5 | **Vector pipeline.** `resvg` rendering into the thumbnail ladder, `usvg` sanitising and cleaning on ingest, `tintable` detection, SVG-native targets and icon ladders. Iconify and Simple Icons land here | an icon set exports recoloured to the live accent, at six sizes, in one batch |
| 7 | **Image pipeline + targets.** Rust ops, target pack, export sheet made real: preview, crop box, every knob, profile editor, post-actions, import/drag-drop, batch | 184² and a per-monitor wallpaper both land in two clicks; 4K→184² **< 30 ms** |
| 8 | **Extensions.** Rodded's system ported, plus `layout`/`target`/`source`/`queryOps`; ship slideshow, colour-match, steam-preview, folder-watch | a dropped-in folder adds a layout and a source with no recompile |
| 9 | **Desktop integration.** IPC, keybind, overlay picker, wallpaper-by-query rotation + retheme, D-Bus subscriptions, desktop entry, PKGBUILD, systemd timer | `Super+P` is instant; a wallpaper set from it recolours the desktop |
| 9.5 | **3D and 2D packs.** Qt Quick 3D `RuntimeLoader` studio view, baked `(asset, camera)` thumbnails, turntable export, sprite-sheet slicing; Poly Haven, ambientCG, Smithsonian, Sketchfab browse | a glTF becomes a 184² avatar and a 3440×1440 wallpaper from one saved camera |
| 10 | **Library depth.** Collections, personas, "used on", smart collections, dedupe grouping, blocklist, offline archive, stats, export history | |

Every phase ends by re-measuring the budget table into `PERF.md`. Phases 0–1 do
that against fixtures precisely so performance is proven before the backend can
be blamed for it.

## Risks, stated plainly

- **Scrapers rot.** HTML fixtures in `tests/`, plus `doctor`, which names the
  broken adapter instead of showing an empty grid.
- **Two moving parts** (daemon + UI) means a protocol to keep honest.
  `PROTOCOL.md` is the authority, as in Morse: it changes first, both sides
  follow.
- **Rate limits / ToS.** Personal-scale crawling, honest UA, cache, delay.
- **SCE is card art, not avatars**; SteamGridDB and Unsplash need keys — all
  labelled in the UI rather than quietly degraded.
- **Quickshell coupling** is contained by the `Sys` facade; the daemon keeps the
  UI replaceable.
- **Performance regresses silently** — a layout added in Phase 4 can quietly cost
  10 ms a frame. That is why the budgets are a table, `seed` exists before the UI
  does, and every phase re-measures into `PERF.md`.
- **UI-first risk:** building views against a fixture the real catalog cannot
  serve. Contained by writing the `Item` record in Phase 0 and treating it as
  binding — the fixture generator and the daemon both emit exactly that shape.
- **SVG is code.** Sanitise through `usvg` on ingest — scripts, external
  references and remote fetches dropped — and rasterise in the daemon rather than
  handing vectors to a view. Qt's SVG support is static Tiny SVG 1.2 and would
  mis-render a chunk of the catalog anyway.
- **3D is the one genuinely heavy feature.** It is affordable only because grid
  tiles are baked PNGs and exactly one live `View3D` exists at a time; if that
  invariant slips, the 60 fps budget goes with it. It also lands late (Phase 9.5)
  so nothing earlier depends on it.
- **Extension API churn.** Contribution points are additive only once Phase 6
  ships; a breaking change means a manifest version bump, not a silent break.
