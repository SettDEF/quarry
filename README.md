# Quarry

**Find, fit and apply pictures for every image slot on your desktop.**

The unit of work here is not the picture. It is the **slot**: a size, an aspect,
and a background the result will be seen against. A 184px Steam avatar. A
600×240 Discord banner. A wallpaper at your panel's *real* 3072×1920, not the
compositor's logical 1536×960. A 32px favicon. An icon in your bar, recoloured
to the accent your desktop is using this week.

Finding a picture is easy. Making it fit the slot is the work — and it is
normally done by hand, in a dozen browser tabs and a one-off crop in GIMP, once
per slot, forever.

Quarry makes that one loop: **query → fit → apply**.

## Three ideas, and everything else follows from them

**One query language over many catalogues.** 156 sources, nearly none needing
an API key — wallhaven, the boorus, DeviantArt, AniList, the Met and the Art
Institute, Wikimedia, Iconify and every npm icon set, emoji.gg, 7TV, Poly Haven,
BlenderKit, Objaverse, Steam's own store art, Bing, DuckDuckGo and SearXNG for
the open web, your local folders — behind one grammar:

```
anime kind:wallpaper ratio:21:9 w>=3440 -nsfw sort:new
cat kind:avatar source:pfps.gg animated:true
family:vector tintable                       # icons I can recolour
kind:wallpaper color:#7aa2f7 dist<25         # matches my current accent
```

The daemon pushes each predicate into the source that can answer it — wallhaven
takes `atleast=3440x1440&ratios=21x9`, danbooru takes its own tag syntax — and
applies the rest locally. That is the difference between a page of usable
ultrawides and a page of everything.

Typed words are a real search on every site: a search API gets them as typed,
a tag board gets them resolved to its own tags through its autocomplete
(`mountain lake` → `mountain` + `lake`, `red car` → `red_car`), and Bing Images,
DuckDuckGo Images and SearXNG search the whole web with them. SearXNG is
metasearch — one request that merges Google, Bing, Brave, Flickr, Pinterest,
Unsplash, Pexels and Wikimedia Commons — and it needs no key; set
`$QUARRY_SEARXNG_URL` to pick the instance. Google on its own needs a key
(`$GOOGLE_CSE_KEY`, `$GOOGLE_CSE_CX`, 100 searches a day free); with it unset the
`google` source simply is not in the list. See `quarryd/src/sources/google.rs`
for the five-minute setup.

**One export pipeline to any slot.** A target is data, not code: a size, a fit,
a crop gravity, a format. Vectors rasterise at the target size rather than being
resampled, so an SVG is sharp at 32px and at 1024px. Crops can pick the busiest
region instead of the middle, so a face survives being squared off. An export
never silently overwrites the last one, and the exact recipe is printable, so a
result that looks wrong can be argued with.

**The desktop is part of the loop.** The UI follows the palette your wallpaper
generated, so it recolours when the desktop does. Wallpaper targets are built
from the monitors actually attached, at their true pixel size. Setting a
wallpaper from here rethemes everything downstream of it.

## What it is not

Not a Steam tool. Steam is one target among wallpapers, Discord, Twitch,
favicons and your icon theme — the app started as `pfpql`, a Steam profile
picture scraper, and that name became a permanent explanation about two days
before this one replaced it.

Not a downloader. The catalogue holds URLs, thumbnails and metadata; originals
are fetched when you export one, and licence and attribution travel with the
sources that provide them.

## Shape

```
quarryd (Rust)                          the UI (QML, quickshell)
  catalogue, query DSL, crawler   ←→    gallery, query bar, export sheet
  image pipeline, thumbnails            follows the live palette
        unix socket, newline JSON — PROTOCOL.md is the contract
```

Both sides are written against `PROTOCOL.md` independently. The catalogue never
crosses the wire as records: a query answers with a count and one ratio per row,
about 1 MB for 137k items, and full records arrive by page. That single decision
is why the gallery scrolls 137,000 items at 60 fps in 19 MB.

### The board

`quarry-board` is a second, native window (Rust, egui) for arranging reference
the way RIA and PureRef do — beside the thing you are drawing, optionally
see-through. It holds no pictures of its own: boards live in the daemon's
catalogue, so a picture on a board is still searchable in quarry, and both
windows stay in step through `board.changed` events.

- a library panel (Tab) searching the catalogue with `find`; click or drag to add
- drop files or folders, paste with Ctrl V, copy out with Ctrl C
- corner handles and a turn knob; right-drag scales, R turns; snapping guides (Alt to move freely)
- groups, tidy into a grid, bring to front / send to back, undo and redo
- a ground of your choosing (theme, black, grey, white), and transparency for the board and the pictures separately (Solid · Float · Trace)
- an eyedropper (I) that copies the hex of anything on the board, and export of the view as a PNG (Ctrl E)
- Find similar: the library shows pictures that look like the selected one
- a board switcher that shows what is on each board
- an overview map, a hide-everything mode (`\`), and a shortcuts sheet (F1)
- the desktop's tinct palette, re-read when the wallpaper changes

`tools/board-demo.sh out.png <images>` renders it with a private daemon inside
Xvfb, so a change can be looked at without a window on anyone's screen.

### The terminal

`quarry term` is the catalogue in a terminal: the same search (catalogue first,
then the sites), a grid of thumbnails, a large view, animated GIFs that play,
and video and audio through mpv.

```sh
quarry term pusheen animated     # browse: arrows, Enter, / search, +/- size, q
quarry term show ramen           # a strip of results printed into the scrollback
quarry term cat emojigg:2177     # one picture, large; an animated one plays
```

In the browser: `s` saves the original, `w` makes it the wallpaper, `o` opens
its page, `y` copies the link, `p` plays a video. Pictures are drawn with
24-bit half-blocks (two pixels per cell), which works everywhere, including
inside zeit, which drops kitty graphics. Where kitty graphics reach the screen
(kitty, or zash outside zeit), `--gfx kitty` is picked automatically.

In zash inside zeit there is also the **stage**: a zeit web pane opened beside
the grid, which zash draws with Chrome. It shows the selected item for real —
the original at full resolution, GIFs moving, video playing (muted; click it
for sound, or `p` for mpv) — and follows the selection. `v` hides and shows it,
and quitting closes it. `QUARRY_TERM_STAGE=0` turns it off.

## Getting it

```sh
tools/install.sh            # build with makepkg, install with pacman
quarry                      # or from the app menu
```

`tools/install-user.sh` puts it in the menu without root, running from the
checkout. The daemon starts on demand in about 4 ms; a systemd user unit ships
for later, when scheduled crawls and query subscriptions need it, and is off
until then.

## Tests

```sh
cd quarryd && cargo test        # parsers, query DSL, schema, rate limits, cache keys
tools/qml-test.sh               # the UI's measurements, asserted
tools/qml-test.sh --offscreen   # …with no window on your session at all
```

The second one exists because every user-visible defect in this project has
been in the QML, and every one of them was a *number*: a search bar that
rendered 4px wide, a filter panel 70px tall holding 73 rows, a completions
dropdown 900px from its field, a settings page listing 0 of 29 sources, board
pieces rebuilt on every drop so every picture reloaded. None of that needs
judgement to catch.

Both apps answer an `ipc call … probe` with their own measurements as JSON, and
the script decides whether they are sane. It is not screenshot diffing: that
breaks on every theme change and teaches you to ignore it. These fail only when
something is structurally wrong.

Not part of `makepkg`'s `check()` — it needs a compositor and a running daemon,
neither of which a clean chroot has.

## Documents

| file | what it is |
|---|---|
| `PLAN.md` | the architecture and the phase order |
| `PROTOCOL.md` | the wire contract — **the authority** |
| `ITEM.md` | the record every source produces and every view consumes |
| `PERF.md` | budgets, measurements, and the bugs the measurements caught |
| `docs/adding-a-source.md` | adding a site yourself — a TOML file, no Rust |
