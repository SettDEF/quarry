# Scripts

One JavaScript file. No build, no QML, no restart — save it and quarry picks it
up within two seconds.

```
~/.local/share/quarry/scripts/*.js
```

Settings → Scripts lists what loaded, what each one is allowed to do, and the
line any of them threw on. `Add the example scripts` copies the ones quarry
ships into that folder, where you can edit them — which is the point: the
filter list inside `4chan-filter.js` **is** its settings screen.

## The shape of one

```js
// ==QuarryScript==
// @name        No tiny pictures
// @version     1.0
// @description Hides anything under 400px wide
// @author      you
// @match       *
// @grant       rows
// ==/QuarryScript==

quarry.on("rows", rows => rows.filter(r => (r.w || 0) >= 400));
```

The header is read before a line of the script runs. `@name`, `@version`,
`@description` and `@author` are what Settings shows. The two that do anything:

**`@match`** — where the script applies. `*` is everywhere; otherwise a
space- or comma-separated list of `source:<id>`, `lens:<id>` or `screen:<name>`.

```
// @match  lens:fourchan
// @match  source:danbooru, source:safebooru
```

**`@grant`** — what the script may reach, and the whole security model. A
script gets an API object built from its grants: no grant, no property. Not a
check at call time — the method is not there.

| grant | what it adds |
|---|---|
| `rows` | `quarry.on("rows", fn)` — filter **or reorder** what a screen shows |
| `menu` | `quarry.menu(label, fn, icon)` — a command in the item menu |
| `keys` | `quarry.key("j", fn)` — a keybind |
| `storage` | `quarry.storage.get/set` — survives restarts |
| `toast` | `quarry.toast(text)` |
| `clipboard` | `quarry.copy(text)` |
| `open` | `quarry.open(url)` — hands a link to your browser |
| `query` | `quarry.query("kind:wallpaper")` — drive the search bar |
| `keep` | `quarry.keep(item, "collection")` — the gallery-downloader move, without the folder of unsearchable files |
| `timer` | `quarry.every(seconds, fn)` — one second is the floor, and every timer dies on reload |
| `view` | `quarry.scroll(pxPerSecond)`, `quarry.step(±1)`, `quarry.viewerOpen()` — drives whatever view is on screen |
| `dock` | `quarry.dock(spec)` — a strip of controls, drawn by quarry |

`quarry.on(event, fn)` and `quarry.log(…)` need no grant: a script with none
can still listen and say what it is doing.

**There is no `fetch` grant.** Every userscript host has one and it is the
first thing anybody asks for. It is missing on purpose — the daemon has no
general "fetch this URL" method, and adding one for scripts would put a hole in
the three things that keep quarry welcome on the sites it reads: the per-host
rate limiter, the cache, and the honest User-Agent. A script that wants rows
asks the catalogue (`@grant query`), which goes through all three.

## The hooks

### `rows` — filter what is shown

```js
quarry.on("rows", function (rows, context) {
    return rows.filter(row => row.w >= 400);
});
```

Return the rows to keep, or nothing at all to leave the page alone. `context`
carries `{ source, kind, family, lens, screen, query }` in the gallery, and
`{ lens, screen, board }` inside the 4chan lens.

**What you drop is hidden, not removed.** The row keeps its cell and draws a
stub you can click through — the way a filtered post on 4chan X leaves
something behind. Two reasons: a shortened page sends the catalogue down its
"a short page is not an answer" path and re-requests forever, and a filter
whose effect you cannot see is a filter you cannot debug.

### `menu` — a command on an item

```js
quarry.menu("Copy the thread number", item => quarry.copy(String(item.no)), "tag");
```

Third argument is a Material Symbols name. Nothing is drawn when no script has
registered anything.

### `key` — a keybind

```js
quarry.key("y", context => quarry.copy(context.item.url));
```

**Bare letters and digits only.** Ctrl+F, Escape and the arrows stay the app's:
a script that captured those would read as a broken app rather than a script.
Nothing fires while you are typing.

### `dock` — controls on screen

```js
quarry.dock({
    title: "Autoscroll",
    icon: "swipe_down",
    items: [
        { id: "run",   kind: "toggle", label: "Scroll", icon: "play_arrow", value: false,
          on: on => { running = on; apply(); } },
        { id: "speed", kind: "slider", label: "px/s", min: 10, max: 340, step: 10, value: 60,
          on: v => { speed = Math.round(v); apply(); } }
    ]
});

quarry.dockSet("run", { value: true });   // change one control without redeclaring
```

A dock is **switched on from the ⋮ menu**, under Docks, and stays on across
restarts. The menu lists only the docks that apply where you are standing, so a
4chan script's dock is not offered while you are in the gallery.

Four kinds: `button`, `toggle`, `slider`, `label`. `on` is called with the new
value; `dockSet` is how the script writes a value back, which is what keeps the
switch honest when the same thing is done with a keybind instead.

**The script describes, quarry draws.** There is no widget tree here — a script
that could build QML items could reach the whole window. It says "a toggle
called Scroll", and what appears is the app's own control in the app's own
theme.

This exists because a keybind nobody told you about is a feature that does not
exist: autoscroll has had nine speeds since the day it was written, and the only
way to find that out was to open the file.

### events

```js
quarry.on("item.open", payload => remember(payload.item.id));
```

`item.open` fires the moment somebody opens something — which is the hook
"hide what I have already seen" is built on, and the reason it exists.

## What ships

| file | what it does |
|---|---|
| `4chan-filter.js` | hides threads and posts by word, name or tripcode, and counts what it hid |
| `4chan-watch.js` | marks threads and says when a watched one has new replies |
| `4chan-sort.js` | reorders a board by reply count and hides the quiet threads |
| `4chan-stickies.js` | drops pinned and closed threads |
| `4chan-images-only.js` | drops replies with no image, so a thread reads as a gallery |
| `copy-and-open.js` | `y` copies the link, `o` opens it — on every screen, which is why it is no longer named for one |
| `autoscroll.js` | scrolls the wall by itself; `a` toggles, `1`–`9` set the speed, `n`/`p` jump between videos, or use its dock |
| `video-autoplay.js` | Autoplay: videos play as you scroll and autoscroll waits on each; in an open picture a slideshow (`p`) moves on after its seconds or at a video's end; `m` sound |
| `seen-fades.js` | remembers everything you open and keeps it out of the way next time |
| `keep-the-thread.js` | one command that puts a picture into a collection |
| `no-tiny-pictures.js` | the smallest useful script — one hook, one condition |

These are quarry's own implementations of behaviours that userscripts made
ordinary — filtering, watching, keybinds, hiding what you have seen, keeping a
gallery. The ideas are borrowed and credited; none of the code is.

## When one breaks

A script that throws is caught, attributed and shown in Settings with the line;
everything else keeps running. Errors are reported the first time and not on
every row after it, because a hook that throws on every page of a scroll would
otherwise be a thousand identical toasts.

Loading is not sandboxed from itself: scripts share one JS engine and run in
the order the folder lists them. A script cannot reach the file system, the
daemon socket or another script's storage, but it can take as long as it likes
— so a `rows` hook that does real work per row will be felt on a wall of
165,000.
