pragma Singleton
import QtQuick
import qs.modules.common
import QtQuick.Window
import Quickshell
import Quickshell.Io

/*
 * The catalog, Phase 1 edition.
 *
 * Measured first, designed second: holding a whole catalog as JavaScript
 * objects costs about 6.8 KB an item in this engine — 137k items took the
 * process from 33 MB to 965 MB with image loading switched off entirely, so it
 * was the records, not the pixmaps. That number is why nothing here ever
 * materialises the catalog.
 *
 * Instead:
 *
 *   · `ratios` — one number per item, the only thing masonry needs to lay a
 *     tile out. 137k of those is about 1 MB, and the daemon can stream them in
 *     bulk for pennies.
 *   · `itemAt(i)` — the full record, materialised on demand and cached by page,
 *     with old pages evicted. Only what is on screen (plus a little) is ever
 *     resident.
 *
 * Phase 0 read a JSON fixture directly; the shape below is what the daemon will
 * answer over the socket in Phase 2, so the views never learn the difference.
 */
QtObject {
    id: root

    // ── the source: the daemon when it is up, the fixture when it is not ────
    property var _base: []            // fixture records, only used offline
    property bool loading: true
    property string error: ""

    readonly property bool live: Client.connected && root._queryId > 0
    readonly property string backend: Client.connected ? Client.backend : "fixture"
    property int _queryId: 0
    property var _pendingPages: ({})

    // What the daemon made of the last query: the sort it applied, and any keys
    // it did not recognise. A query that quietly matches everything is worse
    // than one that says it did not understand.
    property string sort: "relevance"
    property var unknownKeys: []

    /*
     * THE CATALOGUE ITSELF IS BROKEN, IN THE DAEMON'S OWN WORDS.
     *
     * Empty because there is nothing, and empty because the file could not be
     * read, looked exactly alike here: a damaged search index answered every
     * word with zero rows and the wall drew its ordinary "nothing matched" over
     * fifteen thousand pictures. The daemon now says which it is, and this is
     * where the app keeps that so a strip can say it out loud.
     */
    property string damaged: ""

    /// Why the copy of your boards and collections is not being written, if it
    /// is not. That file is the only one of its kind: the catalogue re-crawls,
    /// and this does not.
    property string userDataError: ""

    // ── the query ────────────────────────────────────────────────────────────
    property string query: ""

    /*
     * THE QUERY TEXT IS THE ONLY FILTER STATE.
     *
     * These were three separate properties that the filter panel wrote and the
     * daemon received alongside the text — so choosing a source left the search
     * bar empty and put a chip underneath it instead. Two places holding the
     * same idea, and the one you were looking at was the one that said nothing.
     *
     * They are read off the query now. Picking `pfps.gg` in the panel types
     * `source:pfps.gg` into the bar, which is a thing you can see, edit and
     * delete with backspace — and the chip row it replaced was a second way to
     * say what the bar was already for.
     */
    readonly property string kind: root.filterValue("kind")
    readonly property string source: root.filterValue("source")
    readonly property string family: root.filterValue("family")

    /// The value of a `key:value` token in the query, or "".
    function filterValue(key) {
        // Word-boundary at the front so `source:` does not match `insource:`.
        const found = root.query.match(new RegExp("(?:^|\\s)" + key + ":([^\\s]+)"));
        return found ? found[1] : "";
    }

    /// Set, replace or remove one `key:value` token, leaving the rest of what
    /// was typed exactly as it was.
    function setFilter(key, value) {
        const without = root.query
            .replace(new RegExp("(?:^|\\s)" + key + ":[^\\s]+", "g"), " ")
            .replace(/\s+/g, " ")
            .trim();
        root.query = value && value.length > 0
            ? (without.length > 0 ? `${without} ${key}:${value}` : `${key}:${value}`)
            : without;
    }

    // ── the result: a count, a ratio per item, and pages on demand ───────────
    property int count: 0
    property var ratios: []
    property var _index: []           // result index -> base index

    // How many items may be resident at once, as whole pages.
    readonly property int pageSize: 500
    readonly property int maxPages: 8
    property var _pages: ({})
    property var _pageOrder: []
    property int pagesResident: 0
    property int pagesEvicted: 0
    property int pageLoads: 0

    /*
     * Lookup counter kept in plain JS, deliberately.
     *
     * `itemAt` is called from delegate code on every recycle; making its
     * counter a QML property meant every call notified, and the resulting
     * invalidation storm took the sweep from 5 ms average frames to 131 ms with
     * a 1053 ms worst frame. Anything on this path stays out of the property
     * system.
     */
    property var _stats: ({
            "lookups": 0
        })

    // Scale factor for the perf harness: the same fixture pretending to be a
    // catalog of `repeat × base` items. No records are created by this.
    property int repeat: 1

    readonly property var kinds: root._distinct("kind")
    readonly property var sources: root._distinct("source")

    /*
     * Facets with counts, from the daemon.
     *
     * The filter panel needs to know what is worth filtering by and how much is
     * behind each choice; the daemon tallies that over the whole catalogue,
     * which the client cannot do without holding every record.
     */
    property var facetKinds: []
    property var facetSources: []
    /// Per source: [{ source, group, label, q }] — what each site says it is
    /// made of. See `refreshFacets`.
    property var facetSections: []

    /*
     * How many rows the daemon hid on its own, and could give back.
     *
     * Not rows anybody chose to hide — those are a different reason and are
     * never counted here. A thumbnail that would not fetch used to hide its
     * row permanently whatever the cause, including a host that was merely
     * busy, so most catalogues have a few thousand of these.
     */
    property int autoHiddenCount: 0

    /*
     * WHAT EACH SOURCE IS SET TO.
     *
     * Separate from `facetSources`, which is what the catalogue HOLDS: a
     * source you have switched off still has rows and still belongs in the
     * filter, it just stops being crawled. Two different questions, two lists.
     */
    property var sourcePrefs: []
    /*
     * THE SAME THING, KEYED BY ID.
     *
     * A settings row cannot bind to "the entry for my source" in an array
     * without searching it, and searching an array inside a delegate binding is
     * how a list of twenty-nine rows becomes 841 comparisons on every change.
     * More importantly it lets the ROWS survive a refresh: the Repeater keeps
     * its model (a list of ids that only changes when a source appears), and
     * only the values inside each live delegate change — which is the
     * difference between a switch that animates and a switch that is destroyed
     * and rebuilt already flipped.
     */
    property var sourcePrefMap: ({})
    property string blend: "round-robin"
    property int mixSeed: 0

    /*
     * THE ADULT SWITCH IS A DAEMON SETTING, NOT A QUERY.
     *
     * It used to be expressed by appending `-nsfw` to the query string — a
     * predicate in a box the user can edit, which any later `Catalog.query = …`
     * dropped. Turning it off hid what was on screen and the next tag, lens or
     * history entry brought it straight back out of the LOCAL catalogue.
     *
     * The daemon holds it now and applies it to every answer, so this only has to
     * tell it. `Prefs.showNsfw` is still set because the UI reads it for blur,
     * locked source rows and the lens gate — but it is a mirror of the daemon's
     * answer, never the thing doing the work.
     */
    function setAdult(on) {
        Prefs.showNsfw = on;
        if (!on)
            Prefs.blurNsfw = true;

        if (!Client.connected) {
            Toast.error("quarryd is not running — this will apply when it is");
            return;
        }
        Client.call("setSourcePrefs", { "adult": !!on }, function (err, payload) {
            if (err) {
                Toast.error("Could not save — " + String(err));
                return;
            }
            // Believe the daemon, not the switch: it is the one enforcing this.
            Prefs.showNsfw = payload && payload.adult === true;
            root.reload();
            root.refreshSourcePrefs();
        });
    }

    /*
     * THROW THE RESULT AWAY AND ASK AGAIN.
     *
     * Not `filterNow()`, which is a REFRESH: the query text has not changed, so
     * it keeps the pages already on screen and re-requests them, which is right
     * while a crawl is filling the same result underneath. It is wrong when the
     * result itself has been redefined — the adult switch changes which rows
     * exist, so every offset now names a different picture and the held pages
     * are pictures from the old wall.
     *
     * This was `root.refresh()`, WHICH NEVER EXISTED. Calling it threw a
     * TypeError inside the `setSourcePrefs` reply handler, which aborted the
     * rest of the handler — so the daemon was told, and correctly stopped
     * answering with adult rows, while the window kept the result it already
     * had and went on showing them. Turning the switch off looked like it did
     * nothing at all, and `refreshSourcePrefs()` on the next line never ran
     * either. Nothing was logged where anyone would look.
     */
    function reload() {
        root._dropPages();
        root._pagedQuery = "";      // so the next answer cannot be called "the same query"
        root.filterNow();
    }

    function refreshSourcePrefs() {
        if (!Client.connected)
            return;
        Client.call("sourcePrefs", {}, function (err, payload) {
            if (err || !payload)
                return;
            root.sourcePrefs = payload.sources || [];
            root.blend = payload.blend || "round-robin";
            root.mixSeed = payload.seed || 0;
            root._remapPrefs();
        });
    }

    function _remapPrefs() {
        const map = {};
        for (let i = 0; i < root.sourcePrefs.length; i++)
            map[root.sourcePrefs[i].id] = root.sourcePrefs[i];
        root.sourcePrefMap = map;
    }

    /// Change one source's settings, or the blend, and read the truth back.
    function setSourcePref(params) {
        if (!Client.connected) {
            Toast.error("Can't save — start quarryd first");
            return;
        }
        /*
         * Show it immediately, then confirm.
         *
         * The daemon round trip is a few milliseconds, but a control that waits
         * for it is a control that does not answer the press — and the switch's
         * whole job is to answer the press. If the write fails the refresh puts
         * the real value back and the toast says why.
         */
        if (params.id && root.sourcePrefMap[params.id]) {
            const patched = {};
            const before = root.sourcePrefMap[params.id];
            for (const key in before)
                patched[key] = before[key];
            for (const key in params)
                if (key !== "id")
                    patched[key] = params[key];
            const map = {};
            for (const key in root.sourcePrefMap)
                map[key] = root.sourcePrefMap[key];
            map[params.id] = patched;
            root.sourcePrefMap = map;
        }

        Client.call("setSourcePrefs", params, function (err) {
            if (err) {
                Toast.error("Could not save — " + String(err));
                root.refreshSourcePrefs();
                return;
            }
            root.refreshSourcePrefs();
        });
    }

    // ── boards ──────────────────────────────────────────────────────────────

    property var boards: []
    /// Which board is on the canvas. Empty until one is opened, so nothing is
    /// written to a board nobody has chosen.
    property string board: ""
    property var boardItems: []
    /*
     * THE SAME PLACEMENTS, KEYED BY ID.
     *
     * A Repeater fed a new JS array rebuilds every delegate — so refreshing the
     * board after a drop destroyed and recreated every picture on it, and they
     * all visibly reloaded. The canvas keeps a stable list of ids as its model
     * and reads geometry through here, so a refresh changes VALUES on pieces
     * that are already on screen instead of replacing them.
     */
    property var boardItemMap: ({})
    property var boardContainers: []
    /// Keyed, for the same reason `boardItemMap` is: a Repeater handed a new
    /// array rebuilds every delegate.
    property var boardContainerMap: ({})

    /// The one place containers are assigned, so the map can never fall out of
    /// step with the list — there are three call sites and the third would have
    /// forgotten.
    function _setContainers(list) {
        root.boardContainers = list;
        const boxes = {};
        for (let i = 0; i < list.length; i++)
            boxes[list[i].id] = list[i];
        root.boardContainerMap = boxes;
    }

    signal boardChanged_

    function refreshBoards() {
        if (!Client.connected)
            return;
        Client.call("boards", { "action": "list" }, function (err, payload) {
            if (err || !payload)
                return;
            root.boards = payload.boards || [];
        });
    }

    function openBoard(name) {
        root.board = name;
        root.refreshBoardItems();
    }

    /// Make a board and open it. Naming one before you have anything to put on
    /// it is the normal way to start, so it must not require placing something.
    function createBoard(name) {
        if (!Client.connected || name.length === 0)
            return;
        Client.call("boards", { "action": "create", "name": name }, function (err, payload) {
            if (err) {
                Toast.error("Could not make the board — " + String(err));
                return;
            }
            root.boards = (payload && payload.boards) || [];
            root.openBoard(name);
        });
    }

    function refreshBoardItems() {
        if (!Client.connected || root.board.length === 0) {
            root.boardItems = [];
            return;
        }
        Client.call("boards", { "action": "items", "name": root.board }, function (err, payload) {
            if (err || !payload)
                return;
            root.boardItems = payload.items || [];
            const map = {};
            for (let i = 0; i < root.boardItems.length; i++)
                map[root.boardItems[i].id] = root.boardItems[i];
            root.boardItemMap = map;
            root._setContainers(payload.containers || []);
            root.fetchBoardRecords();
            root.boardChanged_();
        });
    }

    /*
     * Write one piece's geometry.
     *
     * Deliberately fire-and-forget and NOT followed by a refresh: this is
     * called on every drop of a drag, and re-reading the board after each one
     * would replace the objects being dragged with fresh copies mid-gesture.
     * The canvas is the authority while it is open; the daemon is the record.
     */
    function placeOnBoard(item, geom) {
        if (!Client.connected || root.board.length === 0)
            return;
        Client.call("boards", {
            "action": "place",
            "name": root.board,
            "id": item,
            "x": geom.x,
            "y": geom.y,
            "w": geom.w,
            "h": geom.h,
            "angle": geom.angle || 0,
            "hflip": geom.hflip === true,
            "vflip": geom.vflip === true,
            "z": geom.z || 0,
            "sharp": geom.sharp === true,
            "container": geom.container || 0
        }, function (err) {
            if (err) {
                Toast.error("Could not save the board — " + String(err));
                return;
            }
            // The strip shows a count per board; without this it keeps
            // reporting whatever it read when the panel was last opened.
            boardCount.restart();
        });
    }

    property Timer _boardCount: Timer {
        id: boardCount
        // Coalesced: dropping six pictures on a board in a row should cost one
        // list, not six.
        interval: 300
        onTriggered: root.refreshBoards()
    }

    /*
     * Put a picture on a board WITHOUT opening it.
     *
     * quarry proper has no canvas any more — the board is its own application —
     * so "add to a board" here is a write and a sentence, not a navigation. The
     * board app is watching the same daemon and picks it up.
     */
    function placeOnBoardNamed(name, item) {
        if (!Client.connected || !item) {
            Toast.error("Can't add — start quarryd first");
            return;
        }
        const ratio = (item.w > 0 && item.h > 0) ? item.h / item.w : 0.75;
        const w = 460;
        Client.call("boards", {
            "action": "place",
            "name": name,
            "id": item.id,
            // Fanned out from the origin rather than stacked exactly, since
            // nothing here knows where the board's other pictures already are.
            "x": (Math.random() * 900) - 450,
            "y": (Math.random() * 600) - 300,
            "w": w,
            "h": w * ratio,
            "z": 0
        }, function (err) {
            if (err) {
                Toast.error("Could not add — " + String(err));
                return;
            }
            boardCount.restart();
            Toast.show(`Added to “${name}” — open the board to arrange it`);
        });
    }

    /*
     * Take a local file into the catalogue and hand back the row.
     *
     * The board's drop target uses this: a dropped picture becomes an ordinary
     * `file://` row, so it gets a thumbnail and a phash and can be searched for
     * afterwards — rather than existing only as geometry on one board.
     */
    function adoptFile(url, onDone) {
        if (!Client.connected) {
            Toast.error("Can't add — start quarryd first");
            return;
        }
        Client.call("adopt", { "path": String(url) }, function (err, payload) {
            if (err || !payload || !payload.item) {
                Toast.error("Could not read that file — " + String(err || "no item"));
                return;
            }
            // Cached like any other board record, so the canvas can draw it
            // before the next refresh brings it round.
            const next = {};
            for (const key in root.boardRecords)
                next[key] = root.boardRecords[key];
            next[payload.item.id] = payload.item;
            root.boardRecords = next;
            if (onDone)
                onDone(payload.item);
        });
    }

    /// Make or move a container. `id` 0 makes a new one.
    function placeContainer(spec) {
        if (!Client.connected || root.board.length === 0)
            return;
        Client.call("boards", {
            "action": "container",
            "name": root.board,
            "container": spec.id || 0,
            "x": spec.x,
            "y": spec.y,
            "w": spec.w,
            "h": spec.h,
            "label": spec.label || ""
        }, function (err, payload) {
            if (err) {
                Toast.error("Could not save the container — " + String(err));
                return;
            }
            root._setContainers((payload && payload.containers) || []);
            if (spec.onMade)
                spec.onMade(payload ? payload.container : 0);
        });
    }

    /// Remove a container. Its pictures stay on the board, set loose.
    function deleteContainer(id) {
        if (!Client.connected || root.board.length === 0)
            return;
        Client.call("boards", { "action": "uncontain", "name": root.board, "container": id },
            function (err, payload) {
                if (err) {
                    Toast.error("Could not remove it — " + String(err));
                    return;
                }
                root._setContainers((payload && payload.containers) || []);
                root.refreshBoardItems();
            });
    }

    function removeFromBoard(item) {
        if (!Client.connected || root.board.length === 0)
            return;
        Client.call("boards", { "action": "remove", "name": root.board, "id": item }, function (err) {
            if (err) {
                Toast.error("Could not save the board — " + String(err));
                return;
            }
            boardCount.restart();
        });
    }

    function saveBoardView(x, y, z) {
        if (!Client.connected || root.board.length === 0)
            return;
        Client.call("boards", { "action": "view", "name": root.board, "x": x, "y": y, "z": z }, function () {});
    }

    function renameBoard(from, to) {
        if (!Client.connected || to.trim().length === 0 || from === to)
            return;
        Client.call("boards", { "action": "rename", "name": from, "to": to.trim() }, function (err, payload) {
            if (err) {
                Toast.error("Could not rename — " + String(err));
                return;
            }
            root.boards = (payload && payload.boards) || [];
            // Follow it: the board you were looking at is the board you renamed,
            // and being dropped back to the chooser for it would be absurd.
            if (root.board === from)
                root.openBoard(to.trim());
        });
    }

    function deleteBoard(name) {
        if (!Client.connected)
            return;
        Client.call("boards", { "action": "delete", "name": name }, function (err, payload) {
            if (err) {
                Toast.error("Could not delete — " + String(err));
                return;
            }
            root.boards = (payload && payload.boards) || [];
            if (root.board === name) {
                root.board = "";
                root.boardItems = [];
            }
        });
    }

    /*
     * THE RECORDS A BOARD NEEDS, FETCHED ONCE.
     *
     * The board stores ids, and a board can hold pictures the current query
     * does not — which is the entire point of keeping one. `itemById` only
     * searches resident pages, so it answers null for exactly the rows a board
     * is most likely to hold, and the canvas would draw empty frames.
     *
     * So anything not already resident is asked for by id and cached here for
     * the life of the process. One request per picture, once.
     */
    property var boardRecords: ({})

    function boardRecord(id) {
        const resident = root.itemById(id);
        if (resident)
            return resident;
        return root.boardRecords[id] || null;
    }

    function fetchBoardRecords() {
        if (!Client.connected)
            return;
        for (let i = 0; i < root.boardItems.length; i++) {
            const id = root.boardItems[i].id;
            if (root.itemById(id) || root.boardRecords[id])
                continue;
            root._fetchBoardRecord(id);
        }
    }

    /*
     * THE RECORD BEHIND AN ID, WHEREVER IT IS NEEDED.
     *
     * A board holds ids; so does history. Both want the picture, neither has
     * it, and the daemon answers `item` for one id at a time. This is the
     * cache both share: ask for an id and get the record if it is here, and
     * a single request started for it if it is not.
     *
     * Named for what it does rather than for the board, because it was the
     * board's private helper and history needed exactly the same thing —
     * the second caller is where a private helper either becomes shared or
     * becomes two copies.
     */
    function recordFor(id) {
        const key = String(id || "");
        if (key.length === 0)
            return null;
        const held = root.boardRecords[key];
        if (held !== undefined)
            return held;
        root._fetchBoardRecord(key);
        return null;
    }

    function _fetchBoardRecord(id) {
        // Marked before the round trip, so a board holding the same picture
        // twice does not ask for it twice.
        const pending = root.boardRecords;
        pending[id] = null;
        Client.call("item", { "id": id }, function (err, payload) {
            if (err || !payload || !payload.item)
                return;
            const next = {};
            for (const key in root.boardRecords)
                next[key] = root.boardRecords[key];
            next[id] = payload.item;
            root.boardRecords = next;
        });
    }

    function refreshHidden() {
        if (!Client.connected)
            return;
        Client.call("stats", {}, function (err, payload) {
            if (err || !payload)
                return;
            let auto = 0;
            for (const row of (payload.hidden || []))
                if (row.reason === "fetch" || row.reason === "legacy")
                    auto += row.items;
            root.autoHiddenCount = auto;
        });
    }

    /// Forget those decisions. The pictures return as their sources are
    /// crawled again — the rows themselves were deleted when they were hidden,
    /// so there is nothing to un-delete, only a refusal to lift.
    function restoreHidden() {
        if (!Client.connected) {
            Toast.error("Can't restore — start quarryd first");
            return;
        }
        Client.call("restore", { "scope": "auto" }, function (err, payload) {
            if (err || !payload) {
                Toast.error("Restore failed — " + String(err));
                return;
            }
            root.autoHiddenCount = 0;
            Toast.show(payload.restored > 0
                ? `${payload.restored} pictures un-hidden — they return as their sources are crawled`
                : "Nothing was hidden by mistake");
            root.reload();
        });
    }
    property var facetFamilies: []
    // What each source says people come looking for — its own categories.
    property var suggestions: []

    /// Why the facets are empty, when they are. An empty filter panel and a
    /// filter panel that never got its data look identical on screen.
    property string facetError: ""

    function refreshFacets() {
        if (!Client.connected) {
            // NOT a silent return. This ran before the socket was up and then
            // nothing asked again, so the filter panel stayed empty for the
            // life of the process with nothing anywhere saying why.
            root.facetError = "not connected";
            return;
        }
        Client.call("sources", {}, function (err, payload) {
            if (err || !payload) {
                root.facetError = String(err || "empty payload");
                return;
            }
            root.facetError = "";
            root.damaged = payload.damaged || root.damaged;
            root.facetSources = payload.sources || [];
            root.facetKinds = payload.kinds || [];
            root.facetFamilies = payload.families || [];
            root.suggestions = payload.suggestions || [];
            /*
             * A SITE'S OWN TABLE OF CONTENTS.
             *
             * `[[sections]]` in a source manifest — Pornhub's thirty-six
             * categories, a booru's popular tags. The daemon has always sent
             * them and nothing kept them, so every screen that wanted a site's
             * own navigation had to hard-code a second copy that would drift.
             */
            root.facetSections = payload.sections || [];
        });
        root.refreshHidden();
        root.refreshSourcePrefs();
        root.refreshBoards();
    }

    /// Ask again the moment the socket comes up — the first attempt is usually
    /// too early, and without this the panel never recovers from that.
    // Assigned to a named property, not the default one: this singleton's root
    // is a QtObject and has no default property to hold a child.
    property Connections _reconnect: Connections {
        target: Client
        function onConnectedChanged() {
            if (Client.connected)
                root.refreshFacets();
        }
    }

    /*
     * AND ONCE, THE MOMENT THIS SINGLETON EXISTS.
     *
     * QML instantiates a singleton lazily, at its first reference. That is
     * routinely AFTER the socket has already said `ready` and gone connected,
     * so `onReady` never runs here and `onConnectedChanged` never fires again
     * either -- the value it would report is already true. The facets survived
     * that only because the filter panel re-asks every time it opens; the
     * source preferences had nothing asking on their behalf and stayed empty
     * for the life of the process.
     */
    function _refreshOnFirstUse() {
        if (Client.connected)
            root.refreshFacets();
    }

    signal changed

    function _distinct(field) {
        const seen = {};
        const out = [];
        for (let i = 0; i < root._base.length; i++) {
            const v = root._base[i][field];
            if (v && !seen[v]) {
                seen[v] = true;
                out.push(v);
            }
        }
        out.sort();
        return out;
    }

    function load() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../fixtures/sample.json"));
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return;
            try {
                const doc = JSON.parse(xhr.responseText);
                root._base = doc.items || [];
                root.error = root._base.length ? "" : "fixture is empty";
            } catch (e) {
                root.error = "fixture unreadable: " + e;
                root._base = [];
            }
            root.loading = false;
            root.filter();
        };
        xhr.send();
    }

    /*
     * Run the query.
     *
     * The result is an index and a ratio array — never records. Everything the
     * gallery needs to lay out 137k tiles fits in about a megabyte.
     */
    /*
     * Run the query.
     *
     * Against the daemon this is one round trip that answers with a count and a
     * ratio per row — 1.1 MB for 137k rows, where the records would have been
     * ~930 MB in this engine. Offline it does the same work over the fixture.
     * Callers cannot tell, which is the entire point of PROTOCOL.md.
     */
    /*
     * Debounced.
     *
     * Startup changes the query three or four times within a few milliseconds —
     * the fixture loads, the socket connects, a launcher action applies its
     * query — and each one replaced the daemon's result while page requests for
     * the previous one were still in flight. Every one of those came back
     * "stale queryId". Coalescing them means the first page request is made
     * against a query that is going to survive.
     */
    function filter() {
        // A "similar" result is not a query: rows arriving in the background
        // (endless fetch, a crawl) must not quietly replace it. Changing the
        // query leaves it — see onQueryChanged.
        if (root.similarTo)
            return;
        filterDebounce.restart();
    }

    function filterNow() {
        filterDebounce.stop();
        if (Client.connected) {
            root._queryRemote();
            return;
        }
        root._queryLocal();
    }

    /// Typing "sunset" is one search, not six: the record waits for the words
    /// to stop moving.
    property Timer _rememberQuery: Timer {
        id: rememberQuery
        interval: 1200
        onTriggered: {
            const q = (root.query || "").trim();
            if (q.length > 1)
                root.remember("search", q, "");
        }
    }

    property Timer _filterDebounce: Timer {
        id: filterDebounce
        interval: 40
        onTriggered: root.filterNow()
    }

    /// Bumped when a query is SENT, so a reply can tell "the user typed
    /// something else" from "another client replaced the stored result".
    property int _queryGen: 0

    /*
     * HOW LONG A FILTER TAKES, IN THREE PARTS.
     *
     * "It feels slow" is not a measurement and cannot be fixed. These are
     * read by `app probe` (catalog.timing), so the cost of a filter change can
     * be split into the daemon answering, this client applying the answer, and
     * the wall relaying out — rather than argued about.
     */
    property int lastQueryMs: 0      // the daemon's answer, round trip
    property int lastApplyMs: 0      // parsing it and handing it to the view
    property int lastResultCount: 0
    // The three parts of "applying" it, so the expensive one is named.
    property int _ratiosMs: 0
    property int _pagesMs: 0
    property int _changedMs: 0

    function _queryRemote() {
        const asked = root.query;
        const sentAt = Date.now();
        root._queryGen++;
        const gen = root._queryGen;
        Client.call("query", {
            // No structured fields any more: they are tokens in `q`, and the
            // daemon has always parsed those. Sending both meant the same
            // predicate arrived twice.
            "q": root.query,
            "repeat": root.repeat
        }, function (err, payload) {
            if (err) {
                root.error = err;
                return;
            }
            root.lastQueryMs = Date.now() - sentAt;
            const applyAt = Date.now();
            root.error = "";
            root.sort = payload.sort || "relevance";
            root.unknownKeys = payload.unknown || [];
            /*
             * A REFRESH KEEPS WHAT IT IS SHOWING.
             *
             * Dropping every page on each answer was fine when a query was a
             * thing you typed. It is now also what runs every couple of
             * seconds while a search fills the catalogue — and each drop
             * emptied the wall, so every visible tile asked for its page
             * again: measured at 213,913 asks, nearly all of them pending,
             * and a screen of placeholders the whole time.
             *
             * The rows a page holds can shift as results arrive, so the held
             * pages are stale — but a stale picture in the right cell reads as
             * "loading is done", and it is replaced the moment its page lands.
             * A genuinely new query still clears, below.
             */
            // The words this answer belongs to, not whatever is in the field
            // now: a reply that lands after the query moved on must not label
            // its rows with the new words.
            const sameQuery = root._pagedQuery === asked;
            root._pagedQuery = asked;
            const resident = sameQuery ? root._pageOrder.slice() : [];
            if (!sameQuery)
                root._dropPages();
            /*
             * A page asked for under the PREVIOUS queryId is still marked
             * pending, and _requestPage answers a pending page by doing
             * nothing — so the re-request below was skipped and the page kept
             * the old result's rows for good, which is a click opening
             * somebody else's picture. The in-flight replies are dropped by
             * the queryId check anyway, so nothing is lost by forgetting them.
             */
            root._pendingPages = ({});
            root._pageSentAt = ({});
            root._queryId = payload.queryId;
            root.damaged = payload.damaged || "";
            root.userDataError = payload.userData || "";
            const ratiosAt = Date.now();
            /*
             * THE FIRST SLICE OF THE GEOMETRY. THE REST IS PULLED.
             *
             * `query` used to answer with one ratio per row, and over this
             * catalogue that is a 10.3 MB frame holding a 752,168-element
             * array — which SEGFAULTS QV4 inside `JSON.parse`. Bisected in pure
             * JS with no socket in it: 500,000 elements parse, 600,000 kill the
             * engine. There is no JS error to catch and no QML file named in the
             * backtrace, so the app just died about ten seconds into launch and
             * could not report why from inside itself.
             *
             * The daemon now caps the frame (PROTOCOL.md `ratios`) and the rest
             * arrives in slices. Measured: 752,168 ratios in 110 ms this way,
             * against 875 ms and a dead process for the single frame.
             */
            root.ratios = payload.ratios || [];
            root._pullRatios(gen, payload.queryId, payload.count, function () {
                root._ratiosMs = Date.now() - ratiosAt;
                root.count = payload.count;
                root.loading = false;
                const pagesAt = Date.now();
                for (const page of resident)
                    root._requestPage(Number(page));
                root._pagesMs = Date.now() - pagesAt;
                const changedAt = Date.now();
                root.changed();
                root._changedMs = Date.now() - changedAt;
                root.lastApplyMs = Date.now() - applyAt;
                root.lastResultCount = root.count;
            });
        });
    }

    /*
     * Fetch ratio slices until the wall's geometry is complete, then `done()`.
     *
     * `push` into the array already there, never `concat`: SlotGeometry takes
     * its O(added) append path only while the array's identity is unchanged, and
     * a new array on every slice would rebuild the whole masonry eight times
     * over on one launch.
     *
     * `count` is deliberately NOT set until this finishes. `ratioAt` answers 1.0
     * for a row it has no ratio for, so publishing the full count early lays out
     * tens of thousands of tiles as squares and then moves every one of them as
     * the slices land — the wall visibly reflowing under the cursor. A spinner
     * for 110 ms is the better trade.
     */
    function _pullRatios(gen, queryId, total, done) {
        if (gen !== root._queryGen)
            return;                       // the query moved on; this wall is gone
        const have = root.ratios.length;
        if (have >= total || have === 0) {
            done();
            return;
        }
        Client.call("ratios", {
            "queryId": queryId,
            "from": have,
            "count": 100000
        }, function (err, payload) {
            if (gen !== root._queryGen)
                return;
            /*
             * A slice that cannot be had is not fatal. Every row past what did
             * arrive draws at 1.0 until the next query, which is a wall with
             * some wrongly-shaped tiles at the bottom — worth strictly more than
             * no wall, and the alternative here is an empty screen with the
             * spinner up for good.
             */
            const got = (payload && payload.ratios) || [];
            if (err || got.length === 0) {
                if (err)
                    root.error = err;
                done();
                return;
            }
            for (let i = 0; i < got.length; i++)
                root.ratios.push(got[i]);
            root._pullRatios(gen, queryId, payload.total || total, done);
        });
    }

    /*
     * THE CRAWL ADDED ROWS — GROW THE WALL, DO NOT REBUILD IT.
     *
     * `filter()` here was what made the gallery change under you while you
     * scrolled: a background fetch landed, the query ran again, and every
     * offset held a different picture, so the screen you were reading reloaded
     * into something else. `extend` appends only the new matches to the result
     * already open, so what is on screen stays exactly where it is and the
     * wall grows at the bottom — which is what an endless feed is.
     *
     * A stale id means the result it would grow is gone; then, and only then,
     * the query runs again.
     */
    /// `catalog.changed` arrives as fast as a 57-source crawl writes rows;
    /// `filter()` had a 40ms coalescer and `_extend` needs one too.
    property Timer _extendSoon: Timer {
        id: extendSoon
        interval: 250
        onTriggered: root._extend()
    }
    property bool _extending: false
    // When the daemon last said rows landed; the polling fallback stands down while it talks.
    property real _lastChange: 0

    // Started, not restarted: a search files a page every few milliseconds,
    // and restarting on each one held the wall back until the last site.
    function queueExtend() {
        if (!extendSoon.running)
            extendSoon.start();
    }

    function _extend() {
        if (root.similarTo)
            return;
        if (root._extending) {
            // One in flight is enough; the next event will ask again.
            root.queueExtend();
            return;
        }
        if (!Client.connected || root._queryId === 0 || root._pagedQuery !== root.query) {
            root.filter();
            return;
        }
        root._extending = true;
        Client.call("extend", {
            "q": root.query,
            "queryId": root._queryId
        }, function (err, payload) {
            root._extending = false;
            if (err || !payload) {
                root.filter();
                return;
            }
            if (payload.queryId !== root._queryId || (payload.added || 0) === 0)
                return;
            /*
             * The page that held the old last row is short — it was fetched
             * when the result ended there — so it is asked for again.
             *
             * ASKED FOR, NOT FORGOTTEN. Forgetting it deleted the records
             * under the viewport, and the endless scroll puts you exactly
             * there: every extend blanked the bottom screenful to placeholders
             * for a round trip. Re-requesting overwrites the page in place and
             * nothing ever draws empty.
             */
            if (root.count > 0) {
                const last = Math.floor((root.count - 1) / root.pageSize);
                delete root._pendingPages[last];
                if (root._pages[last] !== undefined)
                    root._requestPage(last);
            }
            /*
             * PUSHED, NOT CONCATENATED. `concat` hands back a NEW array, and
             * SlotGeometry takes its append fast-path only while the array
             * identity is unchanged — so every growth rebuilt the masonry,
             * emptied each column for a frame and dropped the view at the top
             * of the wall. Growing in place notifies through `count` alone,
             * which is the O(added) path this function exists to take.
             */
            const grown = payload.ratios || [];
            for (let i = 0; i < grown.length; i++)
                root.ratios.push(grown[i]);
            root.count = payload.count;
            root.pageEpoch++;
            root.changed();
        });
    }

    function _queryLocal() {
        const q = root.query.trim().toLowerCase();
        const base = root._base;
        const idx = [];
        const rat = [];

        for (let r = 0; r < root.repeat; r++) {
            for (let i = 0; i < base.length; i++) {
                const it = base[i];
                if (root.kind && it.kind !== root.kind)
                    continue;
                if (root.source && it.source !== root.source)
                    continue;
                if (root.family && it.family !== root.family)
                    continue;
                if (q.length > 0) {
                    const hay = (it.title + " " + it.slug + " " + it.source + " " + (it.tags || []).join(" ")).toLowerCase();
                    if (hay.indexOf(q) < 0)
                        continue;
                }
                idx.push(i);
                rat.push(it.ratio > 0 ? it.ratio : 1.0);
            }
        }

        root._dropPages();
        root._index = idx;
        root.ratios = rat;
        root.count = idx.length;
        root.changed();
    }

    // ── the resident window ──────────────────────────────────────────────────

    /// The query the held pages belong to: a refresh of the same words keeps
    /// them, a different query cannot.
    property string _pagedQuery: ""

    function _dropPages() {
        root._pages = ({});
        root._pageOrder = [];
        // In-flight requests belong to the query being left behind. Their
        // replies are dropped, so the marks must go too or those pages read as
        // "already asked" against the new query and are never fetched.
        root._pendingPages = ({});
        root._pageSentAt = ({});
        root.pagesResident = 0;
    }

    /// Put `page` at the young end of the eviction order, once.
    function _touchPage(page) {
        const n = Number(page);
        const at = root._pageOrder.indexOf(n);
        if (at >= 0)
            root._pageOrder.splice(at, 1);
        root._pageOrder.push(n);
    }

    /// Forget a page's records without touching the rest of the window.
    function _forgetPage(page) {
        const n = Number(page);
        const at = root._pageOrder.indexOf(n);
        if (at >= 0)
            root._pageOrder.splice(at, 1);
        delete root._pages[n];
        // …and that it was asked for, or the in-flight reply re-stores the
        // short page and every appended row past it reads as undefined.
        delete root._pendingPages[n];
        root.pagesResident = root._pageOrder.length;
    }

    function _loadPage(page) {
        const start = page * root.pageSize;
        const end = Math.min(start + root.pageSize, root.count);
        const out = new Array(end - start);
        for (let i = start; i < end; i++) {
            const src = root._base[root._index[i]];
            // The daemon restarting drops the socket for a moment and this
            // local path runs against an index the base no longer matches:
            // an empty slot for now, filled when the query runs again.
            if (!src) {
                out[i - start] = null;
                continue;
            }
            // A distinct record per result row: same fields, its own id, so a
            // repeated fixture behaves like a catalog of distinct items.
            const copy = Object.assign({}, src);
            copy.id = src.id + (i >= root._base.length ? "#" + Math.floor(i / root._base.length) : "");
            out[i - start] = copy;
        }

        root.pageLoads++;
        // The offline path gets the same script pass as the daemon-backed
        // one: a filter that quietly stops working when the daemon is down is
        // worse than no filter.
        root._pages[page] = root._applyScripts(out);
        // Once per page, or the next store evicts the page just loaded.
        root._touchPage(page);
        root.pagesResident = root._pageOrder.length;
        root.pageEpoch++;

        // Evict the least recently loaded page. This is the whole memory bound:
        // pages × pageSize records, and nothing else.
        while (root._pageOrder.length > root.maxPages) {
            const victim = root._pageOrder.shift();
            delete root._pages[victim];
            root.pagesEvicted++;
        }
        root.pagesResident = root._pageOrder.length;
        return out;
    }

    /// Where a record sits in the current result, among the pages held —
    /// -1 when its page is not loaded (a menu opened on it means it is).
    /*
     * Where a row sits in the WHOLE result, not just the loaded part.
     *
     * `indexOfId` can only see pages the wall has fetched, so reopening a
     * picture from history worked near the top of a result and nowhere else.
     * The daemon holds the order; `locate` asks it. `at` is -1 for a row that
     * is not in this result, which is an ordinary answer, not an error.
     */
    function locateId(id, callback) {
        if (!Client.connected || !id || id.length === 0) {
            callback(-1);
            return ;
        }
        Client.call("locate", {
            "queryId": root._queryId,
            "id": id
        }, function (err, payload) {
            callback(err || !payload ? -1 : Number(payload.at));
        });
    }

    /// The record for a row that may not be in a loaded page.
    function fetchRecord(id, callback) {
        const held = root.recordFor(id);
        if (held) {
            callback(held);
            return ;
        }
        Client.call("item", { "id": id }, function (err, payload) {
            callback(err || !payload ? null : payload.item);
        });
    }

    function indexOfId(id) {
        for (const key in root._pages) {
            const rows = root._pages[key];
            for (let k = 0; k < rows.length; k++) {
                if (rows[k] && rows[k].id === id)
                    return Number(key) * root.pageSize + k;
            }
        }
        return -1;
    }

    /*
     * HIDE MEANS GONE.
     *
     * Both "Hide forever" rows said "Hidden" in a toast and changed nothing:
     * the daemon has had `hide` all along and neither called it, so the
     * picture came straight back on the next page. It is asked now, and the
     * result is refreshed so the tile leaves the wall.
     */
    /// Turn a video's thumbnail into the video, by reading the page it came
    /// from. Search engines index the still and link the page.
    property bool resolving: false
    function resolveVideo(item, callback) {
        if (!item || !Client.connected)
            return;
        root.resolving = true;
        Toast.show("Looking for the video on its page…");
        Client.call("resolve", { "id": item.id }, function (err, payload) {
            root.resolving = false;
            if (err || !payload) {
                Toast.error(String(err) === "no video on that page" ? "That page has no video to play" : `Could not look: ${err}`);
                return;
            }
            Toast.show(payload.changed ? "Found the video" : "Already the video");
            if (callback)
                callback(payload);
        });
    }

    /*
     * The record that outlives the session. The back arrow walks where you have
     * been since the app started; this is what you can come back to tomorrow.
     */
    function remember(kind, value, item) {
        if (!Prefs.keepHistory || !Client.connected)
            return;
        if ((!value || value.length === 0) && (!item || item.length === 0))
            return;
        Client.call("history_add", {
            "kind": kind,
            "value": value || "",
            "item": item || "",
            "context": root.hereNow()
        }, function () {});
    }

    /*
     * WHERE YOU WERE WHEN THIS HAPPENED.
     *
     * Stored beside the entry so coming back lands you in the same place, not
     * merely on the same picture. An entry used to be an id and a timestamp:
     * something opened three screens deep inside the Reddit lens came back as
     * a bare `reddit:1wgxiqf` that reopened in the catalogue, under whatever
     * query happened to be current.
     *
     * The daemon keeps this opaque — a lens names its own screens, and nothing
     * in the daemon should have to know what "post" or "aww" mean.
     */
    function hereNow() {
        const lens = Lenses.activeLens;
        return {
            "query": root.query,
            "lens": Lenses.activeId,
            "screen": lens ? String(lens.screen || "") : "",
            "title": lens && lens.screenTitle ? String(lens.screenTitle) : ""
        };
    }

    function hideItem(item) {
        if (!item)
            return;
        if (!Client.connected) {
            Toast.error("Can't hide — start quarryd first");
            return;
        }
        Client.call("hide", { "id": item.id }, function (err) {
            if (err) {
                Toast.error(`Could not hide: ${err}`);
                return;
            }
            Toast.show("Hidden · you won't see it again");
            // A "like this" answer is a network question; it is not asked
            // again for one hidden tile.
            if (!root.similarTo)
                root.filter();
        });
    }

    function itemAt(i) {
        root._stats.lookups++;
        if (i < 0 || i >= root.count)
            return null;

        const page = Math.floor(i / root.pageSize);
        const held = root._pages[page];
        if (held !== undefined) {
            const at = i - page * root.pageSize;
            /*
             * ASK FOR THE NEXT PAGE BEFORE THE WALL GETS THERE.
             *
             * A page was only ever requested once a cell inside it was already
             * on screen, so a scroll outran the fetch and you watched a
             * screenful of placeholders fill in behind you. The layout places
             * all 111,690 cells at once, which makes it look like the pictures
             * are broken rather than late.
             *
             * So crossing into the last fifth of a held page asks for the next
             * one. Deduplicated by the pending mark like any other ask, and
             * bounded by `maxPages` eviction exactly as before — this changes
             * WHEN a page is fetched, not how many are kept.
             */
            if (root.live && at >= Math.floor(root.pageSize * 0.8)) {
                const ahead = page + 1;
                if (ahead * root.pageSize < root.count && root._pages[ahead] === undefined)
                    root._requestPage(ahead);
            }
            if (at < held.length)
                return held[at];
            /*
             * A SHORT PAGE IS NOT AN ANSWER.
             *
             * A page fetched when the result ended inside it is shorter than
             * pageSize. Rows appended afterwards fall past its end, and this
             * returned `undefined` for them — for good, because a held page is
             * never asked for again. Those cells stayed blank and a click on
             * one opened whatever the viewer had last. Asking again is
             * loop-free: the page comes back full length.
             */
            if (root.live) {
                root._requestPage(page);
                return null;
            }
        }

        root._stats.live = root.live ? 1 : 0;
        root._stats.queryId = root._queryId;
        if (root.live) {
            // Off-box pages are asynchronous, so the tile gets null now and
            // fills itself when the page lands. That is not a degradation to
            // paper over: it is what a catalog too big to hold looks like, and
            // the placeholder is already the right thing to draw.
            root._requestPage(page);
            return null;
        }
        return root._loadPage(page)[i - page * root.pageSize];
    }

    /*
     * SOMEBODY ELSE TOOK THE RESULT.
     *
     * The daemon keeps ONE stored query result for every client, so a second
     * quarry window — or a script — running a query invalidates this one's
     * pages mid-flight, and every page then comes back "stale queryId".
     * Re-asking for the page cannot work: the result it belonged to is gone.
     * The query has to be run again first, and only once however many pages
     * failed, or the two clients trade invalidations in a loop (measured:
     * 24 million requests before this guard existed).
     */
    property double _recoveredAt: 0

    function _recover() {
        const now = Date.now();
        if (now - root._recoveredAt < 1500)
            return;
        root._recoveredAt = now;
        root.filter();
    }

    /*
     * WHICH REQUEST OWNS A PAGE.
     *
     * Clearing a pending mark is not cancelling the request that set it, so an
     * older reply could land after the page had been asked for again and put
     * its shorter, staler rows back on top — and its `delete _pendingPages`
     * cleared the NEWER request's mark, letting a third one through. Each
     * request takes a number; only the current owner stores or clears.
     */
    property var _pageGen: ({})
    property int _pageSeq: 0
    /// page -> when its request went out, for the watchdog below.
    property var _pageSentAt: ({})

    /*
     * A PENDING MARK THAT NOBODY WILL EVER CLEAR.
     *
     * `_pendingPages[page]` is set before the request goes out and cleared in
     * its callback, so the wall asks once rather than once per tile. But a
     * reply that never arrives — a daemon restarted mid-flight, a result taken
     * out from under us, a socket that dropped the frame — leaves the mark set
     * for the life of the session, and every later ask for that page returns
     * silently at the top of `_requestPage`.
     *
     * Measured on a live window: 524 asks, 3 requests issued, ONE page
     * resident against 111,691 placed cells. Every other cell drew its kind's
     * glyph, which reads as "the thumbnail is broken" and is nothing of the
     * sort — there was no row behind the cell at all.
     *
     * So a mark expires. Anything still pending after `pageTimeoutMs` is
     * treated as lost, cleared, and the epoch bumped so the tiles that gave up
     * ask again. Harmless if the reply then lands: `_pageGen` decides who owns
     * the page, and a late answer that no longer owns it is dropped exactly as
     * before.
     */
    readonly property int pageTimeoutMs: 8000

    property Timer _pageWatchdog: Timer {
        id: pageWatchdog

        interval: 2000
        repeat: true
        running: Client.connected
        onTriggered: {
            const now = Date.now();
            let lost = 0;
            for (const page in root._pendingPages) {
                const sent = root._pageSentAt[page] || 0;
                if (sent > 0 && now - sent < root.pageTimeoutMs)
                    continue;

                delete root._pendingPages[page];
                delete root._pageSentAt[page];
                lost += 1;
            }
            if (lost > 0) {
                root._stats.pageLost = (root._stats.pageLost || 0) + lost;
                root.pageEpoch++;
            }
        }
    }

    function _requestPage(page) {
        root._stats.pageAsk = (root._stats.pageAsk || 0) + 1;
        if (root._pendingPages[page]) {
            root._stats.pagePending = (root._stats.pagePending || 0) + 1;
            return;
        }
        root._pendingPages[page] = true;
        // When it was asked for — see `pageWatchdog`. A mark with no reply
        // behind it is the difference between "loading" and "never again".
        root._pageSentAt[page] = Date.now();

        const queryId = root._queryId;
        const gen = root._queryGen;
        const seq = ++root._pageSeq;
        root._pageGen[page] = seq;
        Client.call("items", {
            "queryId": queryId,
            "offset": page * root.pageSize,
            "limit": root.pageSize
        }, function (err, payload) {
            const mine = root._pageGen[page] === seq;
            if (mine) {
                delete root._pendingPages[page];
                delete root._pageSentAt[page];
            }
            if (err) {
                root._stats.pageErr = (root._stats.pageErr || 0) + 1;
                root._stats.lastPageErr = String(err);
                // Same reasoning as a stale page: something has to ask again.
                root.pageEpoch++;
                if (String(err).indexOf("stale queryId") >= 0)
                    root._recover();
                return;
            }
            // A page for a query that has since been replaced is dropped, not
            // stored: those rows belong to a different result.
            if (!payload || queryId !== root._queryId) {
                /*
                 * The query moved on while this page was in flight.
                 *
                 * Dropping it is right — those rows belong to a different
                 * result — but *only* dropping it was the launch bug: the
                 * tiles that asked had already been told "pending", so nobody
                 * ever asked again and the gallery stayed empty until
                 * something else happened to nudge it. Bumping the epoch makes
                 * them ask against the current query.
                 */
                root._stats.pageStale = (root._stats.pageStale || 0) + 1;
                root.pageEpoch++;
                // Only when the result was taken from under us. If a newer
                // query has been sent since, this reply is simply out of date
                // and re-querying to "recover" would be a second round trip
                // for something already on its way.
                if (gen === root._queryGen)
                    root._recover();
                return;
            }
            // A newer request owns this page; its answer is the one to keep.
            if (!mine)
                return;
            root._store(page, payload.items);
            root.changed();
        });
    }

    /*
     * Bumped whenever a page lands.
     *
     * Records are kept in a plain JS map that is *mutated*, deliberately — a
     * QML var property that notified on every insert would re-run every binding
     * that ever touched it. But a delegate created before its page arrived has
     * no way to learn that it can stop showing nothing, and that is a grid full
     * of blank cells. This counter is the one notification: cheap, coarse, and
     * exactly what "something new is available" means.
     */
    property int pageEpoch: 0

    /// How many rows user scripts have hidden this session.
    property int scriptHiddenCount: 0

    /// How many exports are in the air. The window's progress strip watches it;
    /// see the note where it is incremented.
    property int exporting: 0

    function _applyScripts(items) {
        if (!Prefs.scriptsEnabled || Scripts.rowHookCount === 0)
            return items;
        const context = {
            "source": root.filterValue("source"),
            "kind": root.filterValue("kind"),
            "family": root.filterValue("family"),
            "lens": Lenses.activeId,
            "screen": Prefs.layoutMode,
            "query": root.query
        };
        const kept = Scripts.filterRows(items, context);
        if (kept === items || kept.length === items.length)
            return items;
        const keptIds = {};
        for (const row of kept) if (row)
            keptIds[String(row.id)] = true;

        /*
         * A PAGE CAN ARRIVE WITH A HOLE IN IT.
         *
         * `Object.assign({}, null, …)` throws, and the throw happens inside a
         * map over every row of every page — so one missing row stopped the
         * whole page being marked and logged `TypeError: Value is null` on
         * repeat. The same hole bit `no-tiny-pictures`, which is why that
         * script opens with a null check.
         */
        const marked = items.map(row => {
            if (!row)
                return row;

            return keptIds[String(row.id)] ? row : Object.assign({}, row, {
                "scriptHidden": true
            });
        });
        // Counted, because a filter nobody can measure is a filter nobody can
        // tell from a bug — and `app probe` is how that is checked.
        root.scriptHiddenCount += items.length - kept.length;
        return marked;
    }

    function _store(page, items) {
        /*
         * Warm the page's pictures — but after the ones being looked at.
         *
         * Tiles ask for their own thumbnail the moment they appear, and those
         * requests share a daemon with this one. Firing a hundred-and-twenty
         * bulk fetches the instant a page lands put the whole visible screen
         * behind them: what you were looking at filled last. So the batch is
         * small and it waits for a lull.
         */
        const missing = items.filter(i => !i.thumb_local || i.thumb_local.length === 0).map(i => i.id);
        if (missing.length > 0) {
            root._warmQueue = root._warmQueue.concat(missing);
            /*
             * ENQUEUE, DO NOT RESTART.
             *
             * `restart()` pushed the timer's next tick a full interval away —
             * and during a scroll a new page lands more often than that, so the
             * countdown was reset before it ever fired and the warm queue never
             * drained at all. The only thumbnails being fetched were the eight
             * the visible tiles asked for themselves, which is exactly the
             * row-by-row cascade you can watch travel down the wall.
             *
             * The timer's `running` is already bound to the queue being
             * non-empty, so it starts on its own. It just must not be told to
             * begin again every time something is added to what it is draining.
             */
            if (!warmIdle.running)
                warmIdle.start();
        }

        root.pageLoads++;
        /*
         * USER SCRIPTS SEE THE PAGE BEFORE THE WALL DOES.
         *
         * A script's `rows` hook returns what it wants kept — the 4chan X
         * move, where a filter hides a post rather than editing it. What it
         * drops is NOT removed from the page: a short page sends `itemAt`
         * down its "a short page is not an answer" path and re-requests
         * forever. The row stays, marked, and the tile draws a stub it can
         * click through — which is also how the thing it is modelled on
         * behaves.
         */
        root._pages[page] = root._applyScripts(items);
        /*
         * ONE ENTRY PER PAGE IN THE EVICTION ORDER.
         *
         * A refresh re-requests every resident page, and storing it again
         * pushed a SECOND entry for the same number. With eight residents the
         * next store popped the head — the page that had just been stored —
         * so the record was deleted while `_pageOrder` still named it, and the
         * wall emptied and could not refill.
         */
        root._touchPage(page);
        while (root._pageOrder.length > root.maxPages) {
            const victim = root._pageOrder.shift();
            delete root._pages[victim];
            root.pagesEvicted++;
        }
        root.pagesResident = root._pageOrder.length;
        // Tiles that asked while this page was in flight were told "nothing
        // yet"; this is what tells them to ask again. Without it a remote page
        // landed into a grid that never looked at it — every cell stayed empty
        // on launch.
        root.pageEpoch++;
    }

    function lookups() {
        return root._stats.lookups;
    }

    /*
     * A LOCAL THUMBNAIL THAT IS NOT THERE ANY MORE.
     *
     * The view reports this when an Image fails on a `file://` source: the only
     * place the truth is known, because nothing else looks at the disk. The
     * path is struck off so `thumbFor` stops handing it out, and the daemon is
     * asked for the picture properly — which re-fetches it if the file really
     * is gone.
     */
    property var _localGone: ({})

    function thumbVanished(item, size) {
        if (!item)
            return ;

        if (item.thumb_local && item.thumb_local.length > 0)
            root._localGone[item.thumb_local] = true;

        root._stats.thumbLocalGone = (root._stats.thumbLocalGone || 0) + 1;
        delete root._thumbs[item.id + "@" + size];
        // Ask again, now that the shortcut is out of the way.
        root.thumbReady(item.id, root.thumbFor(item, size));
    }

    function thumbStats() {
        // The live shape of the pager, not just its running totals: "521 asks,
        // 3 issued" says nothing about whether a mark is stuck or the wall
        // simply stopped asking, and those want opposite fixes.
        const pending = Object.keys(root._pendingPages);
        return JSON.stringify(Object.assign({}, root._stats, {
            "pendingNow": pending.length,
            "pendingPages": pending.slice(0, 12),
            "heldPages": Object.keys(root._pages),
            "pageSize": root.pageSize,
            "count": root.count
        }));
    }

    /// Find a materialised record by id, across the pages currently held.
    function itemById(id) {
        for (const page in root._pages) {
            const rows = root._pages[page];
            for (let i = 0; i < rows.length; i++)
                if (rows[i] && rows[i].id === id)
                    return rows[i];
        }
        return null;
    }

    function ratioAt(i) {
        return root.ratios[i] || 1.0;
    }

    // ── thumbnails ───────────────────────────────────────────────────────────

    /*
     * Local thumbnails, fetched by the daemon.
     *
     * Two reasons the view does not load remote URLs itself. Several sources
     * refuse hotlinked images — cdn.donmai.us and the Art Institute both answer
     * 403 to a direct request while their metadata APIs are fine — and a remote
     * thumbnail is whatever size the source felt like, where a local ladder step
     * matches the draw size so Qt never decodes 4000px to paint 330.
     */
    /*
     * Thumbnail paths, bounded.
     *
     * One entry per (item, size) is small, but "small × everything you scrolled
     * past in an hour" is not, and it never dropped anything. The map is capped
     * and the oldest entries go first — re-asking the daemon for a path it has
     * already cached costs a round trip and no work.
     */
    // The ladder step the daemon sends with each record.
    readonly property int recordThumbSize: 320

    /*
     * What a tile actually needs on this screen.
     *
     * Warming 320s for tiles that ask for 640 is a fetch nobody uses and a wait
     * nobody avoids, so the page warm and the tiles have to agree.
     */
    readonly property int tileThumbSize: Screen.devicePixelRatio > 1.2 ? 640 : 320

    property var _thumbs: ({})
    property var _thumbOrder: []
    readonly property int maxThumbPaths: 3000
    property var _thumbPending: ({})
    // key -> request id of a single `thumb` call, so a new search can withdraw them.
    property var _thumbCalls: ({})

    /*
     * A NEW SEARCH WITHDRAWS THE OLD SCREEN'S THUMBNAILS.
     *
     * They held the daemon's permits while waiting on image hosts, and the new
     * screen's queued behind them: rows at 0.56 s, first picture at 2.5 s.
     * Every tile gets a new row and asks again for what it still wants.
     */
    function dropThumbRequests() {
        const ids = [];
        for (const key in root._thumbCalls) {
            ids.push(root._thumbCalls[key]);
            delete root._thumbPending[key];
        }
        root._thumbCalls = ({});
        Client.cancel(ids);
    }
    /*
     * HOW MANY PICTURES ARE ON THEIR WAY.
     *
     * A tile with no picture yet and a tile whose picture failed draw the same
     * empty cell, so a wall of rows nobody has fetched yet is indistinguishable
     * from a wall that is broken. Measured on this catalogue: 65,790 cached
     * thumbnails for 227,604 rows, so `sort:new` — which puts the never-yet-
     * fetched rows first — fills the screen with cells that are merely waiting.
     *
     * Counting them lets the window's loading strip say "still working", which
     * is the one thing the empty cell cannot say for itself.
     */
    property int thumbsInFlight: 0
    // Cleared with the failure cache; a counter per key would otherwise grow for
    // as long as the app runs.
    property var thumbRetries: ({})

    /*
     * Nudge the views after a batch of failures.
     *
     * Tiles only ask for a thumbnail when something about them changes, so a
     * transient failure would otherwise sit there until the next scroll. One
     * epoch bump makes every visible tile ask again.
     */
    /*
     * A layout switch starts the new view over.
     *
     * The two layouts keep their own scroll position and their own delegates,
     * so switching used to land you in the middle of a half-built wall with
     * whatever the other view had already asked for. Bumping the epoch makes
     * the incoming layout populate itself from the top.
     */
    property Connections _layoutHooks: Connections {
        target: Prefs

        function onLayoutModeChanged() {
            root.pageEpoch++;
            // Whatever is on screen now is a different amount of content, so
            // the "am I near the end" answer changes with it.
            Qt.callLater(root.loadMore);
        }
    }

    property Timer _retryThumbs: Timer {
        id: retryThumbs
        interval: 1500
        onTriggered: root.pageEpoch++
    }
    property int thumbsCached: 0
    property int thumbsFailed: 0
    property int brokenSeen: 0

    /*
     * Re-running the query is what actually removes a retired row, and several
     * tiles usually fail together — one requery for the batch, not one each.
     */
    // Grown, not re-queried: a re-query renumbers every offset, so a broken
    // thumbnail retiring would move the picture under the pointer.
    property Timer _retireBroken: Timer {
        id: retireBroken
        interval: 700
        onTriggered: root._extend()
    }

    signal thumbReady(string id, string path)

    /*
     * Warm a whole page of thumbnails in one request.
     *
     * One call per tile was the starvation: ninety tiles on screen, each its own
     * round trip, each holding a network fetch — the gallery filled a few tiles
     * at a time and looked broken. The daemon fetches a batch in parallel and
     * answers with a map, so a page of records becomes one request.
     */
    /*
     * Warming happens in the gaps, in small batches.
     *
     * 24 at a time keeps the daemon's twelve slots busy without ever queueing
     * so deep that a newly visible tile has to wait behind the queue.
     */
    property var _warmQueue: []
    readonly property int warmBatch: 24

    /// How many warm batches may be out at once.
    ///
    /// MEASURED, not picked: one batch of 24 alone runs at 21 thumbs/s and two
    /// together at 36 — the daemon is not saturated by a single batch, so
    /// serialising them would have thrown away two thirds of the rate. Held at
    /// two deliberately; these fetches go to public boorus, and the way to make
    /// a wall load slower is to get rate-limited.
    readonly property int warmConcurrency: 2

    /// Batches currently out at the daemon.
    property int _warmInFlight: 0

    /*
     * The timer is now the KICK and the safety net, not the pump.
     *
     * The first batch still waits for a lull, deliberately — tiles on screen
     * ask for their own thumbnails and must not queue behind a bulk fetch.
     * After that each batch starts when the last one lands, which keeps the
     * queue depth (and so the worst case for a newly visible tile) exactly
     * where it was while removing the idle gap between batches.
     */
    property Timer _warmIdle: Timer {
        id: warmIdle
        /*
         * Short enough to keep up with a scroll.
         *
         * 500ms was chosen to let a page's visible tiles fetch before the bulk
         * warm competed with them — a real concern, and the wrong lever for it:
         * half a second is four or five rows at scrolling speed, so the warm
         * was always behind the eye. The batch size and the concurrency are
         * what bound the competition; the interval only decides how far behind
         * the queue runs.
         */
        interval: 150
        repeat: true
        running: root._warmQueue.length > 0
        onTriggered: root._pumpWarm()
    }

    function _pumpWarm() {
        /*
         * Bounded on BOTH axes: how many batches may be in flight, and how many
         * slices one pump may take.
         *
         * A batch whose ids are all cached returns without taking a slot, so
         * without the second bound a long queue of cached ids would drain in
         * one synchronous pass — each slice copying the rest of the array,
         * on the UI thread, which is a stutter in the middle of the scroll
         * this exists to smooth.
         */
        let slices = 0;
        while (root._warmInFlight < root.warmConcurrency && root._warmQueue.length > 0 && slices < 8) {
            slices++;
            const batch = root._warmQueue.slice(0, root.warmBatch);
            root._warmQueue = root._warmQueue.slice(root.warmBatch);
            root.warmThumbs(batch, root.tileThumbSize);
        }
        if (root._warmQueue.length > 0 && root._warmInFlight < root.warmConcurrency)
            Qt.callLater(root._pumpWarm);
    }

    function warmThumbs(ids, size) {
        if (ids.length === 0)
            return;
        if (!Client.connected) {
            // Put them back rather than dropping them: the queue drains on a
            // timer, so a batch discarded while the daemon restarts is a
            // screenful of thumbnails nobody ever fetches again.
            root._warmQueue = ids.concat(root._warmQueue);
            return;
        }

        const wanted = ids.filter(id => !root._thumbs[id + "@" + size] && !root._thumbPending[id + "@" + size]);
        if (wanted.length === 0) {
            // A batch that was entirely cached is not a reason to stall the
            // queue for a tick. callLater, not a direct call: draining a long
            // queue of cached ids would otherwise recurse once per batch.
            Qt.callLater(root._pumpWarm);
            return;
        }
        for (const id of wanted)
            root._thumbPending[id + "@" + size] = true;
            root.thumbsInFlight++;
        root._warmInFlight++;

        Client.call("thumbs", {
            "ids": wanted,
            "size": size
        }, function (err, payload) {
            for (const id of wanted)
                delete root._thumbPending[id + "@" + size];
                root.thumbsInFlight = Math.max(0, root.thumbsInFlight - 1);
            if (err || !payload) {
                root._warmInFlight--;
                Qt.callLater(root._pumpWarm);
                return;
            }

            let landed = 0;
            for (const id in payload.thumbs) {
                const key = id + "@" + size;
                root._thumbs[key] = "file://" + payload.thumbs[id];
                // The bulk warm is where nearly every path comes from, so
                // leaving it out of the order meant `maxThumbPaths` bounded
                // nothing and the map grew for the life of the process.
                root._thumbOrder.push(key);
                while (root._thumbOrder.length > root.maxThumbPaths)
                    delete root._thumbs[root._thumbOrder.shift()];
                root.thumbsCached++;
                landed++;
            }
            if (landed > 0)
                root.pageEpoch++;
            root._warmInFlight--;
            Qt.callLater(root._pumpWarm);
        });
    }

    /*
     * A PICTURE FOR A WORD, FROM WHAT IS ALREADY HERE.
     *
     * A wall of category cards wants a picture each, and fetching one per
     * category would be hundreds of requests for decoration. This answers only
     * from what the app is already holding: a row on a resident page whose
     * title carries the word, and only if its thumbnail has already been
     * fetched. No network, no daemon call, and an empty answer where there is
     * genuinely nothing — which the card draws as its name rather than as
     * somebody else's photograph.
     */
    function coverFor(word) {
        const needle = String(word || "").trim().toLowerCase();
        if (needle.length === 0)
            return "";
        for (const page in root._pages) {
            const rows = root._pages[page];
            if (!rows)
                continue;
            for (let i = 0; i < rows.length; i++) {
                const row = rows[i];
                if (!row || !row.title)
                    continue;
                if (String(row.title).toLowerCase().indexOf(needle) < 0)
                    continue;
                const held = root._thumbs[row.id + "@" + root.tileThumbSize];
                if (held && held.length > 0)
                    return held;
            }
        }
        return "";
    }

    function thumbFor(item, size) {
        // Counted per exit, because "no thumbnails appeared" has five possible
        // causes and guessing between them wasted a round of debugging.
        root._stats.thumbCalls = (root._stats.thumbCalls || 0) + 1;
        if (!item) {
            root._stats.thumbNoItem = (root._stats.thumbNoItem || 0) + 1;
            return "";
        }
        if (!Client.connected) {
            root._stats.thumbNoClient = (root._stats.thumbNoClient || 0) + 1;
            return item.thumb || item.url || "";
        }

        /*
         * The path that comes with the record is the *grid* thumbnail.
         *
         * The daemon fills `thumb_local` at the ladder step tiles use (320), so
         * returning it for any size at all handed the detail view a 320px file
         * to stretch across a 1200px pane — which is exactly what "bad quality"
         * looked like. It is only the right answer when that is the size being
         * asked for.
         */
        /*
         * The path the record arrived with, unless it has already been tried
         * and found gone — see `thumbVanished`.
         *
         * The daemon checks the file exists when it fills `thumb_local` in, but
         * that is true at PAGE-FETCH time and pages are held for a long while.
         * Thumbnails are evicted the whole time — the cache has a budget and it
         * trims, Settings can empty it outright — so a held record goes on
         * naming a file that is no longer there. Handing that dead path to an
         * Image produced a permanently blank tile: no request was made, so no
         * failure was ever counted, and every diagnostic in the app reported a
         * clean bill of health while a third of the wall sat empty.
         */
        if (size <= root.recordThumbSize && item.thumb_local && item.thumb_local.length > 0 && !root._localGone[item.thumb_local])
            return "file://" + item.thumb_local;

        const key = item.id + "@" + size;
        const held = root._thumbs[key];
        if (held !== undefined) {
            root._stats.thumbHit = (root._stats.thumbHit || 0) + 1;
            return held;
        }

        if (root._thumbPending[key])
            root._stats.thumbAlreadyPending = (root._stats.thumbAlreadyPending || 0) + 1;

        if (!root._thumbPending[key]) {
            root._stats.thumbRequested = (root._stats.thumbRequested || 0) + 1;
            root._thumbPending[key] = true;
            root._thumbCalls[key] = Client.call("thumb", {
                "id": item.id,
                "size": size,
                /*
                 * The URL this row arrived with, for the sources that sign
                 * theirs. Pornhub's posters carry an expiry: the copy stored in
                 * the catalogue goes 403 a day later and the tile stays empty
                 * for ever, while the row on screen — which came from a live
                 * listing — has a URL that works right now.
                 */
                "url": String(item.url || "")
            }, function (err, payload) {
                delete root._thumbPending[key];
                delete root._thumbCalls[key];
                if (err || !payload) {
                    root.thumbsFailed++;
                    // WHICH row failed, not just how many. "thumbsFailed: 2"
                    // on a wall of five hundred says nothing you can act on —
                    // the id names the source, and the source names the bug.
                    root._stats.lastThumbFail = `${item.id} @${size}: ${String(err).slice(0, 80)}`;
                    root._stats.thumbFailIds = (root._stats.thumbFailIds || []).concat([item.id]).slice(-8);

                    if (payload && payload.broken) {
                        /*
                         * The daemon tried the thumbnail and the original and
                         * neither is an image. This row will never fill a cell,
                         * so it leaves the results entirely.
                         */
                        root._thumbs[key] = "";
                        root.brokenSeen++;
                        retireBroken.restart();
                    } else {
                        /*
                         * Everything else is temporary — a timeout, a daemon
                         * restarting, a source having a bad minute.
                         *
                         * Caching "" for those was catastrophic: one blip while
                         * a screenful was loading left every one of those tiles
                         * permanently empty, and nothing ever asked again. The
                         * whole gallery went grey and stayed grey. So a failure
                         * is *not* remembered; the next time the tile asks, it
                         * asks the daemon.
                         */
                        delete root._thumbs[key];
                        root.thumbRetries[key] = (root.thumbRetries[key] || 0) + 1;
                        if (root.thumbRetries[key] <= 3)
                            retryThumbs.restart();
                    }
                } else {
                    root._thumbs[key] = "file://" + payload.path;
                    root.thumbsCached++;
                }

                root._thumbOrder.push(key);
                while (root._thumbOrder.length > root.maxThumbPaths) {
                    const victim = root._thumbOrder.shift();
                    delete root._thumbs[victim];
                }

                root.thumbReady(item.id, root._thumbs[key]);
            });
        }

        /*
         * Nothing until it lands.
         *
         * Showing the remote URL meanwhile looks like a free first paint, and
         * on the sources that block hotlinking (cdn.donmai.us, the Art
         * Institute) it is a guaranteed 403 per tile — a wall of failed
         * requests and console noise for an image that was never going to
         * appear. The placeholder is already the right thing to draw.
         */
        return "";
    }

    /*
     * Fill in what a listing could not say.
     *
     * A crawl gets an image and an id; the item's own page has the title, who
     * uploaded it, and the tags it was filed under. One request, made when
     * something is actually opened.
     */
    property var _enriched: ({})

    function enrich(item, callback) {
        if (!item || !Client.connected || root._enriched[item.id]) {
            if (callback)
                callback(null, item, []);
            return;
        }
        root._enriched[item.id] = true;

        Client.call("enrich", {
            "id": item.id
        }, function (err, payload) {
            if (err || !payload || !payload.item) {
                if (callback)
                    callback(err, item, []);
                return;
            }
            // The record lives in a page the client holds, so update it there
            // rather than waiting for the page to be refetched.
            for (const page in root._pages) {
                const rows = root._pages[page];
                for (let i = 0; i < rows.length; i++) {
                    if (rows[i].id === payload.item.id) {
                        rows[i] = payload.item;
                        root.pageEpoch++;
                    }
                }
            }
            if (callback)
                callback(null, payload.item, payload.related || []);
        });
    }

    // ── collections ──────────────────────────────────────────────────────────

    property var collections: []
    /// Which collections the item under inspection belongs to. Fetched per
    /// item rather than held for the whole catalogue: membership is only ever
    /// looked at one row at a time.
    property var collectionsOfItem: []

    function refreshCollections() {
        if (!Client.connected)
            return;
        Client.call("collections", {
            "action": "list"
        }, function (err, payload) {
            if (!err && payload)
                root.collections = payload.collections || [];
        });
    }

    function collectionsOf(item, callback) {
        if (!item || !Client.connected) {
            if (callback)
                callback([]);
            return;
        }
        Client.call("collections", {
            "action": "of",
            "id": item.id
        }, function (err, payload) {
            const names = (!err && payload) ? (payload.collections || []) : [];
            root.collectionsOfItem = names;
            if (callback)
                callback(names);
        });
    }

    function keep(item, name, member) {
        if (!item || !name || name.length === 0)
            return;
        Client.call("collections", {
            "action": member ? "add" : "remove",
            "name": name,
            "id": item.id
        }, function (err, payload) {
            if (err) {
                Toast.error(err);
                return;
            }
            root.collections = payload.collections || [];
            root.collectionsOfItem = payload.of || [];
            Toast.show(member ? `Kept in ${name}` : `Removed from ${name}`);
            // A collection view has to lose the row it just lost.
            if (!member && root.query.indexOf("in:" + name) >= 0)
                root.filterNow();
        });
    }

    // ── export ───────────────────────────────────────────────────────────────

    property string lastExport: ""

    /*
     * Export an item to a named target.
     *
     * The daemon fetches the original, applies the target's recipe and writes
     * the file — vectors rasterised at the export size rather than resampled,
     * and never overwriting an existing file. The callback gets the path so the
     * UI can say where it went, which is the only part of an export anyone
     * actually needs to see.
     */
    /// Runs a target's `apply` step. Named property, not a child: the root
    /// here is a QtObject and has no default property to put one in.
    property Process _applyProc: Process {
        onExited: (code) => {
            if (code !== 0)
                Toast.error("That did not apply — see the log");
        }
    }

    /// "More like this" — the same result machinery, chosen differently.
    ///
    /// The daemon replaces the current result with the near-hash matches, so
    /// everything downstream (pages, ratios, the masonry, the view) carries on
    /// unchanged. The only new state is a note of what we are looking at, so
    /// the bar can say so and so there is something to go back FROM.
    property var similarTo: null
    property string similarMethod: "all"
    property int _similarGeneration: 0
    property bool findingSimilar: false

    /*
     * THE WAYS TO ASK "WHAT IS LIKE THIS", FOR ONE PICTURE.
     *
     * Three groups, in the order you actually reach for them: what is already
     * in your catalogue, what the rest of the web has, and the plain searches
     * the bar could have said — its tags, its artist, its colour, its shape —
     * offered here because "like this" is the moment you think of them.
     *
     * Every row is a VERB, because every row does something. And a row is only
     * here when it can work for THIS picture: no tags means no "search its
     * tags", a local file means no "more on its site", an unmeasured picture
     * means no "match its colour". A menu full of entries that answer nothing
     * teaches you to stop opening it.
     *
     * One list, read by the tile menu and the viewer, so both say the same.
     */
    function similarMethods(item) {
        if (!item)
            return [];
        const site = item.source || "its site";
        // "More avatars from local" is not a sentence; the same query is.
        const where = item.source === "local" ? "your own files" : site;
        const sized = item.w > 0 && item.h > 0;
        const out = [
            {
                "id": "all",
                "label": "Find everything alike",
                "icon": "auto_awesome",
                "hint": "here · its site · the web"
            },
            {
                "id": "look",
                "label": "Find look-alikes here",
                "icon": "filter_center_focus",
                "hint": "your catalogue"
            },
            {
                "id": "dupes",
                "label": "Find exact copies here",
                "icon": "join_inner",
                "hint": "the same file again"
            }
        ];

        /*
         * The web rows are never conditional, and that is new.
         *
         * Yandex is handed the picture itself when there is no URL it will
         * take, so a local file, a hotlink-blocked host and a video's poster
         * frame all answer now. Hiding these on a local row would hide the
         * case they were built for.
         */
        out.push({
            "id": "sep-web",
            "separator": true
        });
        out.push({
            "id": "web",
            "label": "Find it on the web",
            "icon": "travel_explore",
            "hint": "Yandex"
        });
        out.push({
            "id": "bigger",
            "label": "Find a bigger copy",
            "icon": "zoom_in",
            "hint": sized ? `bigger than ${item.w}×${item.h}` : "any larger copy"
        });
        out.push({
            "id": "sites",
            "label": "See where else it appears",
            "icon": "public",
            "hint": "pages that carry it"
        });
        if (root._canAskSite(item))
            out.push({
                "id": "native",
                "label": item.source === "wallhaven" ? "See wallhaven's own similar" : `See more on ${site}`,
                "icon": "language",
                "hint": "its site"
            });

        const searches = [];
        const tags = (item.tags || []).filter(t => t && t.indexOf(":") < 0);
        if (tags.length > 0)
            searches.push({
                "id": "tags",
                "label": "Search its tags",
                "icon": "sell",
                "hint": tags.slice(0, 2).join(" + ")
            });
        // A row from an album (erome) carries `album:<id>`: the rest of it is
        // one tag search away.
        const albumTag = (item.tags || []).find(t => String(t).indexOf("album:") === 0);
        if (albumTag)
            searches.push({
                "id": "album",
                "label": "The rest of this album",
                "icon": "photo_album",
                "hint": "same post"
            });
        // Quoted when it has to be, so a two-word artist is searchable at all.
        if (item.author && item.author.length > 0)
            searches.push({
                "id": "author",
                "label": `Search for ${item.author}`,
                "icon": "person",
                "hint": "artist"
            });
        if (item.dominant && item.dominant.length > 0)
            searches.push({
                "id": "color",
                "label": "Match its colour",
                "icon": "palette",
                "hint": item.dominant,
                "swatch": item.dominant
            });
        if (sized) {
            const shape = root._aspectLabel(item.w, item.h);
            if (shape.length > 0)
                searches.push({
                    "id": "shape",
                    "label": "Match its shape",
                    "icon": "aspect_ratio",
                    "hint": shape
                });
            searches.push({
                "id": "size",
                "label": "Match its size",
                "icon": "photo_size_select_large",
                "hint": `${item.w}×${item.h}`
            });
        }
        if (item.source && item.kind)
            searches.push({
                "id": "kindhere",
                "label": `More ${item.kind}s from ${where}`,
                "icon": "category",
                "hint": "source + kind"
            });
        if (item.family === "video" && item.source)
            searches.push({
                "id": "morevideo",
                "label": `More video from ${where}`,
                "icon": "movie",
                "hint": "moving only"
            });
        if (searches.length > 0) {
            out.push({
                "id": "sep-search",
                "separator": true
            });
            for (const search of searches)
                out.push(search);
        }
        return out;
    }

    /// Whether the site a picture came from can be asked for more like it.
    ///
    /// The daemon's ladder needs something to search WITH: wallhaven has a
    /// real "similar" of its own, everywhere else is asked for the picture's
    /// most distinctive tags or the words in its title. A local file has no
    /// site at all, and a row with neither tags nor a title would send the
    /// ladder off with nothing and come back "nothing".
    function _canAskSite(item) {
        if (!item || !item.source || item.source === "local")
            return false;
        if (item.source === "wallhaven")
            return true;
        return (item.tags || []).length > 0 || (item.title || "").length > 3;
    }

    /// The aspect as people write it — `16:9`, never `1.7778`.
    ///
    /// Reduced by GCD, and the decimal kept when the reduction is uglier than
    /// it is: `2367:3308` is not a shape anybody names. Same rule as the
    /// daemon's `util::aspect_label`, and `ratio:` matches within 0.05 either
    /// way, so both spellings find the same pictures.
    function _aspectLabel(w, h) {
        if (!(w > 0) || !(h > 0))
            return "";
        let a = Math.round(w);
        let b = Math.round(h);
        while (b > 0) {
            const t = a % b;
            a = b;
            b = t;
        }
        const rw = Math.round(w / a);
        const rh = Math.round(h / a);
        return rw <= 40 && rh <= 40 ? `${rw}:${rh}` : (w / h).toFixed(2);
    }

    /// A value with a space in it has to be quoted or the bar reads it as two
    /// clauses — `author:Studio Ghibli` searches for `author:studio` and the
    /// word "ghibli".
    function _quoted(value) {
        const text = String(value || "");
        return text.indexOf(" ") >= 0 ? `"${text}"` : text;
    }

    /*
     * ENGINES THAT TAKE A PICTURE BY URL.
     *
     * Opened in the browser rather than answered inside quarry: this is the
     * second opinion, and reading one means reading its page. Each is good at
     * something different — Lens at places and objects, TinEye at finding the
     * oldest copy, SauceNAO and IQDB at drawn art.
     *
     * Empty for a row that is only on this disk. All six need a URL they can
     * fetch, and there is no point offering a link that opens an error.
     */
    function pictureSearchEngines(item) {
        if (!item)
            return [];
        // A video's file is not a picture; its poster is the only thing worth
        // sending. A model has no flat original either.
        const still = item.family !== "video" && item.family !== "model";
        const url = [still ? item.url : "", item.sample, item.thumb].find(u => u && String(u).indexOf("http") === 0) || "";
        if (url.length === 0)
            return [];
        const e = encodeURIComponent(url);
        return [
            {
                "id": "yandex",
                "label": "Yandex",
                "icon": "travel_explore",
                "hint": "the open web",
                "url": `https://yandex.com/images/search?rpt=imageview&url=${e}`
            },
            {
                "id": "lens",
                "label": "Google Lens",
                "icon": "center_focus_strong",
                "hint": "places and objects",
                "url": `https://lens.google.com/uploadbyurl?url=${e}`
            },
            {
                "id": "bing",
                "label": "Bing",
                "icon": "search",
                "hint": "visual search",
                "url": `https://www.bing.com/images/search?q=imgurl:${e}&view=detailv2&iss=sbi`
            },
            {
                "id": "tineye",
                "label": "TinEye",
                "icon": "history",
                "hint": "the oldest copy",
                "url": `https://tineye.com/search?url=${e}`
            },
            {
                "id": "saucenao",
                "label": "SauceNAO",
                "icon": "draw",
                "hint": "drawn art",
                "url": `https://saucenao.com/search.php?url=${e}`
            },
            {
                "id": "iqdb",
                "label": "IQDB",
                "icon": "collections",
                "hint": "boorus",
                "url": `https://iqdb.org/?url=${e}`
            },
            {
                "id": "ascii2d",
                "label": "ascii2d",
                "icon": "brush",
                "hint": "illustrations, Pixiv and X",
                "url": `https://ascii2d.net/search/url/${e}`
            },
            {
                "id": "tracemoe",
                "label": "trace.moe",
                "icon": "movie",
                "hint": "which anime, which episode",
                "url": `https://trace.moe/?url=${e}`
            }
        ];
    }

    function findSimilar(item, fromHistory, method) {
        if (!item)
            return;
        const how = method || "all";
        // A separator row is not an action; the menus filter these out, and
        // this is the belt to that pair of braces.
        if (how.indexOf("sep-") === 0)
            return;
        // The searches the bar can say are just that: a query, with its own
        // history step and its own Back.
        if (["tags", "album", "author", "color", "shape", "size", "kindhere", "morevideo"].indexOf(how) >= 0) {
            let q = "";
            if (how === "tags") {
                q = (item.tags || []).filter(t => t && t.indexOf(":") < 0).slice(0, 2)
                    .map(t => `tag:${String(t).replace(/\s+/g, "_")}`).join(" ");
            } else if (how === "album") {
                const tag = (item.tags || []).find(t => String(t).indexOf("album:") === 0);
                q = tag ? `tag:${tag}` : "";
            } else if (how === "author") {
                q = `author:${root._quoted(item.author)}`;
            } else if (how === "color") {
                q = `color:${item.dominant} dist<20`;
            } else if (how === "shape") {
                // `ratio:` matches within 0.05, so this is "the same shape",
                // not "the same two numbers".
                q = `ratio:${root._aspectLabel(item.w, item.h)}`;
            } else if (how === "size") {
                q = `w:${item.w} h:${item.h}`;
            } else if (how === "kindhere") {
                q = `source:${item.source} kind:${item.kind}`;
            } else {
                q = `source:${item.source} video`;
            }
            if (q.length > 0)
                root.query = q;
            else
                Toast.show(how === "tags" ? "This picture has no tags to search by" : "Nothing to search by");
            return;
        }
        if (!Client.connected) {
            // Otherwise this menu action did nothing at all — no daemon, no
            // toast, just a click that appeared to be ignored.
            Toast.error("Can't compare — start quarryd first");
            return;
        }
        /*
         * ONLY THE LATEST QUESTION MAY ANSWER.
         *
         * The site and the web take seconds. By the time they answer you may
         * have gone Back, typed a search or asked about another picture — and
         * applying the stale answer then replaced where you had gone with a
         * "Like …" you had already left. Remember what the screen was when
         * this was asked; an answer for anything else is dropped.
         */
        const generation = ++root._similarGeneration;
        const askedQuery = root.query;
        const askedSimilar = root.similarTo;
        root.findingSimilar = true;
        Toast.show(how === "look" ? "Looking through your catalogue…"
            : how === "dupes" ? "Looking for the same file again…"
            : how === "web" ? "Asking the web for pictures like this…"
            : how === "bigger" ? "Looking for a bigger copy…"
            : how === "sites" ? "Asking where else this picture is…"
            : how === "native" ? `Asking ${item.source} for more like this…`
            : `Looking here, on ${item.source} and on the web…`);
        /*
         * `maxDistance` is what "exact" means.
         *
         * A 64-bit perceptual hash calls a re-encode, a resize and a light
         * crop the same picture at 12 — which is right for "looks like this"
         * and much too loose for "is this one I already have". 2 is the same
         * file again.
         */
        const distance = how === "dupes" ? 2 : 12;
        // `web` too, so a daemon that predates `method` still answers "all".
        Client.call("similar", { "id": item.id, "limit": 300, "maxDistance": distance, "method": how, "web": how !== "look" && how !== "dupes" },
            function (err, payload) {
                if (generation !== root._similarGeneration)
                    return;
                root.findingSimilar = false;
                if (root.query !== askedQuery || root.similarTo !== askedSimilar)
                    return;
                if (err || !payload) {
                    // A hash that does not exist yet is the common case, and it
                    // is not an error the user caused — say what it means.
                    Toast.error(String(err) === "this item has no perceptual hash yet"
                        ? "Nothing to compare yet — open it once so its picture is measured"
                        : `Could not look: ${err}`);
                    return;
                }
                const problems = [payload.nativeError, payload.webError, payload.copiesError].filter(e => e && e.length > 0);
                if ((payload.count || 0) === 0) {
                    Toast.show(problems.length > 0 ? `Nothing alike found · ${problems.join(" · ")}` : "Nothing else looks like that");
                    return;
                }
                const web = payload.web || 0;
                const native = payload.native || 0;
                const copies = payload.copies || 0;
                const local = Math.max(0, (payload.count || 0) - web - native - copies);
                const parts = [];
                if (how === "all" || how === "look")
                    parts.push(`${local} in your catalogue`);
                if (how === "dupes")
                    parts.push(local === 1 ? "1 copy of it here" : `${local} copies of it here`);
                if (how === "all" || how === "native")
                    parts.push(payload.nativeError && payload.nativeError.length > 0 ? `${item.source}: ${payload.nativeError}` : `${native} from ${payload.nativeHow || item.source}`);
                if (how === "all" || how === "web")
                    parts.push(payload.webError && payload.webError.length > 0 ? `web: ${payload.webError}` : `${web} from the web`);
                if (how === "bigger" || how === "sites")
                    parts.push(payload.copiesError && payload.copiesError.length > 0 ? `web: ${payload.copiesError}` : (how === "bigger" ? `${copies} bigger copies` : `on ${copies} pages`));
                Toast.show(parts.join(" · "), "Back", function () {
                    root.back();
                });
                // Where you were, so Back returns there — unless this IS a
                // return, in which case back() has already moved the stacks.
                if (!fromHistory)
                    root._record({ "query": root.query, "similar": root.similarTo, "method": root.similarMethod });
                root.similarTo = item;
                root.similarMethod = how;
                root._dropPages();
                root._queryId = payload.queryId;
                root.ratios = payload.ratios;
                root.count = payload.count;
                root.sort = "similar";
                root.loading = false;
                root.changed();
            });
    }

    /// Leave "more like this" and go back to the query in the bar.
    function clearSimilar() {
        if (!root.similarTo)
            return;
        root._record(root._current());
        root.similarTo = null;
        root.filterNow();
    }

    /*
     * WHERE YOU HAVE BEEN, LIKE A BROWSER.
     *
     * Following "like this" from a picture, then a tag, then "like this" again
     * is exploring — and the only way back was retyping what you had, because
     * each step replaced the last. Every step now leaves a note of where it
     * came from: a search (the words in the bar) or a "like this" (the picture
     * it was like). Back and Forward walk those notes, and the rail's mark
     * lists them, newest first, on right-click.
     *
     * Typing is one step, not one per letter: a change within a moment of the
     * previous one keeps the older note, so "sunset beach" is a single entry
     * whose back is whatever you had before you started typing.
     */
    property var history: []
    property var future: []
    readonly property bool canGoBack: root.history.length > 0
    readonly property bool canGoForward: root.future.length > 0
    property bool _navigating: false
    property string _lastQuery: ""
    property var _lastSimilar: null
    property double _lastRecordAt: 0

    function describeStep(step) {
        if (!step)
            return "";
        if (step.similar) {
            const t = step.similar.title && step.similar.title.length > 0 ? step.similar.title : (step.similar.slug || step.similar.id);
            return `Like “${t}”`;
        }
        return step.query && step.query.length > 0 ? step.query : "Everything";
    }

    function _same(a, b) {
        return a.query === b.query && (a.similar ? a.similar.id : "") === (b.similar ? b.similar.id : "");
    }

    function _record(step) {
        if (root._navigating)
            return;
        const now = Date.now();
        // Typing grows or shrinks the same words; a click on the rail replaces
        // them, and that is a step of its own however quickly it follows.
        const typing = !step.similar && !root.similarTo && root.history.length > 0
            && now - root._lastRecordAt < 1500
            && (root.query.startsWith(step.query) || step.query.startsWith(root.query));
        root._lastRecordAt = now;
        if (typing)
            return;
        const h = root.history.slice();
        if (h.length > 0 && root._same(h[h.length - 1], step))
            return;
        h.push(step);
        while (h.length > 60)
            h.shift();
        root.history = h;
        root.future = [];
    }

    /// Several changes that are one thing to the person making them — "back
    /// to Everything" clears three filters — leave one note, not three.
    function step(fn) {
        const before = root._current();
        if (root._navigating) {
            fn();
            return;
        }
        root._navigating = true;
        try {
            fn();
        } finally {
            root._navigating = false;
        }
        root._lastQuery = root.query;
        root._lastRecordAt = 0;
        if (!root._same(before, root._current()))
            root._record(before);
    }

    function _current() {
        return { "query": root.query, "similar": root.similarTo, "method": root.similarMethod };
    }

    function _go(step) {
        root._navigating = true;
        if (root.query !== step.query)
            root.query = step.query; // clears similarTo and refilters
        root._navigating = false;
        root._lastQuery = root.query;
        root._lastRecordAt = 0;
        if (step.similar) {
            root.findSimilar(step.similar, true, step.method || "all");
        } else if (root.similarTo) {
            root.similarTo = null;
            root.filterNow();
        }
    }

    /// Back `steps` notes (1 = the previous one).
    function back(steps) {
        const n = Math.max(1, steps || 1);
        if (root.history.length < n)
            return;
        const h = root.history.slice();
        const f = root.future.slice();
        f.push(root._current());
        const taken = h.splice(h.length - n, n);
        // The ones skipped over stay reachable by Forward, in order.
        for (let i = taken.length - 1; i > 0; i--)
            f.push(taken[i]);
        root.history = h;
        root.future = f;
        root._go(taken[0]);
    }

    function forward(steps) {
        const n = Math.max(1, steps || 1);
        if (root.future.length < n)
            return;
        const h = root.history.slice();
        const f = root.future.slice();
        h.push(root._current());
        const taken = f.splice(f.length - n, n).reverse();
        for (let i = 0; i < taken.length - 1; i++)
            h.push(taken[i]);
        root.history = h;
        root.future = f;
        root._go(taken[taken.length - 1]);
    }

    function exportItem(item, targetId, callback) {
        const target = Targets.byId(targetId);
        if (!item || !target) {
            if (callback)
                callback("no such target: " + targetId, null);
            return;
        }
        if (!Client.connected) {
            if (callback)
                callback("no daemon — start quarryd to export", null);
            return;
        }

        Targets.remember(targetId);

        /*
         * A video goes somewhere else, and is applied by something else.
         *
         * The recipe still travels — the daemon ignores it for video and says
         * so with `verbatim` in the reply — but the destination and the apply
         * step both change: a moving wallpaper lands in ~/Videos and is set by
         * mpvpaper, not by the still-image hook.
         */
        const isVideo = item.family === "video";

        /*
         * SOMETHING IS BEING WRITTEN, AND THE WINDOW SHOULD SAY SO.
         *
         * An export fetches the ORIGINAL — not the thumbnail the tile is made
         * of — so it is a download of the full file, and on a big picture or a
         * video that is seconds of nothing happening. There was no in-flight
         * state at all, so no surface could have shown it even if one wanted
         * to: the only sign an export was running was the toast when it
         * finished.
         *
         * A counter rather than a flag, because several can be in the air at
         * once — a batch export, or simply clicking twice.
         */
        root.exporting++;

        Client.call("export", {
            "id": item.id,
            "recipe": target.recipe,
            // The destination names the folder, not the source: a wallpaper
            // belongs under "desktop" whatever the board that hosted it called
            // the row. See the template expansion in main.rs.
            "target": target.id,
            "group": target.group || "",
            "path": isVideo
                ? `~/Videos/quarry/{group}/{slug}-{w}x{h}.{ext}`
                : `~/Pictures/quarry/{group}/{slug}-{w}x{h}.{ext}`
        }, function (err, payload) {
            root.exporting = Math.max(0, root.exporting - 1);
            if (!err && payload)
                root.lastExport = payload.path;
            // A target may finish somewhere other than the filesystem — a
            // wallpaper is not applied until something applies it. See
            // Targets.monitorTargets.
            const step = isVideo && target.applyVideo && target.applyVideo.length > 0
                ? target.applyVideo
                : target.apply;

            if (!err && payload && step && step.length > 0) {
                // A video sent to a target that only knows how to set a still
                // would be handed to a script expecting a PNG. Better to say so
                // than to run it and watch the desktop not change.
                if (isVideo && !(target.applyVideo && target.applyVideo.length > 0)) {
                    Toast.show(`Saved, but ${target.label || target.id} can't set a video`);
                } else {
                    root._applyProc.command = step.map(a => a.replace("{path}", payload.path));
                    root._applyProc.running = true;
                }
            }
            if (callback)
                callback(err, payload);
        });
    }

    // ── endless scroll ───────────────────────────────────────────────────────

    /*
     * A crawl that never answers must not end the scroll.
     *
     * `loadingMore` gates every further request, so one lost response — a
     * daemon restart, a source hanging — meant "loading more…" for ever and a
     * gallery that stopped growing. The flag is released whether or not the
     * answer arrives.
     */
    property Timer _moreWatchdog: Timer {
        id: moreWatchdog
        interval: 190000
        onTriggered: {
            if (!root.loadingMore)
                return;
            root.loadingMore = false;
            root.searchReport = "that took too long — try again";
        }
    }

    // Pages each source adds per scroll step. The scroll itself has no end.
    property int pagesPerLoad: 8

    /*
     * A SEARCH ASKS THE SITES, NOT JUST THE CATALOGUE.
     *
     * Typing "red car" ran one query against what had already been fetched
     * and not a single request to any site — measured: 652 old rows that
     * happened to match, and nothing from the web for as long as you did not
     * scroll to the very bottom. That is a filter, not a search.
     *
     * So a search starts a live round by itself: every site's own search, a
     * couple of pages each, as soon as you stop typing for a moment (Enter
     * starts it at once). Not per keystroke — "r", "re", "red" are not worth
     * forty requests each — and not with the scroll's eight pages, because
     * the first answer should be fast rather than deep. The scroll carries on
     * from there, endlessly, as before.
     */
    property int firstSearchPages: 2
    property int _moreGeneration: 0
    /// Rounds asked for the current query; the first one is kept short.
    property int _roundsThisQuery: 0

    /*
     * RESULTS AS THEY ARRIVE, NOT WHEN THE LAST SITE ANSWERS.
     *
     * The daemon files each site's rows as that site answers, but the app only
     * looked again when the whole round was over — which, across forty sites,
     * took longer than the client's thirty-second deadline, so the answer was
     * dropped as "timed out" and the wall never showed any of it (measured:
     * 3,643 rows fetched for "blue whale", 14 on screen). While the first round
     * of a new search runs, the wall is refreshed every couple of seconds; you
     * just typed, so you are at the top and nothing jumps under you.
     */
    property Timer _liveRefresh: Timer {
        id: liveRefresh
        // Four seconds, not two and a half: a refresh replaces the daemon's
        // stored result, and every page fetch still in flight is discarded
        // with it, so refreshing faster than a page arrives is self-defeating.
        interval: 4000
        repeat: true
        property int ticks: 0
        onTriggered: {
            // A search keeps refreshing for as long as it runs: its rows land
            // in the catalogue while the round is still going, and without
            // this the wall stays empty until every source has answered.
            // Scrolling stops once the screen is full, where a rebuild would
            // only move the ground under someone reading it.
            const searching = root.searching;
            const spent = searching ? ++liveRefresh.ticks > 400 : (++liveRefresh.ticks > 12 || root.count >= 300);
            if ((!root.loadingMore && !searching) || spent) {
                liveRefresh.stop();
                return;
            }
            // A daemon that says when rows land (`catalog.changed`) has
            // already grown the wall; this is for one that does not.
            if (Date.now() - root._lastChange < liveRefresh.interval)
                return;
            // Extend, not filter: this runs every four seconds while a search
            // fills the catalogue, and a rebuild moves the ground under
            // someone reading the wall — which is the whole reason `_extend`
            // exists.
            root._extend();
        }
    }
    property Timer _liveSearch: Timer {
        id: liveSearch
        interval: 450
        onTriggered: root.searchNow()
    }

    /// Ask the sites for the current query now.
    function searchNow() {
        liveSearch.stop();
        // Two characters at least: a lone letter is not a search worth forty
        // sites' time, or a catalogue full of whatever "a" finds.
        if (root.similarTo || root.fetchMode === "catalog" || (root.query || "").trim().length < 2)
            return;
        root.loadMore(root.firstSearchPages);
    }

    property Timer _moreRetry: Timer {
        id: moreRetry
        interval: 4000
        onTriggered: root.loadMore()
    }
    property bool loadingMore: false
    property bool exhausted: false
    property int pagesLoaded: 0

    /*
     * Ask for the next page, the way a browser userscript keeps appending.
     *
     * The daemon owns "where we are" per source and per query, so this is one
     * call with no cursor to track here. Rows are appended, which the masonry
     * places in O(added) — a new page costs a millisecond or two no matter how
     * far you have already scrolled.
     */
    /*
     * HOW FAR THE WALL REACHES PAST THE CATALOGUE.
     *
     *   endless  — scrolling keeps asking the sources, for as long as any of
     *              them has pages. The default: a gallery that ends while the
     *              internet has more is a gallery that stopped.
     *   search   — sources are asked only while something is typed; browsing
     *              stays inside what you already have.
     *   catalog  — never asks; the wall is exactly what the catalogue holds.
     */
    readonly property string fetchMode: Prefs.fetchMode

    function loadMore(pages) {
        if (root.loadingMore || root.exhausted || !Client.connected || root.similarTo)
            return;
        if (root.fetchMode === "catalog")
            return;
        if (root.fetchMode === "search" && root.query.trim().length === 0)
            return;
        root.loadingMore = true;
        moreWatchdog.restart();
        // An answer for an older query must not end, stall or retry this one.
        const generation = root._moreGeneration;
        // The first round of a new search is short, whoever asks for it — the
        // wall asks for a deep one the moment a result looks thin.
        const firstRound = root._roundsThisQuery === 0 && (root.query || "").trim().length > 0;
        const askPages = firstRound ? root.firstSearchPages : (pages > 0 ? pages : root.pagesPerLoad);
        root._roundsThisQuery++;
        if (firstRound) {
            liveRefresh.ticks = 0;
            liveRefresh.restart();
        }

        Client.call("more", {
            // Trimmed and single-spaced: the daemon keeps its page cursor by this
            // text, and a completion's trailing space started every site over
            // from page one.
            "q": (root.query || "").trim().replace(/\s+/g, " "),
            // No source list: the daemon uses every adapter it has, so adding
            // one makes the endless scroll deeper without touching the app.
            // Two hardcoded names meant the scroll ended when those two ran
            // out, while other sources still had pages.
            /*
             * Four pages a call, not one.
             *
             * A page is 24–50 rows before local filtering and a handful after
             * it, so one page per scroll grows the wall by less than a screen
             * and immediately asks again. The daemon fetches the pages in
             * parallel, so four cost what the slowest one costs.
             */
            "pages": askPages
        }, function (err, payload) {
            if (generation !== root._moreGeneration) {
                // Its rows are in the catalogue now; if they match what is
                // asked today, the refresh shows them. Nothing else is touched.
                if (payload && payload.added > 0)
                    root._extend();
                return;
            }
            moreWatchdog.stop();
            root.loadingMore = false;
            if (err || !payload) {
                root.searchReport = err || "could not load more";
                return;
            }

            root.pagesLoaded++;
            /*
             * No toast for a page landing.
             *
             * Endless scroll adding rows is the normal case, not news — and it
             * announced itself *while you were scrolling*, which is the worst
             * possible moment to put something over the gallery. The header
             * already carries the count and the page tally; that is where a
             * number belongs.
             */
            // Every source out of pages means the scroll is genuinely over —
            // otherwise "nothing new this time" is normal and worth retrying
            // further down.
            /*
             * Only when every source says it is done.
             *
             * A page that adds nothing is normal — duplicates, or a local
             * filter that rejected everything on it — and treating that as the
             * end stopped the scroll while sources still had pages. The end is
             * when the daemon reports every source exhausted.
             */
            // The home feed has no end: the daemon starts a finished front
            // page over after a rest, so a quiet call is asked again later.
            // Slowly, though: every site answered with nothing new, and asking
            // thirty of them again at once every few seconds is not polite.
            if (payload.endless && payload.added === 0) {
                moreRetry.interval = 30000;
                moreRetry.restart();
            }
            /*
             * THE SCROLL IS OVER ONLY WHEN EVERY SOURCE THAT WAS ASKED IS OUT
             * OF PAGES.
             *
             * This compared against a constant 3, from when there were three
             * adapters; there are 57. A query the boorus cannot express
             * legitimately exhausts twenty of them on the first round, which
             * latched `exhausted` and killed the scroll for the rest of that
             * query — measured on a search whose matches were already in the
             * catalogue. `payload.sources` is how many were actually asked, so
             * that is what the count is against.
             *
             * A SKIPPED SOURCE IS NOT AN EXHAUSTED ONE. `payload.skipped` is
             * the sources that could not express the query at all; a question
             * forty-six sources cannot ask is not the end of the answer.
             */
            else if (payload.exhausted && payload.sources > 0 && payload.exhausted.length >= payload.sources && payload.added === 0)
                root.exhausted = true;
            // Pages that failed to arrive are asked for again after a pause,
            // rather than the scroll sitting still until something moves it.
            else if (payload.added === 0 && payload.failed && payload.failed.length > 0) {
                moreRetry.interval = 4000;
                moreRetry.restart();
            }

            /*
             * A ROUND THAT ADDED NOTHING STILL GROWS THE WALL.
             *
             * `added` counts rows NEW to the catalogue, so a round that fetched
             * six hundred matches it already held reported +0 and the wall
             * never grew — "57 sources · 0 pages · +0" with the matches sitting
             * in the catalogue. The open result is a snapshot; `extend` is
             * cheap and idempotent, so every successful round asks for it.
             */
            root._extend();
        }, 180000);
    }

    // ── live search ──────────────────────────────────────────────────────────

    property bool searching: false
    /*
     * How the last "ask every source" ended — and it has to be SAID.
     *
     * This was written on every outcome and read by nothing but the CLI probe.
     * The header shows a live line while `searching` is true and then simply
     * stops showing it, so a search that failed outright looked exactly like a
     * search that finished and found nothing: the button appeared to work and
     * confirm there was nothing out there. Failures now go to a toast.
     */
    property string searchReport: ""
    onSearchReportChanged: {
        const text = root.searchReport;
        if (text.length === 0)
            return;
        const bad = text.indexOf("failed") >= 0 || text.indexOf("timed out") >= 0 || text.indexOf("too long") >= 0 || text.indexOf("could not") >= 0;
        if (bad)
            Toast.error(text);
    }

    /*
     * Crawl the sources for the current query.
     *
     * The daemon pushes down whatever each source can express — wallhaven takes
     * `atleast` and `ratios`, danbooru takes its own tag syntax — and filters
     * the rest locally. The counts come back so the UI can say what happened
     * rather than just showing more tiles.
     */
    /*
     * CRAWL THE SOURCES FOR THE CURRENT QUERY — AS DEEP AS THEY GO.
     *
     * Every enabled source when none are named: a hardcoded list of fourteen
     * meant "search every source" skipped half of them. Depth is each
     * source's `pages` setting, and 0 — the default — means UNLIMITED: that
     * source is paged, one page after another, until it says it has no more.
     * Sources run side by side; within one source pages go in order, because
     * a page past the end is a wasted request and the answer to "is there
     * more" arrives with each page.
     *
     * It stops by itself when the sources run dry, when the query changes
     * (a crawl for the old words would fill the catalogue with the wrong
     * pictures), or when `stopSearch()` is called. The wall refreshes as pages
     * land, so results appear while it runs rather than at the end.
     */
    property int searchGeneration: 0
    property int searchPages: 0
    property int searchAdded: 0
    property var searchActive: []

    function enabledSources() {
        const out = [];
        for (const pref of root.sourcePrefs)
            if (pref.enabled !== false)
                out.push(pref.id);
        return out;
    }

    function stopSearch() {
        root.searchGeneration++;
        root.searching = false;
        root.searchActive = [];
        searchWatchdog.stop();
    }

    function searchSources(sources) {
        if (!Client.connected)
            return;
        const list = sources && sources.length > 0 ? sources : root.enabledSources();
        if (list.length === 0)
            return;
        const generation = ++root.searchGeneration;
        const query = root.query;
        root.searching = true;
        root.searchReport = "";
        root.searchPages = 0;
        root.searchAdded = 0;
        root.searchActive = list.slice();
        searchWatchdog.restart();
        liveRefresh.ticks = 0;
        liveRefresh.restart();

        let fetched = 0;
        let quiet = 0;

        /*
         * One round asks every source at once and files each page as it lands;
         * the app used to crawl source by source, page after page, so nothing
         * showed until a slow host finished and the counters sat at zero.
         */
        const round = function () {
            if (generation !== root.searchGeneration || root.query !== query)
                return;
            // Three pages a round, not eight: a round answers only when its
            // slowest host does. Measured: eight pages over five sources, 40s.
            Client.call("more", { "q": query, "pages": 3, "sources": list }, function (err, payload) {
                if (generation !== root.searchGeneration)
                    return;
                searchWatchdog.restart();
                if (err || !payload) {
                    root.searching = false;
                    root.searchActive = [];
                    searchWatchdog.stop();
                    root.searchReport = `search failed: ${err || "no answer"}`;
                    return;
                }

                root.searchPages += payload.pages || 0;
                root.searchAdded += payload.added || 0;
                fetched += payload.fetched || 0;
                quiet = (payload.added || 0) > 0 ? 0 : quiet + 1;
                // Sources still worth asking: the ones that have not run out.
                const done = (payload.exhausted || []).concat(payload.failed || []);
                root.searchActive = list.filter(s => done.indexOf(s) < 0);
                if ((payload.added || 0) > 0)
                    root._extend();

                // Three rounds with nothing new is the end of what these
                // sources have for these words; `endless` home feeds never are.
                const spent = quiet >= 3 || root.searchActive.length === 0;
                if (spent && !payload.endless) {
                    root.searching = false;
                    root.searchActive = [];
                    searchWatchdog.stop();
                    root.searchReport = `+${root.searchAdded} new of ${fetched} fetched`;
                    root._extend();
                    return;
                }
                Qt.callLater(round);
            }, 180000);
        };

        round();
    }

    // The perf harness: pretend the fixture is `times` larger. Costs one index
    // and one ratio per item and nothing more.
    function multiply(times) {
        root.repeat = Math.max(1, times);
        root.filter();
    }

    /*
     * A RELOAD DOES NOT FORGET WHAT YOU WERE LOOKING AT.
     *
     * The query is the whole filter state (see above), and it lived only in
     * memory — so every reload, and every hot reload of a QML edit, came back
     * to an empty search and every chosen filter gone. It is kept in the
     * settings file now and put back on start, unless `--query` asked for
     * something else. A restored query filters the catalogue but does not set
     * off a live search of every site: a reload is not a new question.
     */
    property bool _queryRestored: false
    property bool _restoringQuery: false

    function _restoreQuery() {
        if (!Prefs.loaded) {
            restoreWhenLoaded.enabled = true;
            return;
        }
        restoreWhenLoaded.enabled = false;
        const saved = String(Prefs.lastQuery || "");
        if (saved.length > 0 && root.query.length === 0) {
            root._restoringQuery = true;
            root.query = saved;
            root._restoringQuery = false;
        }
        root._queryRestored = true;
    }

    property Connections _restoreWhenLoaded: Connections {
        id: restoreWhenLoaded

        enabled: false
        target: Prefs

        function onLoadedChanged() {
            root._restoreQuery();
        }
    }

    property Timer _saveQuery: Timer {
        id: saveQuery

        interval: 600
        onTriggered: {
            if (root._queryRestored && Prefs.lastQuery !== root.query)
                Prefs.lastQuery = root.query;
        }
    }

    // A new query is a new endless scroll, so the exhausted flag resets with it.
    onQueryChanged: {
        saveQuery.restart();
        rememberQuery.restart();
        root._record({ "query": root._lastQuery, "similar": root.similarTo });
        root._lastQuery = root.query;
        root.exhausted = false;
        root.similarTo = null;
        if (root.searching)
            root.stopSearch();
        root.dropThumbRequests();
        root.filter();
        // A new query is a new live search: release the old one's hold on
        // `loadingMore`, and ask the sites once typing settles.
        root._moreGeneration++;
        root._roundsThisQuery = 0;
        liveRefresh.stop();
        root.loadingMore = false;
        moreWatchdog.stop();
        moreRetry.stop();
        if ((root.query || "").trim().length > 0 && !root._restoringQuery)
            liveSearch.restart();
        else
            liveSearch.stop();
    }
    onKindChanged: root.filter()
    onSourceChanged: root.filter()
    onFamilyChanged: root.filter()

    Component.onCompleted: {
        // The fixture is read regardless: it is the offline fallback, and it is
        // what fills the filter chips before the first query returns.
        root.load();

        // See _refreshOnFirstUse: the socket is usually already up by the time
        // this singleton exists, so neither `ready` nor `connectedChanged` will
        // ever fire for us and nothing else would ask.
        root._refreshOnFirstUse();

        // A desktop action launches `quarry --query kind:wallpaper`, which for
        // a cold start arrives here rather than over IPC.
        const startup = Quickshell.env("QUARRY_QUERY");
        // Nothing asked for on the command line: come back to what was being
        // searched before the reload, once the stored settings are in hand.
        if (!startup || startup.length === 0)
            root._restoreQuery();
        if (startup && startup.length > 0) {
            // Choose the slot the flag is describing, so the dock, the aspect
            // filter and the primary action all agree with the results. Falls
            // back to the plain query when the flag names no slot we know.
            const slot = Slots.matchQuery(startup);
            if (slot)
                Slots.choose(slot);
            else
                root.query = startup;
        }
    }

    /*
     * A crawl that never answers must not pin the spinner forever.
     *
     * The daemon can be killed mid-search, and a response that never arrives
     * leaves `searching` true with no way back — the UI would look busy for the
     * rest of the session over a socket that closed.
     */
    property Timer _searchWatchdog: Timer {
        id: searchWatchdog
        // A round across forty sources can take a minute; this is for a daemon
        // that stopped answering, not for a slow host.
        interval: 120000
        onTriggered: {
            if (!root.searching)
                return;
            root.searching = false;
            root.searchReport = "search timed out";
        }
    }

    property var _clientHooks: Connections {
        target: Client

        function onReady() {
            root.loading = false;
            root.filter();
            root.refreshFacets();
            root.refreshCollections();
        }

        function onConnectedChanged() {
            if (!Client.connected) {
                root._queryId = 0;
                root.filter();      // fall back to the fixture
            }
        }

        function onReconnected() {
            // Anything that failed while the socket was down is worth retrying,
            // and the tiles need telling that it is worth asking again.
            root.thumbRetries = ({});
            root._thumbPending = ({});
            root._thumbCalls = ({});
            // Pages too: a request that was in flight when the socket died is
            // marked "already asked" forever, and every tile in it stays empty.
            root._pendingPages = ({});
            root._pageSentAt = ({});
            root.pageEpoch++;
            /*
             * A NEW DAEMON HAS NO MEMORY OF OUR QUERY.
             *
             * The stored result died with the old process, so the id we hold
             * belongs to nothing. Clearing the marks is not enough: unless
             * something asks for a page, nothing discovers it, and the wall
             * sits at "0 items" against a daemon with a full catalogue — which
             * is exactly what a restarted daemon looked like from the app.
             */
            root._queryId = 0;
            root._pagedQuery = "";
            root.filter();
        }

        function onEvent(name, payload) {
            /*
             * The crawl added rows. GROW the open result rather than running
             * the query again: `filter()` renumbers every offset, so the tile
             * under the pointer became a different picture mid-scroll and the
             * click that followed opened it. `_extend` falls back to `filter()`
             * on its own when the result it would grow has gone.
             */
            if (name === "catalog.changed") {
                root._lastChange = Date.now();
                root.queueExtend();
            }
            /*
             * The other application changed a board.
             *
             * quarry and quarry-board share one catalogue and one daemon, so
             * "add to a board" in the browser has to appear on the canvas that
             * is already open beside it. Without this the board only found out
             * when someone pressed Ctrl+R, which is a thing nobody thinks to do
             * because nothing on screen says anything is stale.
             */
            if (name === "board.changed") {
                root.refreshBoards();
                if (payload && payload.name === root.board)
                    root.refreshBoardItems();
            }
        }
    }
}
