# quarryd as the desktop's picture backend

**Scope: wallpapers and booru/anime content. Nothing else.**
The bar, dock, notifications, battery, workspaces and lock screen stay exactly
as they are and gain no dependency on this. A media daemon going down must cost
you pictures, never your shell.

## Why — what the shell does today

Measured in `~/.config/quickshell/ii`, not assumed:

| | today | quarryd |
|---|---|---|
| wallpaper thumbnails | `thumbgen-venv.sh` → activate a **Python virtualenv** → `thumbgen.py`, or an **ImageMagick** script; a batch job with a progress bar | in-process Rust, laddered, cached to `~/.cache/quarry/thumbs`, decode-gated |
| booru fetching | `services/Booru.qml`, **556 lines** of HTTP + JSON in QML mapping `preview_url`/`sample_url`/`file_url` for danbooru and yande.re | `sources/` in Rust: retries, dedupe, phash, dominant colour, a plugin per source |
| booru image cache | none — the only cached thing is the provider list ("these shift over months") | every ladder step cached on disk |
| dominant colour | `ColorQuantizer` in QML, on the UI thread | computed during thumbnailing, stored on the row |

## Where the speed actually comes from

Not "Rust is faster than QML" — the network dominates a booru fetch either way.
It comes from three specific things, in order of size:

1. **No process spawn.** A wallpaper folder currently costs a bash script, a
   virtualenv activation and a Python interpreter before a single pixel is
   resized. quarryd does it in the process that is already running.
2. **A cache that already exists.** Booru images are re-fetched every browse.
   quarryd has the ladder and the on-disk cache today.
3. **Work off the UI thread.** Colour quantisation in QML competes with the
   frame you are trying to draw; in the daemon it does not.

The fourth win is not speed: a source added once is available to the app, the
wallpaper picker and the shell together.

## The one real gap

`thumb` takes an **item id** — it is catalogue-shaped. The shell mostly needs
*"a thumbnail for this local file path"*. That is a small protocol addition and
it is a hard prerequisite for the wallpaper half:

    { "t": "req", "m": "thumb_path", "p": { "path": "/home/…/pic.png", "size": 320 } }
    → { "path": "~/.cache/quarry/thumbs/…", "cached": true,
        "phash": "…", "dominant": "#705a3f" }

Same ladder, same cache, same gate.

**It does not touch theming, and must not.** `tinct` already owns wallpaper →
colour scheme: `scripts/colors/applycolor.sh` runs it in place of
`rebuild_templates.py` + matugen, "byte-identical", and it is installed at
`~/.local/bin/tinct`. quarryd's `dominant` is a single accent for tinting a
*tile* in a picker — not a palette, not a scheme, and no input to tinct. The two
do not overlap and neither should learn the other's job.

Worth noting the precedent though: the colour pipeline's Python was already
replaced with Rust, and it worked. The wallpaper THUMBNAIL pipeline is the same
shape of problem, still on Python — this plan is that same move, once more.

## Order of work

1. **`thumb_path`** in quarryd — nothing else can start without it.
2. **Wallpapers**: `Wallpapers.qml` calls `thumb_path` instead of spawning
   `thumbgen-venv.sh`. Delete the venv and ImageMagick scripts once the progress
   UI has something to bind to (quarryd can report per-file completion).
3. **Booru**: `Booru.qml` keeps its UI and loses its HTTP/JSON — `query` and
   `items` replace them. 556 lines become a handful of IPC calls, and the shell
   inherits caching, dedupe and every future source.

## Lifecycle — the thing that actually changes

Today quarryd starts on demand from the launcher and can be killed freely: it is
one app's backend. If the wallpaper picker depends on it, it becomes a **session
service that is expected to be up**. `packaging/quarryd.service` already exists,
so the plumbing is there — but this is a real change of status and worth naming
before, not after.

Both consumers must degrade rather than break: no daemon means no thumbnails and
no booru, not an empty wallpaper list or a stalled shell.


## Reddit — and what Rodded is for

Reddit exists three times in this ecosystem:

| where | what | size |
|---|---|---|
| `Rodded/Api.qml` + `Auth.qml` | OAuth, listings, search, comments, media | 700 lines of QML |
| `ii/scripts/colors/fetch_reddit.sh` | wallpapers, plus `.gallerydl.bak` and `.oauth.bak` variants | 304 lines of bash |
| quarry | nothing — yet it owns the source plugin system | 0 |

**The idea: Reddit becomes a quarry source, and Rodded is its specification.**

Rodded already solved the hard parts — the OAuth dance, the listing endpoints,
and above all Reddit's genuinely awkward media (previews vs galleries vs
crossposts vs `v.redd.it`). Porting that knowledge into `sources/reddit.rs` is
transcription, not design, and it is the difference between guessing at those
shapes and copying ones that already work.

What each side gets:

- **The shell** deletes `fetch_reddit.sh` and its two backup variants, exactly as
  it deletes `thumbgen-venv.sh` — one less script, one more source.
- **quarry** gains r/wallpapers and friends as first-class rows: cached,
  deduplicated by phash against the boorus, and sized to the monitor.
- **Rodded** can hand its media to quarryd — the ladder, the cache and the decode
  gate it does not have — and keep everything that is actually Reddit.

**The boundary matters, and it is not "merge them".** Rodded is a Reddit
*client*: comments, votes, subscriptions, the thread. None of that is quarry's
business and none of it should move. Only *"give me the pictures from r/X"*
overlaps, and only that moves. Rodded keeps `Api.qml` for everything else.

**Credentials** are already shared — `Auth.qml` reuses the quickshell config's —
so a Rust source reads the same store rather than inventing a third copy.


## The booru half: measured, and not worth doing

The plan above assumed `Booru.qml`'s 556 lines could become IPC calls. Tested,
they cannot — not all of them, and the remainder does not justify the change.

The shell browses seven providers. quarryd covers four (danbooru, safebooru,
yandere, and konachan, added while checking this). The other three are each
blocked for a different real reason, verified rather than assumed:

| provider | what happens | verdict |
|---|---|---|
| **gelbooru** | dapi answers **401** without `user_id` + `api_key` | needs credentials; a manifest was written and removed rather than ship a source that always fails |
| **waifu.im** | **403**, Cloudflare "Just a moment…" JS challenge | not reachable without a browser engine |
| **zerochan** | 200, but the JSON carries **only the 240px thumbnail** — `/600/` and `/full/` are 404 | useless to a tool that exports at monitor size |

That last one is the interesting failure: zerochan works perfectly as a *browser*
source, which is why the shell has it, and is near-worthless to a *fitting* tool,
which is what quarry is. The same API is fine for one and not the other.

**So the migration would leave both code paths in place permanently** — quarryd
for four providers, QML HTTP for three — to replace QML HTTP with QML IPC. That
is more moving parts for no removed capability, which is the opposite of what
the wallpaper half achieved (it deleted a Python virtualenv and ImageMagick
outright).

Revisit only if those three become reachable. Nothing else in this plan changes:
the wallpaper half stands on its own and is done.
