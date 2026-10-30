# The `Item` record

Binding from Phase 0. The fixture generator, the daemon, every source adapter and
every view produce or consume **exactly this shape**. Adding a field is a
protocol change; renaming one is a breaking change.

| field | type | notes |
|---|---|---|
| `id` | string | stable, `"<source>:<source_id>"` |
| `source` | string | adapter id — `wallhaven`, `pfps.gg`, `iconify`, `polyhaven` |
| `source_id` | string | the source's own id |
| `family` | string | `raster · vector · video · sprite · model · hdri · material` — decides which renderer runs |
| `kind` | string | `avatar · banner · wallpaper · icon · cover · emote · sticker` |
| `title` | string | may be empty |
| `slug` | string | filename-safe, used in export path templates |
| `url` | string | the full-resolution original |
| `thumb` | string | local ladder path once indexed; a remote URL before that |
| `page_url` | string | where a human would look at it |
| `ext` | string | `png jpg webp gif svg glb …` |
| `w`, `h` | int | nominal viewBox for vectors, render size for models |
| `ratio` | real | `w / h`, precomputed — masonry reads it per tile |
| `bytes` | int | 0 when unknown |
| `animated` | bool | True for a GIF and for every video. A GIF is a `raster` that moves; a video is its own family, because nothing in the image pipeline can open one |
| `duration` | float | Seconds, `0` for a still. **Measured, not reported**: filled in by `ffprobe` the first time the daemon thumbnails the file. Sources describe video badly and a duration nobody measured is worse than none, because the UI would print it |
| `tintable` | bool | monochrome vector, safe to recolour |
| `nsfw` | bool | |
| `author` | string | |
| `license` | string | carried through where the source provides it |
| `tags` | string[] | |
| `added_at` | int | unix seconds |
| `phash` | string | 16 hex chars, empty until indexed |
| `dominant` | string | `#rrggbb`, empty until indexed |

Two invariants the UI relies on: **`ratio` is always populated** (masonry must
never wait on an image to know a tile's height), and **`thumb` is always
loadable** — a path or a URL, never empty.
