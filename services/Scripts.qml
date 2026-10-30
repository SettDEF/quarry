pragma Singleton

import QtCore
import Quickshell
import Quickshell.Io
import QtQuick
import qs.modules.common

/*
 * USER SCRIPTS — QUARRY'S ANSWER TO A USERSCRIPT.
 *
 * A lens is QML: a file that has to be written against the app's own types,
 * loaded by a registry, restarted to take effect. That is the right shape for
 * a whole screen and completely the wrong shape for "hide anything under 400
 * pixels" or "press J for the next picture" — the small, personal, one-file
 * changes that Tampermonkey made ordinary on the web, and that 4chan X made
 * the reason people use 4chan at all. Read what those scripts DO and it is
 * nearly always one of four things: filter what is shown, add a menu command,
 * bind a key, or remember a preference.
 *
 * So a script here is one `.js` file, no build step, hot-reloaded when you
 * save it, with a metadata header in the userscript tradition:
 *
 *     // ==QuarryScript==
 *     // @name        No tiny pictures
 *     // @version     1.0
 *     // @description Drops anything under 400px from every wall
 *     // @match       source:danbooru        (or lens:morse, or * )
 *     // @grant       rows, toast
 *     // ==/QuarryScript==
 *
 *     quarry.on("rows", rows => rows.filter(r => r.w >= 400));
 *
 * WHAT A SCRIPT CAN REACH, AND WHY IT IS A SHORT LIST
 *
 * `@grant` is the whole security model, and it is deliberately coarse: a
 * script gets an API object built for it, holding only what it asked for. No
 * grant, no property — not a permission check at call time, an object that
 * does not have the method. Nothing here hands out the QML engine, the file
 * system, or the daemon socket: `fetch` goes through the daemon's own fetcher
 * so a script cannot become a way around quarry's rate limits and honest
 * User-Agent.
 *
 * WHY Qt.createQmlObject AND NOT eval
 *
 * A QML JS context has no `eval` worth relying on, and a function built from a
 * string has no file name, so an error in a script would point at nothing.
 * Wrapping the source in a tiny QML object gives the engine a real compile
 * unit with the script's own file name in the error — which is the difference
 * between "TypeError somewhere" and "no-tiny-pictures.js:7".
 */
Singleton {
    id: root

    readonly property string home: {
        const u = StandardPaths.writableLocation(StandardPaths.HomeLocation).toString();
        return u.replace(/^file:\/\//, "");
    }
    /// Where a person's own scripts live. One flat folder on purpose: a script
    /// is one file, and a folder per file is a project.
    readonly property string dir: `${root.home}/.local/share/quarry/scripts`

    /// [{ id, name, version, description, author, match, grants, settings,
    ///    path, enabled, error, hooks, menus, keys }]
    property var scripts: []
    property int revision: 0
    readonly property int failing: root.scripts.filter(s => s.error.length > 0).length
    /// Read on every page that lands, so it is a number rather than a walk.
    readonly property int rowHookCount: root._rowHooks.length

    signal changed

    // ── the registries the app reads ─────────────────────────────────────────
    /*
     * Held flat rather than per script, because every hook is read on a hot
     * path — a page of rows landing, a menu opening, a key going down — and
     * walking a list of scripts to build a list of callbacks on each one is
     * work done thousands of times to answer a question that changes when a
     * file is saved.
     */
    property var _rowHooks: []          // [{ id, match, fn }]
    property var _menuItems: []         // [{ id, label, icon, fn }]
    property var _keyBinds: ({})        // key -> [{ id, fn }]
    property var _eventHooks: ({})      // event -> [{ id, fn }]
    property var _store: ({})           // id -> { key: value }
    /*
     * A SCRIPT'S OWN STRIP OF CONTROLS.
     *
     * Keys are how a script has always been driven, and a key you have to
     * already know about is a feature nobody finds: autoscroll has nine speeds
     * and the only way to learn that was to read the file. A dock is the other
     * half — the same script, with its buttons drawn on screen, switched on
     * from the overflow menu like anything else and remembered across
     * restarts.
     *
     * Held here rather than inside the script because the app draws it: a
     * script that could create QML items could reach the whole window.
     */
    property var _docks: []             // [{ id, name, match, title, icon, items }]

    /*
     * ROWS, ON THEIR WAY TO THE SCREEN.
     *
     * The one hook that has to be fast. A script returns a filtered array, or
     * nothing at all to leave the page alone; anything it throws is caught and
     * attributed, because a broken script must cost its author a red line in
     * settings and everyone else nothing.
     */
    function filterRows(items, context) {
        if (root._rowHooks.length === 0 || !items || items.length === 0)
            return items;
        let rows = items;
        for (const hook of root._rowHooks) {
            if (!root._matches(hook.match, context))
                continue;
            try {
                const out = hook.fn(rows, context || ({}));
                if (Array.isArray(out))
                    rows = out;
            } catch (e) {
                root._blame(hook.id, `rows hook: ${e}`);
            }
        }
        return rows;
    }

    /// The menu commands scripts have registered — the app draws them.
    function menuItems() {
        return root._menuItems;
    }

    // ── docks ────────────────────────────────────────────────────────────────
    /// Every dock a loaded script offers, whether or not it is showing.
    function docks() {
        return root._docks;
    }

    /// The docks that should be on screen right now: switched on, and declared
    /// by a script whose `@match` covers where you are.
    function openDocks() {
        return root._docks.filter((d) => {
            return Prefs.openDocks.indexOf(d.id) >= 0 && root._matches(d.match, root.hereContext());
        });
    }

    /*
     * A SCRIPT'S OWN ACTIONS, FOR THE ⋮ MENU — the way a Rodded extension
     * contributes rows to the header's overflow.
     *
     * A switch that says only "Autoscroll is on" is the least interesting
     * thing a script has to offer: what anybody wants from that menu is to
     * START it, and to change the one number it runs on. So the controls come
     * up here as rows, filtered to where you are standing like everything else
     * scripts do.
     */
    function menuControls() {
        const out = [];
        for (const dock of root._docks) {
            if (!root._matches(dock.match, root.hereContext()))
                continue;
            for (const item of dock.items) {
                const wanted = item.menu !== undefined && item.menu !== null ? item.menu !== false : (item.kind === "toggle" || item.kind === "slider");
                if (!wanted)
                    continue;
                out.push({
                    "dock": dock.id,
                    "id": item.id,
                    "kind": item.kind,
                    // A row with no heading over it has to name itself.
                    "label": typeof item.menu === "string" && item.menu.length > 0 ? item.menu : (item.kind === "slider" ? `${dock.title} speed` : dock.title),
                    "icon": item.icon.length > 0 ? item.icon : dock.icon,
                    "value": item.value,
                    "min": item.min,
                    "max": item.max,
                    "step": item.step,
                    "unit": item.kind === "slider" ? item.label : ""
                });
            }
        }
        return out;
    }

    function dockShowing(id) {
        return Prefs.openDocks.indexOf(id) >= 0;
    }

    function setDockShowing(id, on) {
        const now = Prefs.openDocks.filter(x => x !== id);
        Prefs.openDocks = on ? now.concat([id]) : now;
        root.revision++;
        root.changed();
    }

    /*
     * A CONTROL WAS USED. The value is written back into the registry before
     * the script is called, so a toggle that throws still shows what it was
     * set to rather than silently springing back.
     */
    /*
     * A DOCK FROM SOMETHING THAT IS NOT A SCRIPT.
     *
     * The strip, the overflow menu, the "showing" switch, the settings rows and
     * `runDock` all work off this one list, so an extension that registers here
     * gets every one of them without a second implementation — which is the
     * whole reason it is this list and not a parallel one.
     *
     * `owner` marks where it came from: a reload rebuilds the script docks and
     * must leave these alone, and a failing handler is blamed on the extension
     * rather than on a script id that does not exist.
     */
    function registerDock(id, dock) {
        if (!id || !dock)
            return ;

        const entry = Object.assign({}, dock, {
            "id": String(id),
            "name": String(dock.name || dock.title || id),
            "match": dock.match || "*",
            "owner": "extension",
            "items": dock.items || []
        });
        root._docks = root._docks.filter(d => d.id !== entry.id).concat([entry]);
        root.revision++;
    }

    function unregisterDock(id) {
        root._docks = root._docks.filter(d => d.id !== String(id));
        root.revision++;
    }

    function runDock(scriptId, itemId, value) {
        const dock = root._docks.find(d => d.id === scriptId);
        if (!dock)
            return;
        const item = dock.items.find(i => i.id === itemId);
        if (!item)
            return;
        if (value !== undefined)
            item.value = value;
        root.revision++;
        if (typeof item.on !== "function")
            return;
        try {
            item.on(item.value);
        } catch (e) {
            root._blame(scriptId, `dock "${item.label || itemId}": ${e}`);
        }
    }

    /*
     * WHERE YOU ARE, in the shape `@match` is written against. The row hook is
     * handed one by whoever is drawing rows; a dock and a settings list have to
     * ask, because nothing is landing when they need the answer.
     */
    function hereContext() {
        return {
            "lens": Lenses.activeId,
            "screen": Lenses.activeLens ? String(Lenses.activeLens.screen || "") : "",
            "source": Catalog.filterValue("source"),
            "query": Catalog.query
        };
    }

    /*
     * THE SCRIPTS THAT APPLY WHERE YOU ARE.
     *
     * What the overflow menu lists: switching one on or off is a thing people
     * do while looking at the thing it changes, and sending them to a settings
     * page for it meant the filter script and the wall it filters were never
     * on screen together. The 4chan ones are left out here on purpose — a list
     * of eleven, five of which do nothing where you are standing, is a list
     * nobody reads. Settings shows all of them.
     */
    function hereScripts() {
        return root.scripts.filter((s) => {
            return root._matches(s.match, root.hereContext());
        });
    }

    /// Whether a script applies where you are standing.
    function appliesHere(match) {
        return root._matches(match, root.hereContext());
    }

    /*
     * `@match` IN WORDS.
     *
     * "lens:fourchan" is what the file says and not what a settings page should
     * — a person reading a list of scripts wants to know which of them are
     * running here and which are waiting for somewhere else.
     */
    function scopeLabel(match) {
        if (!match || match === "*")
            return "Everywhere";
        const parts = String(match).split(/[,\s]+/).filter(x => x.length > 0).map((clause) => {
            const bits = clause.indexOf(":") > 0 ? clause.split(":") : ["", clause];
            const name = bits[1];
            if (bits[0] === "lens") {
                const entry = Lenses.find(name);
                return entry ? entry.name : name;
            }
            if (bits[0] === "screen")
                return `the ${name} screen`;
            return name;
        });
        return parts.join(", ");
    }

    function runMenu(entry, item) {
        try {
            entry.fn(item || null);
        } catch (e) {
            root._blame(entry.id, `menu "${entry.label}": ${e}`);
        }
    }

    /// A key went down somewhere the gallery owns. True if a script took it.
    function key(name, context) {
        const bound = root._keyBinds[String(name)];
        if (!bound || bound.length === 0)
            return false;
        let taken = false;
        for (const b of bound) {
            try {
                b.fn(context || ({}));
                taken = true;
            } catch (e) {
                root._blame(b.id, `key "${name}": ${e}`);
            }
        }
        return taken;
    }

    /// Something happened that scripts may care about: a lens opened, an item
    /// was viewed, a query ran.
    function emit(event, payload) {
        const listeners = root._eventHooks[String(event)];
        if (!listeners)
            return;
        for (const l of listeners) {
            try {
                l.fn(payload || ({}));
            } catch (e) {
                root._blame(l.id, `on("${event}"): ${e}`);
            }
        }
    }

    // ── loading ──────────────────────────────────────────────────────────────
    /*
     * ONE LOAD AT A TIME.
     *
     * The reader works through a queue of files, one shell at a time, so a load
     * takes several turns. A second `reload()` arriving mid-queue used to clear
     * the list and restart the lister while the old queue was still draining
     * into it — so the files that landed after the clear were counted twice.
     * Measured: twelve scripts on disk, fourteen loaded.
     *
     * It was always reachable (the folder is polled every two seconds, and a
     * save during a load does exactly this); asking for the stored settings
     * when they arrive made it happen on every start.
     */
    property bool _loading: false
    property bool _reloadQueued: false

    function reload() {
        if (root._loading) {
            root._reloadQueued = true;
            return;
        }
        root._loading = true;
        root._clear();
        lister.running = true;
    }

    function _loadDone() {
        root._loading = false;
        if (!root._reloadQueued)
            return;
        root._reloadQueued = false;
        root.reload();
    }

    function open() {
        Sys.run(["mkdir", "-p", root.dir], function () {
            Sys.open(root.dir);
        });
    }

    /*
     * THE EXAMPLES, COPIED RATHER THAN LOADED.
     *
     * quarry ships eleven of them, and they are NOT loaded from where they are
     * installed — they are copied into your folder on request. A shipped
     * script that ran from /usr/share would be a script you cannot edit, and
     * editing them is the entire point: the filter list in the 4chan one IS
     * its settings screen.
     */
    function installExamples() {
        const from = Qt.resolvedUrl("../scripts").toString().replace(/^file:\/\//, "");
        Sys.run(["sh", "-c", `mkdir -p '${root.dir}' && cp -n '${from}'/*.js '${root.dir}'/ 2>/dev/null; ls -1 '${root.dir}'/*.js | wc -l`], function (ok) {
            if (!ok) {
                Toast.error("Could not copy the examples");
                return;
            }
            Toast.show("Examples copied — edit them in the scripts folder");
            root.reload();
        });
    }

    function setEnabled(id, on) {
        const off = Object.assign({}, root._disabled);
        if (on)
            delete off[id];
        else
            off[id] = true;
        root._disabled = off;
        Prefs.disabledScripts = Object.keys(off);
        root.reload();
    }

    property var _disabled: {
        const out = {};
        for (const id of Prefs.disabledScripts || [])
            out[id] = true;
        return out;
    }

    /// Everything unloaded — what "run scripts: off" means.
    function clearAll() {
        root._clear();
        root.revision++;
        root.changed();
    }

    property var _timers: []

    /*
     * AUTOSCROLL, DRIVEN BY QUARRY RATHER THAN BY THE SCRIPT.
     *
     * A script says "sixty pixels a second" and stops caring. Doing it the
     * other way — a script with its own timer writing `contentY` — means
     * every script that scrolls reimplements easing, clamping and the end of
     * the list, and gets at least one of them wrong.
     *
     * The timer only runs while something asked for it, so a person with no
     * scrolling script pays nothing.
     */
    property real scrollSpeed: 0
    /// Wall-clock ms until the scroller may move again — see the dwell above.
    property double _holdUntil: 0
    /// Carried motion for the eased scroll, and how long the post-touch
    /// slowdown lasts. Plain properties, not bindings: they change every tick.
    property real _glide: 0
    property double _dampenUntil: 0

    /*
     * SNAP: centre the video that reached the middle, then hold on it.
     *
     * From the Reddtastic userscript. A playing tile calls snapTo() when its
     * centre comes within Prefs.snapTolerance of the view's; the scroller eases
     * the remaining distance, then waits the dwell. Each video snaps once. Tiles
     * side by side play together, so their holds overlap rather than add up.
     */
    /// Set by the Slideshow (api.slideshow): the viewer's video plays once and reports its end.
    property bool slideshowRunning: false
    property real _snapLeft: 0
    property var _snapped: ({})        // token -> when its hold started (ms)
    property int _snappedCount: 0

    function snapTo(token, delta, seconds) {
        if (!Prefs.dwellOnVideo || !Prefs.snapToVideo || root.scrollSpeed === 0 || !token)
            return ;
        if (root._snapped[token] !== undefined)
            return ;
        if (root._snappedCount > 400) {         // a long session; forget the oldest pass
            root._snapped = ({});
            root._snappedCount = 0;
        }
        const now = Date.now();
        root._snapped[token] = now;
        root._snappedCount++;
        // Everything playing now plays through this wait too, so it has had its turn.
        // Without this a many-column wall stopped on every staggered video and barely moved.
        for (const other of PlayGate.holderList) {
            if (root._snapped[other] === undefined) {
                root._snapped[other] = now;
                root._snappedCount++;
            }
        }
        if (root._holdUntil <= now)
            root._snapLeft = delta;
        root._holdUntil = Math.max(root._holdUntil, now + 350 + root._dwellMs(seconds > 0 ? seconds : 0));
        root._glide = 0;
    }

    /// A snapped clip's length arrived after the snap: stretch its hold to match.
    function noteDuration(token, seconds) {
        const started = root._snapped[token];
        if (started === undefined || !(seconds > 0) || root._holdUntil <= Date.now())
            return ;
        root._holdUntil = Math.max(root._holdUntil, started + 350 + root._dwellMs(seconds));
    }

    function autoplayState() {
        return {
            "on": Prefs.autoplayInView,
            "all": Prefs.autoplaySlots === 0,
            "sound": Prefs.hoverSound,
            "hold": Prefs.dwellOnVideo,
            "centre": Prefs.snapToVideo,
            "slots": Prefs.autoplaySlots,
            "threshold": Prefs.autoplayThreshold,
            "watch": Prefs.dwellMode,
            "seconds": Prefs.dwellSeconds,
            "percent": Prefs.dwellPercent,
            "longest": Prefs.dwellMaxSeconds
        };
    }
    // Settings changed them: tell scripts (the Autoplay dock), so the two never disagree.
    Connections {
        target: Prefs
        function onAutoplayInViewChanged() { root.emit("autoplay", root.autoplayState()); }
        function onAutoplaySlotsChanged() { root.emit("autoplay", root.autoplayState()); }
        function onHoverSoundChanged() { root.emit("autoplay", root.autoplayState()); }
        function onDwellOnVideoChanged() { root.emit("autoplay", root.autoplayState()); }
        function onSnapToVideoChanged() { root.emit("autoplay", root.autoplayState()); }
        function onAutoplayThresholdChanged() { root.emit("autoplay", root.autoplayState()); }
        function onDwellModeChanged() { root.emit("autoplay", root.autoplayState()); }
        function onDwellSecondsChanged() { root.emit("autoplay", root.autoplayState()); }
        function onDwellPercentChanged() { root.emit("autoplay", root.autoplayState()); }
        function onDwellMaxSecondsChanged() { root.emit("autoplay", root.autoplayState()); }
    }

    /// Live gallery tiles, for jumping between videos. Plain JS: tiles come and go at scroll speed.
    property var _tiles: []
    function registerTile(tile) {
        root._tiles.push(tile);
    }
    function unregisterTile(tile) {
        const i = root._tiles.indexOf(tile);
        if (i >= 0)
            root._tiles.splice(i, 1);
    }

    /*
     * N / P: the next or previous video, centred.
     *
     * Picks among the tiles that exist (the visible window and its overscan);
     * with none that way, moves a screen so the next press finds one. While
     * autoscrolling it eases there and holds like a snap; otherwise it jumps.
     */
    function jumpVideo(dir) {
        const view = root.liveScrollable();
        if (!view)
            return false;
        const tol = Prefs.snapTolerance;
        let best = null;
        let bestOff = 0;
        for (const t of root._tiles) {
            if (!t || !t.isVideo || !t.visible || t.blurred || !(t.viewHeight > 0))
                continue;
            const off = t.viewOffset + t.height / 2;
            if (dir > 0 ? off <= tol : off >= -tol)
                continue;
            if (!best || (dir > 0 ? off < bestOff : off > bestOff)) {
                best = t;
                bestOff = off;
            }
        }
        const delta = best ? bestOff : dir * view.height * 0.9;
        if (best) {
            root._snapped[best.playToken] = Date.now();
            root._snappedCount++;
        }
        if (root.scrollSpeed !== 0) {
            root._snapLeft = delta;
            root._glide = 0;
            root._holdUntil = best ? Date.now() + 350 + root._dwellMs(best._seconds > 0 ? best._seconds : 0) : 0;
        } else {
            const lo = view.originY || 0;
            const hi = lo + Math.max(0, view.contentHeight - view.height);
            view.contentY = Math.max(lo, Math.min(hi, view.contentY + delta));
        }
        return !!best;
    }

    property bool _moving: false
    onScrollSpeedChanged: {
        if (root.scrollSpeed !== 0) {
            // Just started: what is already playing was being watched, so the
            // first stop is for a video that scrolls in, not the one under you.
            if (!root._moving) {
                root._moving = true;
                for (const t of PlayGate.holderList) {
                    root._snapped[t] = Date.now();
                    root._snappedCount++;
                }
            }
            return ;
        }
        root._moving = false;
        // Stopped: any wait goes with it, so starting again moves at once.
        root._holdUntil = 0;
        root._snapLeft = 0;
        root._snapped = ({});
        root._snappedCount = 0;
    }

    /*
     * The dwell is armed by the ELECTION changing, not by a timer of its own:
     * PlayGate bumps `revision` only when the set of playing tiles actually
     * differs, so this fires once per new video rather than once per frame.
     */
    Connections {
        target: PlayGate

        function onRevisionChanged() {
            // With snapping on, the hold starts at the middle (snapTo), not when a tile starts playing.
            if (!Prefs.dwellOnVideo || root.scrollSpeed === 0 || Prefs.snapToVideo)
                return ;
            if (PlayGate.playing <= 0)
                return ;

            root._holdUntil = Date.now() + root._dwellMs();
        }
    }
    /// How long the view has sat at an end without changing shape, and the
    /// shape it had — see the scroller.
    property int _endTicks: 0
    property string _endShape: ""

    /*
     * WHATEVER IS ON SCREEN — not whatever the gallery is.
     *
     * Autoscroll drove `Shell.gallery`, so it worked on the wall and did
     * nothing in a lens, in history, or on any screen written after it. A
     * script that only scrolls one of a dozen surfaces is not "autoscroll",
     * it is autoscroll-for-the-gallery.
     *
     * So the view is FOUND rather than named: the biggest visible thing on
     * screen that can actually scroll. Biggest by area, because every screen
     * has small scrollable corners — a sidebar, a chip row, a menu — and the
     * one you mean is always the one you are looking at. Nothing has to
     * register itself, which is what makes this work for screens nobody has
     * written yet.
     */
    /*
     * HOW LONG TO WAIT ON THE CLIP THAT JUST STARTED.
     *
     * "Watch mode", from the userscript this follows: the whole thing, a
     * fraction of it, or a flat number of seconds. The whole thing is the
     * honest default; the other two exist because a ten-minute video is not
     * something a scrolling wall should sit through.
     *
     * A length of 0 means nobody measured one — a picture, or a video whose
     * duration the source never published — so every mode falls back to the
     * fixed seconds rather than waiting forever or not at all. The cap on
     * "full" is the same idea: a two-hour file is not a dwell, it is a stop.
     */
    function _dwellMs(seconds) {
        const fixed = Math.max(0, Prefs.dwellSeconds) * 1000;
        const length = seconds !== undefined ? seconds : PlayGate.lastDuration;
        if (!(length > 0))
            return fixed;

        // "Whole" and "part" stop at the longest wait: a five-minute clip must
        // not park the wall for five minutes (measured: a 287 s hold read as broken).
        const longest = Math.max(1, Prefs.dwellMaxSeconds) * 1000;
        if (Prefs.dwellMode === "full")
            return Math.min(length * 1000, longest);

        if (Prefs.dwellMode === "percent")
            return Math.min(length * Math.max(1, Math.min(100, Prefs.dwellPercent)) / 100 * 1000, longest);

        return fixed;
    }

    /*
     * THE SAME ANSWER, WITHOUT ASKING SIXTY TIMES A SECOND.
     *
     * `scrollable()` walks the whole window — every item, twelve deep — and the
     * scroll timer called it on EVERY tick. Inside a lens that is the lens's
     * entire UI re-walked at 60Hz for an answer that changes when you open
     * something, and at no other time. That cost lands on the same thread that
     * draws the lens, which is why autoscroll is felt most exactly where the
     * UI is busiest.
     *
     * So the surface is remembered. Two things can invalidate it: the context
     * changing (a viewer opening, a different lens) which is what `key` below
     * catches, and the surface itself going away — a lens torn down mid-scroll
     * leaves a destroyed object behind, and reading a property off one throws
     * inside the timer. That is caught and treated as "re-resolve", not as an
     * error, because it is the ordinary consequence of closing a lens while it
     * is scrolling.
     */
    property var _view: null
    property string _viewKey: ""

    function liveScrollable() {
        /*
         * WHAT THE VIEW ON SCREEN SAID IT WAS.
         *
         * Every layout and every lens skin claims `Host.activeFlickable` as it
         * appears, so the usual case needs no search at all — and the answer is
         * the surface the skin MEANT, not the biggest one in it. That is the
         * difference inside a lens: a conversation beside a chat list are two
         * scrollables of similar size, and which one autoscroll drove came down
         * to which happened to be wider.
         *
         * The walk below stays as the fallback, for a screen that claims
         * nothing.
         */
        /*
         * A WALL UNDER AN OPEN VIEWER IS STILL VISIBLE, and still holds its
         * claim. Opening a picture is the clearest statement that THIS is what
         * you want — so while the viewer is up, only the viewer's own claim
         * counts, and anything else falls to the walk below (which answers
         * "nothing" rather than the wall behind).
         */
        const claimed = Host.activeFlickable;
        const trusted = !Shell.detailOpen || Host.activeOwner === Shell.detail;
        if (trusted && claimed) {
            try {
                if (claimed.visible && claimed.height > 80 && claimed.contentHeight > claimed.height + 1)
                    return claimed;
            } catch (e) {
                // Destroyed under us; fall through to the walk.
            }
        }

        const key = (Shell.detailOpen ? "detail" : "wall") + "|" + Lenses.activeId;
        if (key !== root._viewKey) {
            root._viewKey = key;
            root._view = null;
        }
        if (root._view) {
            try {
                const v = root._view;
                // Still there, still visible, still has somewhere to go.
                if (v.visible && v.height > 80 && v.contentHeight > v.height + 1)
                    return v;

            } catch (e) {
                // Destroyed under us. Fall through and look again.
            }
            root._view = null;
        }
        root._view = root.scrollable();
        return root._view;
    }

    function scrollable() {
        const window = Shell.window;
        if (!window || !window.contentItem)
            return null;

        /*
         * A COVERED SURFACE IS NOT THE ONE YOU ARE LOOKING AT.
         *
         * The search picks the biggest scrollable on screen, and the wall is
         * always the biggest — including while a picture is open on top of it.
         * So opening something left the wall sliding along underneath, and
         * closing it put you somewhere you had never been. Opening a picture is
         * the clearest statement there is that THIS is what you want to look
         * at.
         *
         * The viewer is searched instead when one is open, because a lens
         * viewer scrolls too — a thread, a comment list — and that is a surface
         * worth driving. If it has nothing scrollable, nothing scrolls, which
         * is the right answer rather than falling back to the wall behind.
         */
        const root = Shell.detailOpen && Shell.detail ? Shell.detail : window.contentItem;
        let best = null;
        let bestArea = 0;
        const walk = function (item, depth) {
            if (!item || depth > 12 || item.visible === false || item.opacity === 0)
                return;
            const scrolls = item.contentHeight !== undefined && item.contentY !== undefined;
            if (scrolls && item.height > 80 && item.contentHeight > item.height + 1) {
                const area = item.width * item.height;
                if (area > bestArea) {
                    bestArea = area;
                    best = item;
                }
            }
            const kids = item.children || [];
            for (let i = 0; i < kids.length; i++)
                walk(kids[i], depth + 1);
        };
        walk(root, 0);
        // Only fall back to the wall when nothing is covering it.
        return best || (Shell.detailOpen ? null : Shell.gallery);
    }

    property Timer _scroller: Timer {
        interval: 16
        repeat: true
        running: root.scrollSpeed !== 0 && Prefs.scriptsEnabled

        onTriggered: {
            const view = root.liveScrollable();
            if (!view) {
                root.scrollSpeed = 0;
                root.emit("scrollend", { "reason": "gone" });
                return;
            }
            /*
             * DWELL ON A VIDEO THAT HAS JUST STARTED.
             *
             * Autoscroll and autoplay without this are two features that
             * ignore each other: the wall slides on at a steady rate and a
             * clip gets whatever fraction of a second it happens to be on
             * screen for, which is no way to watch anything.
             *
             * Not "pause while a video plays" — with autoplay on, something is
             * ALWAYS playing, so that setting would simply stop the scroll for
             * good. It holds each time the set of playing tiles CHANGES, which
             * is each time something new has come into view, and then carries
             * on by itself.
             */
            // Ease the last of a snap before holding: a quarter of what is left per tick.
            if (Math.abs(root._snapLeft) > 0.5 && !view.dragging && !view.flicking) {
                const lo = view.originY || 0;
                const hi = lo + Math.max(0, view.contentHeight - view.height);
                const step = root._snapLeft * 0.25;
                view.contentY = Math.max(lo, Math.min(hi, view.contentY + step));
                root._snapLeft -= step;
                return ;
            }
            root._snapLeft = 0;
            if (root._holdUntil > Date.now())
                return ;

            /*
             * YOUR HAND BEATS THE TIMER.
             *
             * While you are dragging or flicking, two things are moving the
             * same view and the slower one wins — the wall creeps against your
             * hand and lands somewhere neither of you chose. So the script
             * yields, and comes back `idleSeconds` after you stop.
             *
             * It yields rather than stops: stopping would make you press play
             * again every time you nudged the list to look at something, which
             * is exactly when you least want to go hunting for a control.
             */
            if (view.dragging || view.flicking) {
                // However it resolves, your own scroll earns the slowdown.
                root._dampenUntil = Date.now() + 900;
                root._glide = 0;
                root._holdUntil = Date.now() + (Prefs.resumeAfterTouch ? Math.max(0, Prefs.idleSeconds) * 1000 : 0);
                if (!Prefs.resumeAfterTouch) {
                    root.scrollSpeed = 0;
                    root.emit("scrollend", { "reason": "touched" });
                }
                return ;
            }

            // Still, while you are looking at one. See Shell.hoveredTiles.
            if (Prefs.pauseOnHover && Shell.overPicture)
                return ;

            /*
             * THE RANGE STARTS AT `originY`, NOT AT ZERO.
             *
             * A Flickable's scroll range is `originY … originY + contentHeight
             * - height`, and `originY` is only 0 for the ordinary top-to-bottom
             * case. A ListView with `verticalLayoutDirection: VerticalBottomToTop`
             * — a chat, where the newest message is at the bottom — runs
             * NEGATIVE: measured on a 40-row list, −1200 … −200.
             *
             * So `Math.max(0, next)` clamped the view to 0, which is outside
             * that range entirely, and the conversation sat pinned and
             * motionless. Autoscroll did nothing at all in the morse lens and
             * worked everywhere else, which read as the lens being unsupported
             * rather than as one wrong constant.
             *
             * Increasing contentY is visually downward in BOTH layouts
             * (measured: top row went 0→33 one way, 39→6 the other), so the
             * direction needs no special case — only the bounds do.
             */
            const top = view.originY || 0;
            const bottom = top + Math.max(0, view.contentHeight - view.height);

            /*
             * HOW FAST, before anything is moved.
             *
             * Three things can change it, and they multiply rather than
             * override: the pointer's height on the screen, a short slowdown
             * after you touched it yourself, and nothing at all when both are
             * off. Each is a separate switch because each answers a different
             * complaint — "too fast to read", and "it fought me".
             */
            let rate = root.scrollSpeed;

            /*
             * Keep the pointer low and it hurries; raise it and it slows to let
             * you read. −1 is the pointer being somewhere else entirely, which
             * leaves the rate alone rather than treating it as the top.
             */
            if (Prefs.pointerSteersSpeed && Shell.pointerFrac >= 0)
                rate *= 0.35 + Shell.pointerFrac * 1.3;

            // A brief slowdown after your own scroll, recovering on its own.
            if (Prefs.dampenAfterTouch && root._dampenUntil > Date.now())
                rate *= 0.35;

            const step = rate * (interval / 1000);
            /*
             * EASED, or stepped.
             *
             * Moving by the full step every tick is correct and looks mechanical
             * — the wall advances in even jumps regardless of what is on it.
             * Smoothing carries a little of the previous frame's motion into
             * this one, which is what makes a long read feel like gliding
             * rather than ratcheting. `smoothness` is how much of the old
             * motion survives, so 0 is the stepped version exactly.
             */
            if (Prefs.smoothScroll) {
                const keep = Math.max(0, Math.min(0.95, Prefs.scrollSmoothness));
                root._glide = root._glide * keep + step * (1 - keep);
            } else {
                root._glide = step;
            }
            const next = view.contentY + root._glide;
            /*
             * EITHER END IS AN END, AND NEITHER IS NECESSARILY THE END.
             *
             * A list that is still growing has not finished, so a boundary only
             * starts a two-second count and a change of shape resets it.
             *
             * BOTH ends need that, not just the bottom. A Morse conversation
             * prepends older messages at the TOP — which is the direction you
             * read a chat in — so an upward scroll hit the boundary, stopped
             * dead and announced "Stopped at the top" while the history it was
             * waiting for was still on its way. Autoscroll in Morse therefore
             * worked for about one second.
             *
             * Shape is `contentHeight` AND `originY`: a bottom-to-top list
             * grows by moving originY negative, leaving contentHeight's
             * relation to the boundary unchanged.
             *
             * It stops out loud (`scrollend`) — the script owns the toggle and
             * has no other way to learn that the host stopped it.
             */
            const end = next >= bottom ? "bottom" : (next <= top ? "top" : "");
            if (end.length === 0) {
                view.contentY = next;
                // Only when there is something to clear: this runs at 60 Hz.
                if (root._endTicks !== 0) {
                    root._endTicks = 0;
                    root._endShape = "";
                }
                return;
            }
            view.contentY = end === "bottom" ? bottom : top;

            const shape = `${Math.round(view.contentHeight)}|${Math.round(view.originY || 0)}`;
            if (shape !== root._endShape) {
                root._endShape = shape;
                root._endTicks = 0;
                return;
            }
            root._endTicks++;
            // Two seconds: long enough for a page from a slow source, short
            // enough that the real end does not feel like a hang.
            if (root._endTicks < 120)
                return;

            root.scrollSpeed = 0;
            root.emit("scrollend", { "reason": end });
        }
    }

    function _clear() {
        // A reload that left the old file's timers running would double them
        // on every save — the classic way a hot-reloading host leaks.
        for (const t of root._timers) {
            t.running = false;
            t.destroy();
        }
        root._timers = [];
        root._rowHooks = [];
        root._menuItems = [];
        root._keyBinds = ({});
        root._eventHooks = ({});
        root.slideshowRunning = false;  // a reloaded slideshow says so again if it runs
        /*
         * An extension's dock SURVIVES a script reload.
         *
         * `_docks` is rebuilt from the script files every time one is saved,
         * which is right for scripts and wrong for everything else in the
         * list: an extension registered its dock once, at enable, and nothing
         * about editing an unrelated .js file should take it away. It would
         * come back only when the extension was toggled off and on, which is
         * not a thing anyone would think to do.
         */
        root._docks = root._docks.filter(d => d.owner === "extension");
        root.scripts = [];
    }

    function _blame(id, message) {
        const next = root.scripts.map(s => s.id === id ? Object.assign({}, s, {
            "error": String(message).slice(0, 300)
        }) : s);
        root.scripts = next;
        root.revision++;
        root.changed();
        Toast.error(`${id}: ${String(message).slice(0, 80)}`);
    }

    /*
     * `@match` — which screens a script applies to.
     *
     * Deliberately not a URL pattern: quarry has no URLs. What a script needs
     * to say is "on this source", "in this lens", or "everywhere", so those
     * are the three forms, and anything else is a name to be matched against
     * both.
     */
    function _matches(match, context) {
        if (!match || match === "*")
            return true;
        const c = context || ({});
        for (const clause of String(match).split(/[,\s]+/).filter(x => x.length > 0)) {
            if (clause === "*")
                return true;
            const [key, value] = clause.indexOf(":") > 0 ? clause.split(":") : ["", clause];
            if (key === "source" && String(c.source || "") === value)
                return true;
            if (key === "lens" && String(c.lens || "") === value)
                return true;
            if (key === "screen" && String(c.screen || "") === value)
                return true;
            if (key.length === 0 && (String(c.source || "") === value || String(c.lens || "") === value))
                return true;
        }
        return false;
    }

    /// The header block, read before a line of the script runs — the same
    /// order userscripts have done it for twenty years.
    /*
     * A SETTING A SCRIPT DECLARES, so it can be changed without editing it.
     *
     * Until now a script's options lived in `let speed = ...` at the top of
     * its own file and the only way to change one was to open the file —
     * which is fine for the person who wrote it and no use to anyone else.
     * The dock could show a couple, but a dock is for what you change WHILE
     * watching; the rest had nowhere to be.
     *
     * Pipe-separated, because the values are prose: a label and a description
     * both contain spaces, and splitting those on whitespace is how a parser
     * starts guessing.
     *
     *     // @setting speed | number | 60 | Speed | 10..400 | Pixels a second
     *     // @setting up    | switch | false | Scroll upward
     *     // @setting dwell | choice | 5 | Wait | 3,5,10,20 | Seconds per clip
     *
     * key | type | default | label | range-or-options | description
     *
     * The value is stored under the script's OWN storage key, so a script
     * already reading `quarry.storage.get("speed", 60)` picks its setting up
     * with no change at all — the declaration only gives it a face.
     */
    function _setting(spec) {
        const parts = String(spec).split("|").map(p => p.trim());
        if (parts.length < 4)
            return [];

        const type = parts[1].toLowerCase();
        if (["number", "switch", "choice"].indexOf(type) < 0)
            return [];

        const out = {
            "key": parts[0],
            "type": type,
            "label": parts[3],
            "description": parts[5] || "",
            "min": 0,
            "max": 100,
            "step": 1,
            "options": []
        };
        const range = parts[4] || "";
        if (type === "number") {
            out.def = Number(parts[2]) || 0;
            const m = range.match(/(-?\d+(?:\.\d+)?)\s*\.\.\s*(-?\d+(?:\.\d+)?)(?:\s+step\s+(-?\d+(?:\.\d+)?))?/);
            if (m) {
                out.min = Number(m[1]);
                out.max = Number(m[2]);
                out.step = m[3] ? Number(m[3]) : 1;
            }
        } else if (type === "switch") {
            out.def = String(parts[2]).toLowerCase() === "true";
        } else {
            out.def = parts[2];
            out.options = range.split(",").map(o => o.trim()).filter(o => o.length > 0);
        }
        if (!out.key || !out.label)
            return [];

        return [out];
    }

    /// The declared settings of a loaded script, with the value each one has
    /// now — the stored one, or the default it declared.
    function settingsFor(id) {
        const meta = (root.scripts || []).find(s => s.id === id);
        if (!meta || !meta.settings)
            return [];

        const mine = root._store[id] || ({});
        return meta.settings.map(function (s) {
            const held = mine[s.key];
            return Object.assign({}, s, {
                "value": held === undefined ? s.def : held
            });
        });
    }

    /*
     * Written to the script's own store, then the script is RELOADED.
     *
     * A script reads its options into local variables when it runs, so a value
     * changed underneath it would not be noticed until something else made it
     * reload. Reloading is cheap — these are a few dozen lines each — and it
     * is the only version of this that is true for every script rather than
     * for the ones that happen to re-read their storage.
     */
    function setSetting(id, key, value) {
        const all = Object.assign({}, root._store);
        all[id] = Object.assign({}, all[id] || ({}));
        all[id][key] = value;
        root._store = all;
        Prefs.scriptStore = all;
        root.reload();
    }

    function _header(source, path) {
        const meta = {
            "id": path.replace(/^.*\//, "").replace(/\.js$/, ""),
            "name": "",
            "version": "",
            "description": "",
            "author": "",
            "match": "*",
            "grants": [],
            "settings": []
        };
        const block = source.match(/\/\/\s*==QuarryScript==([\s\S]*?)\/\/\s*==\/QuarryScript==/);
        if (!block)
            return meta;
        for (const line of block[1].split("\n")) {
            const m = line.match(/^\s*\/\/\s*@(\w[\w-]*)\s+(.*)$/);
            if (!m)
                continue;
            const key = m[1].toLowerCase();
            const value = m[2].trim();
            if (key === "grant")
                meta.grants = meta.grants.concat(value.split(/[,\s]+/).filter(g => g.length > 0));
            else if (key === "setting")
                meta.settings = meta.settings.concat(root._setting(value));
            else if (key === "match")
                meta.match = value;
            else if (meta[key] !== undefined)
                meta[key] = value;
        }
        if (meta.name.length === 0)
            meta.name = meta.id;
        return meta;
    }

    /*
     * THE OBJECT A SCRIPT IS HANDED, BUILT FROM ITS OWN GRANTS.
     *
     * Everything a script can do is here, and nothing it did not ask for is.
     * `on` and `log` are always given: a script with no grants can still
     * listen and say what it is doing, which is what makes the first five
     * minutes of writing one bearable.
     */
    function _api(meta) {
        const id = meta.id;
        const grants = meta.grants;
        const has = g => grants.indexOf(g) >= 0 || grants.indexOf("*") >= 0;
        const api = {
            "id": id,
            "version": meta.version,
            "log": function (...args) {
                console.info(`[script ${id}]`, args.map(a => String(a)).join(" "));
            },
            "on": function (event, fn) {
                if (typeof fn !== "function")
                    return;
                if (event === "rows") {
                    if (!has("rows")) {
                        root._blame(id, "rows needs `@grant rows`");
                        return;
                    }
                    root._rowHooks = root._rowHooks.concat([{
                        "id": id,
                        "match": meta.match,
                        "fn": fn
                    }]);
                    return;
                }
                const next = Object.assign({}, root._eventHooks);
                next[event] = (next[event] || []).concat([{
                    "id": id,
                    "fn": fn
                }]);
                root._eventHooks = next;
            }
        };
        if (has("menu"))
            api.menu = function (label, fn, icon) {
                if (typeof fn !== "function")
                    return;
                root._menuItems = root._menuItems.concat([{
                    "id": id,
                    "label": String(label),
                    "icon": String(icon || "code"),
                    "fn": fn
                }]);
            };
        if (has("keys"))
            api.key = function (name, fn) {
                if (typeof fn !== "function")
                    return;
                const next = Object.assign({}, root._keyBinds);
                const k = String(name);
                next[k] = (next[k] || []).concat([{
                    "id": id,
                    "fn": fn
                }]);
                root._keyBinds = next;
            };
        if (has("storage")) {
            api.storage = {
                "get": function (key, fallback) {
                    const mine = root._store[id] || ({});
                    return mine[key] === undefined ? fallback : mine[key];
                },
                "set": function (key, value) {
                    const all = Object.assign({}, root._store);
                    all[id] = Object.assign({}, all[id] || ({}));
                    all[id][key] = value;
                    root._store = all;
                    Prefs.scriptStore = all;
                }
            };
        }
        if (has("toast"))
            api.toast = function (text) {
                Toast.show(String(text).slice(0, 200));
            };
        if (has("clipboard"))
            api.copy = function (text) {
                Sys.copyText(String(text));
            };
        if (has("open"))
            api.open = function (url) {
                Sys.open(String(url));
            };
        if (has("view")) {
            /*
             * DRIVING THE VIEW — what autoscroll and autoplay need and
             * nothing else has.
             *
             * Three verbs, because three is what the scripts people actually
             * write need: move the wall, step the open picture, and ask
             * whether a picture is open at all. A script cannot reach the
             * view object itself — it says what it wants done, and quarry
             * does it to whichever view is on screen.
             */
            api.scroll = function (pixelsPerSecond) {
                // A new scroll is not still waiting at the last one's end.
                root._endTicks = 0;
                root._endShape = "";
                root.scrollSpeed = Number(pixelsPerSecond) || 0;
                // Chrome hidden for a read is chrome back when the read ends,
                // whoever stopped it. Nothing else clears this.
                if (root.scrollSpeed === 0 && Host.chromeSuppressed)
                    Host.chromeSuppressed = false;
            };
            /*
             * JUST THE PICTURES.
             *
             * The search bar and the rail are neither pictures nor anything you
             * touch while the wall reads itself. `Host.chromeSuppressed` has
             * been the channel for this since the extension API landed and had
             * no caller and no reader; this is the caller.
             */
            api.chrome = function (visible) {
                Host.chromeSuppressed = visible === false;
            };
            /// What autoscroll would move right now — for a script that wants
            /// to say so, and for `app script` to report.
            api.scrollableHeight = function () {
                const view = root.scrollable();
                return view ? Math.round(view.contentHeight) : 0;
            };
            /*
             * THE VIEWER THAT IS ACTUALLY OPEN — the gallery's, or a lens's.
             *
             * These knew only `Shell.detail`, so a slideshow stopped dead the
             * moment you opened a picture inside Morse or 4chan: `viewerOpen`
             * answered false and autoplay switched itself off, which reads as
             * the script being broken rather than as it not knowing where it
             * was. A lens that has its own viewer holds `viewing` and answers
             * `viewerStep` — both do, and a lens that does neither is simply
             * not somewhere a slideshow can run.
             */
            api.step = function (delta) {
                const by = Number(delta) || 1;
                if (Shell.detail && Shell.detail.open) {
                    Shell.detail.step(by);
                    return;
                }
                const lens = Lenses.activeLens;
                if (lens && lens.viewing && typeof lens.viewerStep === "function")
                    lens.viewerStep(by);
            };
            /// What the open viewer shows: { id, video, position, duration } in seconds.
            /// A lens viewer reports id only (video: false) unless it says more.
            api.viewerVideo = function () {
                if (Shell.detail && Shell.detail.open && typeof Shell.detail.videoState === "function")
                    return Shell.detail.videoState();
                const lens = Lenses.activeLens;
                if (lens && typeof lens.viewerVideo === "function")
                    return lens.viewerVideo();
                const v = lens ? lens.viewing : null;
                return { "id": v ? String(v.id || v.name || JSON.stringify(v).slice(0, 40)) : "", "video": false, "position": 0, "duration": 0 };
            };
            /// A slideshow says it runs, so the viewer stops looping videos and reports their end.
            api.slideshow = function (on) {
                root.slideshowRunning = !!on;
            };
            api.viewerOpen = function () {
                if (Shell.detail && Shell.detail.open)
                    return true;
                const lens = Lenses.activeLens;
                return !!(lens && lens.viewing);
            };
            /// Centre the next (1) or previous (-1) video; false when none was near.
            api.jumpVideo = function (dir) {
                return root.jumpVideo(Number(dir) < 0 ? -1 : 1);
            };
            /// Sound for autoplaying videos: the hovered one, else the one nearest the middle.
            api.toggleSound = function () {
                Prefs.hoverSound = !Prefs.hoverSound;
                return Prefs.hoverSound;
            };
        }
        if (has("play")) {
            /// Autoplay's switches, as one object: on, all (in view), sound, hold, centre.
            api.autoplay = function () {
                return root.autoplayState();
            };
            /// Set one of them by that name; returns the new state.
            api.setAutoplay = function (key, value) {
                const on = !!value;
                switch (String(key)) {
                case "on": Prefs.autoplayInView = on; break;
                case "all": Prefs.autoplaySlots = on ? 0 : 3; break;
                case "sound": Prefs.hoverSound = on; break;
                case "hold": Prefs.dwellOnVideo = on; break;
                case "centre": Prefs.snapToVideo = on; break;
                case "slots": Prefs.autoplaySlots = Math.max(0, Math.round(Number(value) || 0)); break;
                case "threshold": Prefs.autoplayThreshold = Math.max(1, Math.min(100, Math.round(Number(value) || 60))); break;
                case "watch":
                    if (["full", "percent", "fixed"].indexOf(String(value)) < 0)
                        throw new Error(`setAutoplay: watch must be full, percent or fixed`);
                    Prefs.dwellMode = String(value);
                    break;
                case "seconds": Prefs.dwellSeconds = Math.max(1, Math.round(Number(value) || 5)); break;
                case "percent": Prefs.dwellPercent = Math.max(1, Math.min(100, Math.round(Number(value) || 80))); break;
                case "longest": Prefs.dwellMaxSeconds = Math.max(1, Math.round(Number(value) || 30)); break;
                default: throw new Error(`setAutoplay: unknown "${key}"`);
                }
                return root.autoplayState();
            };
        }
        if (has("dock")) {
            /*
             * THE SCRIPT DESCRIBES ITS CONTROLS; QUARRY DRAWS THEM.
             *
             * A declaration, not a widget tree — the script says "a toggle
             * called Scrolling and a slider called Speed", and what appears is
             * quarry's own buttons in quarry's own theme, which is both why it
             * looks like the rest of the app and why a script cannot reach the
             * window through it.
             *
             * Items: { id, kind: button|toggle|label|slider, label, icon,
             * value, min, max, step, on }. `on` is called with the new value.
             */
            api.dock = function (spec) {
                const s = spec || ({});
                const items = (s.items || []).map(function (item, index) {
                    return {
                        "id": String(item.id || `item${index}`),
                        "kind": String(item.kind || "button"),
                        "label": String(item.label || ""),
                        "icon": String(item.icon || ""),
                        "value": item.value,
                        "min": item.min !== undefined ? Number(item.min) : 0,
                        "max": item.max !== undefined ? Number(item.max) : 100,
                        "step": item.step !== undefined ? Number(item.step) : 1,
                        /*
                         * Whether this control also belongs in the ⋮ menu, and
                         * what it is called there. A dock says "Scroll" beside
                         * a title that says "Autoscroll"; a menu row has no
                         * title over it and has to say the whole thing.
                         *
                         * Unset means: toggles and sliders yes, buttons no — a
                         * menu is for deciding, and ‹ › are for doing.
                         */
                        "menu": item.menu,
                        "on": typeof item.on === "function" ? item.on : null
                    };
                });
                root._docks = root._docks.filter(d => d.id !== id).concat([{
                    "id": id,
                    "name": meta.name,
                    "match": meta.match,
                    "title": String(s.title || meta.name),
                    "icon": String(s.icon || "widgets"),
                    /*
                     * DOES THIS DOCK STILL MEAN ANYTHING OVER AN OPEN PICTURE?
                     *
                     * Autoscroll's controls drive the WALL. With a picture open
                     * the wall is not on screen, so the dock was a strip of
                     * buttons floating over the photograph, controlling
                     * something invisible — which reads as the viewer failing
                     * to cover the window.
                     *
                     * Autoplay's controls are the opposite: they are about the
                     * thing you are looking at, and hiding them there would be
                     * the mistake. So the script says which it is, and the
                     * default is "no" because most controls are about the wall.
                     */
                    "overViewer": s.overViewer === true,
                    "items": items
                }]);
                root.revision++;
                root.changed();
            };
            /// Change one control without redeclaring the dock — the way a
            /// script says "now it is running" or "now it is 130 px/s".
            api.dockSet = function (itemId, patch) {
                const dock = root._docks.find(d => d.id === id);
                if (!dock)
                    return;
                const item = dock.items.find(i => i.id === String(itemId));
                if (!item)
                    return;
                for (const key in (patch || ({}))) item[key] = patch[key]
                root.revision++;
                root.changed();
            };
        }
        if (has("query"))
            api.query = function (text) {
                Catalog.query = String(text);
            };
        if (has("keep"))
            /*
             * "KEEP EVERY PICTURE IN THIS THREAD" — the single most-installed
             * shape of script on the adult script sites is a gallery
             * downloader, and this is what it needs. It goes through the
             * catalogue's own `keep`, so a script cannot write files anywhere
             * a person did not already choose.
             */
            api.keep = function (item, collection) {
                if (!item)
                    return;
                Catalog.keep(item, String(collection || "Kept"), true);
            };
        if (has("timer"))
            /*
             * A REPEATING TASK, WITH A FLOOR.
             *
             * Watchers, auto-refreshers and slideshows need one. A second is
             * the shortest allowed: a script asking for 50ms has
             * misunderstood, and the cost lands on somebody else's daemon —
             * but an eight-second slideshow is a perfectly ordinary thing to
             * want, and a five-second floor could not express it.
             * Every timer a script makes is destroyed on reload — see
             * `_clear` — so editing a file cannot leave one running.
             */
            api.every = function (seconds, fn) {
                if (typeof fn !== "function")
                    return;
                const ms = Math.max(1, Number(seconds) || 5) * 1000;
                const timer = Qt.createQmlObject(`import QtQuick
Timer {
    interval: ${ms}
    repeat: true
    running: true
}`, root, `${id}-timer`);
                timer.triggered.connect(function () {
                    try {
                        fn();
                    } catch (e) {
                        root._blame(id, `every(${seconds}s): ${e}`);
                    }
                });
                root._timers = root._timers.concat([timer]);
            };
        /*
         * THERE IS NO `fetch` GRANT, DELIBERATELY.
         *
         * Every userscript host has one and it is the first thing anybody
         * asks for. It is not here because the daemon has no general "fetch
         * this URL" method, and adding one for scripts would put a hole in
         * the three things that keep quarry welcome on the sites it reads:
         * the per-host rate limiter, the cache, and the honest User-Agent.
         * A script that wants rows asks the catalogue for them (`query`),
         * which goes through all three.
         *
         * If this ever arrives it should be `@grant fetch` plus a declared
         * host list in the header — Tampermonkey's `@connect` — and the
         * daemon doing the fetching under its own rules.
         */
        return api;
    }

    function _run(path, source) {
        const meta = root._header(source, path);
        const entry = {
            "id": meta.id,
            "name": meta.name,
            "version": meta.version,
            "description": meta.description,
            "author": meta.author,
            "match": meta.match,
            "grants": meta.grants,
            // Carried through, or `settingsFor` finds nothing and a script's
            // declared options never reach the settings screen.
            "settings": meta.settings,
            "path": path,
            "enabled": !root._disabled[meta.id],
            "error": ""
        };
        if (!entry.enabled) {
            root.scripts = root.scripts.concat([entry]);
            return;
        }
        /*
         * The wrapper. `quarry` is the name the script sees, because a script
         * reads better as `quarry.on(…)` than as `api.on(…)` — and because
         * every userscript ever written names its host.
         */
        const wrapper = `import QtQuick
QtObject {
    function run(quarry) {
${source}
    }
}`;
        try {
            const obj = Qt.createQmlObject(wrapper, root, path);
            obj.run(root._api(meta));
        } catch (e) {
            entry.error = String(e).replace(/^.*?:\d+:\d+:\s*/, "").slice(0, 300);
        }
        root.scripts = root.scripts.concat([entry]);
        root.revision++;
        root.changed();
    }

    // ── the folder, and watching it ──────────────────────────────────────────
    property Process _lister: Process {
        id: lister
        command: ["sh", "-c", `mkdir -p '${root.dir}' && ls -1 '${root.dir}'/*.js 2>/dev/null || true`]

        stdout: StdioCollector {
            onStreamFinished: {
                const paths = String(this.text || "").split("\n").map(p => p.trim()).filter(p => p.length > 0);
                if (paths.length === 0) {
                    root.revision++;
                    root.changed();
                    root._loadDone();
                    return;
                }
                reader.queue = paths;
                reader.next();
            }
        }
    }

    /*
     * Read one at a time rather than one Process each: a folder of thirty
     * scripts would otherwise be thirty shells at once, and the order they
     * load in decides the order their row hooks run.
     */
    property Process _reader: Process {
        id: reader

        property var queue: []
        property string current: ""

        function next() {
            if (reader.queue.length === 0) {
                root._loadDone();
                return;
            }
            reader.current = reader.queue.shift();
            reader.command = ["cat", reader.current];
            reader.running = true;
        }

        stdout: StdioCollector {
            onStreamFinished: {
                const source = String(this.text || "");
                if (source.trim().length > 0)
                    root._run(reader.current, source);
                reader.next();
            }
        }
    }

    /*
     * Hot reload, the way a userscript manager does it: save the file, see the
     * change. Polled rather than watched because the folder may not exist yet
     * and a watch on a missing directory is a watch that never fires.
     */
    property Timer _watch: Timer {
        interval: 2000
        repeat: true
        running: Prefs.scriptsEnabled
        onTriggered: stamp.running = true
    }

    property Process _stamp: Process {
        id: stamp
        command: ["sh", "-c", `ls -l --time-style=+%s '${root.dir}'/*.js 2>/dev/null | md5sum || true`]

        property string last: ""

        stdout: StdioCollector {
            onStreamFinished: {
                const now = String(this.text || "").trim();
                if (stamp.last.length > 0 && now !== stamp.last) {
                    root.reload();
                    Toast.show("Scripts reloaded");
                }
                stamp.last = now;
            }
        }
    }

    /*
     * THE STORED SETTINGS ARRIVE AFTER WE ASK FOR THEM.
     *
     * `Prefs` is a FileView, which loads asynchronously — its own code says so
     * ("not at startup, when the adapter still holds nothing but defaults").
     * Scripts read the store in `Component.onCompleted`, before that, so every
     * `@setting` anybody had changed was read as its default and thrown away on
     * every single start. Measured with autoscroll's `speed` 120 and `up` true
     * on disk: it started at 60, downward. The settings only ever took effect
     * if something reloaded the scripts later.
     *
     * So the store is taken when it actually turns up, and the scripts are read
     * again with it. Compared by value, not identity: `storage.set` assigns the
     * same object here and into Prefs, and reloading on our own write would be
     * a loop.
     */
    Connections {
        target: Prefs

        function onScriptStoreChanged() {
            const next = Prefs.scriptStore || ({});
            if (JSON.stringify(next) === JSON.stringify(root._store))
                return;
            root._store = next;
            if (Prefs.scriptsEnabled)
                root.reload();
        }
    }

    Component.onCompleted: {
        root._store = Prefs.scriptStore || ({});
        if (Prefs.scriptsEnabled)
            root.reload();
    }
}
