pragma Singleton
import QtQuick
import QtCore
import Quickshell
import Quickshell.Io
import Qt.labs.folderlistmodel
import qs.modules.common

/*
 * LENSES — per-site ways of LOOKING at results.
 *
 * A source adapter fetches rows; a lens is a screen built for one site, with
 * its own navigation and its own look. 4chan is the case that forced it: a
 * board, a catalogue and a thread of replies are not a masonry wall, and no
 * amount of tile tuning makes them one.
 *
 * This replaces what quarry called an "extension". Same safety properties —
 * manifest read before any code loads, instances created on enable, a user
 * directory overriding a built-in of the same id, a failure contained to the
 * lens that caused it — plus the two things a lens has that an extension did
 * not: the SOURCES it applies to, and SKINS.
 *
 * WHAT A LENS SHIPS
 *
 *   <dir>/lens.json          read on its own, before a line of QML loads
 *   <dir>/<entry>            the lens object: a `Lens` (modules/lens/Lens.qml)
 *   <dir>/<skin entry>…      one component per skin
 *
 *   { "id": "fourchan", "name": "4chan", "version": "1.0",
 *     "description": "…", "author": "…", "icon": "forum",
 *     "entry": "Main.qml",
 *     "sources": ["4chan"],        // or ["*"] for any; [] = never auto-opened
 *     "rail": true,                // offer a row in the navigation rail
 *     "skins": [ { "id": "default", "name": "Quarry", "entry": "skins/Default.qml" } ],
 *     "defaultSkin": "default",
 *     "enabledByDefault": true }
 *
 * The lens holds the STATE and does the fetching; a skin only draws. Switching
 * skin destroys one component and builds another — the lens, and everything you
 * had navigated to, survives it. That is why a skin may look nothing like the
 * rest of the app and still be cheap.
 *
 * SEARCH PATHS, in priority order (last wins on an id collision):
 *
 *   <config>/modules/lens/builtin/   shipped with quarry
 *   <config>/extensions/             legacy extension packs, still honoured
 *   ~/.local/share/quarry/extensions/
 *   ~/.local/share/quarry/lenses/    user-installed
 */
QtObject {
    id: root

    readonly property string home: {
        const u = StandardPaths.writableLocation(StandardPaths.HomeLocation).toString();
        return u.replace(/^file:\/\//, "");
    }

    // Resolved relative to services/, so a checkout and /usr/share behave the
    // same way — nothing here special-cases being installed.
    readonly property var searchPaths: [
        {
            "url": Qt.resolvedUrl("../modules/lens/builtin"),
            "origin": "builtin",
            "manifest": "lens.json"
        },
        {
            "url": Qt.resolvedUrl("../extensions"),
            "origin": "builtin",
            "manifest": "manifest.json"
        },
        {
            "url": "file://" + root.home + "/.local/share/quarry/extensions",
            "origin": "user",
            "manifest": "manifest.json"
        },
        {
            "url": "file://" + root.home + "/.local/share/quarry/lenses",
            "origin": "user",
            "manifest": "lens.json"
        }
    ]

    // [{ id, name, description, version, author, icon, entry, sources, skins,
    //    defaultSkin, rail, legacy, providesMocks, enabledByDefault,
    //    origin, dir, instance, error }]
    property var catalog: []
    property bool scanning: false

    signal catalogUpdated
    signal lensError(string id, string message)
    signal opened(string id)
    signal closed(string id)

    readonly property int count: root.catalog.length
    readonly property int enabledCount: root.catalog.filter(e => root.isEnabled(e.id)).length
    readonly property var live: root.catalog.filter(e => e.instance !== null && e.instance !== undefined)

    // ── what is on screen ────────────────────────────────────────────────────
    /// The lens currently taking over the content area, "" for none.
    property string activeId: ""
    /// Handed to the lens on open: which row or source sent you here.
    property var activeContext: null

    /*
     * THE OPEN SKIN DRAWS ITS OWN HEADER — see LensSkin.wantsChrome.
     *
     * Written by LensHost, which is the only thing holding the skin. It exists
     * because quarry's chrome and a lens's chrome were both on screen: two
     * titles both reading "Morse", two search fields (one of which searched the
     * catalogue, not the chats), two close buttons and a "Fetch more" that
     * fetched nothing — about 130px of duplicated bar above the first row.
     */
    property bool skinDrawsChrome: false

    readonly property var activeEntry: root.activeId.length > 0 ? root.find(root.activeId) : null
    readonly property var activeLens: root.activeEntry ? root.activeEntry.instance : null

    /*
     * Open a lens over the gallery. A lens that is listed but switched off is
     * switched on by opening it — you asked for it by name.
     */
    function open(id, context) {
        const entry = root.find(id);
        if (!entry)
            return false;
        if (!root.isEnabled(id))
            root.setEnabled(id, true);
        else
            root._instantiate(id);
        if (!entry.instance && !root.find(id).instance)
            return false;
        root.activeContext = context || null;
        root.activeId = id;
        const live = root.find(id).instance;
        if (live)
            live.open(root.activeContext);
        root.opened(id);
        return true;
    }

    /// The lens that claims this source, if one is enabled. `openFor` is how a
    /// result row reaches its site's own reader.
    function lensForSource(sourceId) {
        const wanted = String(sourceId || "").toLowerCase();
        for (let i = 0; i < root.catalog.length; i++) {
            const entry = root.catalog[i];
            if (!root.isEnabled(entry.id))
                continue;
            const sources = entry.sources || [];
            for (let j = 0; j < sources.length; j++) {
                const claim = String(sources[j]).toLowerCase();
                if (claim === "*" || claim === wanted)
                    return entry;
            }
        }
        return null;
    }

    function openFor(sourceId, context) {
        const entry = root.lensForSource(sourceId);
        return entry ? root.open(entry.id, context) : false;
    }

    function close() {
        if (root.activeId.length === 0)
            return;
        const was = root.activeId;
        const entry = root.find(was);
        if (entry && entry.instance)
            entry.instance.close();
        root.activeId = "";
        root.activeContext = null;
        root.closed(was);
    }

    /// Rail rows, for lenses that asked for one and are switched on.
    readonly property var railEntries: root.catalog.filter(e => e.rail === true && root.isEnabled(e.id))

    // ── skins ────────────────────────────────────────────────────────────────
    function skinsOf(id) {
        const entry = root.find(id);
        return entry && entry.skins.length > 0 ? entry.skins : [];
    }

    /// The chosen skin id: what you picked, else the manifest's default, else
    /// the first one declared. Never empty for a lens that ships a skin.
    function skinOf(id) {
        const entry = root.find(id);
        if (!entry || entry.skins.length === 0)
            return "";
        const picked = root._skinMap()[id];
        if (picked && entry.skins.some(s => s.id === picked))
            return picked;
        if (entry.defaultSkin && entry.skins.some(s => s.id === entry.defaultSkin))
            return entry.defaultSkin;
        return entry.skins[0].id;
    }

    function setSkin(id, skinId) {
        const map = root._skinMap();
        map[id] = String(skinId);
        store.skinJson = JSON.stringify(map);
        root._persist();
        const entry = root.find(id);
        if (entry && entry.instance)
            entry.instance.skinId = root.skinOf(id);
        root.catalogUpdated();
    }

    /// The URL a host loads to draw a lens. "" when the lens ships no skin, in
    /// which case the lens draws itself.
    function skinUrl(id) {
        const entry = root.find(id);
        if (!entry)
            return "";
        const wanted = root.skinOf(id);
        for (let i = 0; i < entry.skins.length; i++)
            if (entry.skins[i].id === wanted)
                return "file://" + entry.dir + "/" + entry.skins[i].entry;
        return "";
    }

    /// The open lens's own navigation, for the rail. Empty when none.
    readonly property var activeNav: root.activeLens && root.activeLens.navItems ? root.activeLens.navItems : []
    readonly property var activeTiles: root.activeLens && root.activeLens.navTiles ? root.activeLens.navTiles : []

    function navPick(id) {
        if (root.activeLens)
            root.activeLens.navPicked(id);
    }

    readonly property string activeSkinUrl: root.activeId.length > 0 ? root.skinUrl(root.activeId) : ""

    // ── per-lens settings ────────────────────────────────────────────────────
    /*
     * A lens gets a persisted settings object for free, so it does not have to
     * open a file of its own. Small things only — what you switched on, where
     * you were — not a cache.
     */
    function settingsOf(id) {
        try {
            const all = JSON.parse(store.settingsJson);
            const mine = all && all[id];
            return (mine && typeof mine === "object") ? mine : ({});
        } catch (e) {
            return ({});
        }
    }

    function setSettings(id, values) {
        let all = {};
        try {
            const parsed = JSON.parse(store.settingsJson);
            if (parsed && typeof parsed === "object")
                all = parsed;
        } catch (e) {}
        all[id] = values || {};
        store.settingsJson = JSON.stringify(all);
        root._persist();
        const entry = root.find(id);
        if (entry && entry.instance)
            entry.instance.settings = all[id];
    }

    function _skinMap() {
        try {
            const m = JSON.parse(store.skinJson);
            return (m && typeof m === "object") ? m : ({});
        } catch (e) {
            return ({});
        }
    }

    // ── contributions (unchanged from the extension API) ─────────────────────
    /*
     * Every lens's own rows, plus the one every lens gets for free: the site it
     * is a lens ON. It is appended here rather than written into each lens so
     * that a lens cannot forget it, and so the wording is the same everywhere.
     */
    /*
     * THE ROWS BELONG TO THE LENS ON SCREEN — ONLY THAT ONE.
     *
     * `_collectFrom` walks every INSTANTIATED lens, which is right for mock
     * packs (a pack is a pack wherever it came from) and wrong for verbs. Open
     * 4chan, then Pornhub, then Reddit, and the overflow under the heading
     * "REDDIT" listed all three lenses' rows in one list: "Refresh · boards"
     * and "Watch in its own window" beside Reddit's own, with "Copy the link"
     * and "Open on the site" appearing twice because two lenses each offer one.
     * Pressing one of them acted on a lens that was not on screen.
     */
    /*
     * A PACK THAT IS NOT A SITE READER HAS NO SCREEN TO BE ON.
     *
     * The filter below is right for a lens: 4chan's verbs have no meaning while
     * you are looking at Reddit. It was wrong for everything else. An extension
     * that claims no source and ships no skin — the slideshow, a pack of
     * in-context mocks — is never the "active lens", so its rows were collected
     * and then dropped, every time. Its own file says it "contributes an
     * action, an overlay and a target-driven side effect"; two of those three
     * reached nothing.
     *
     * So a SCOPED row (a lens on a site) shows only on that lens; an unscoped
     * one always shows.
     */
    readonly property var menuItems: {
        const active = root.activeId;
        const rows = root._collectFrom("menuItems", "item").filter((r) => {
            return r.scoped ? r.lensId === active : true;
        });
        /*
         * …unless the lens already offers it.
         *
         * This row is appended so a lens cannot forget it and so the wording is
         * the same everywhere. 4chan writes its own anyway, with a hint saying
         * WHICH page — so the menu listed "Open the real site here" twice, one
         * of them less useful than the other.
         */
        const lens = root.activeLens;
        const already = rows.some(r => String(r.item.label || "") === "Open the real site here");
        if (lens && !already && String(lens.siteUrl || "").length > 0)
            rows.push({
                "lensId": lens.lensId,
                "lensName": lens.name,
                "extensionId": lens.lensId,
                "extensionName": lens.name,
                "scoped": true,
                "item": {
                    "label": "Open the real site here",
                    "icon": "public",
                    "hint": "in the app",
                    "action": () => lens.showSite()
                }
            });
        return rows;
    }
    readonly property var contextMocks: root._collectFrom("contextMocks", "mock")
    /// Link openers from every enabled pack — see `openers` on Lens; Sys.open
    /// asks these before xdg-open.
    readonly property var openers: root._collectFrom("openers", "opener")

    /// Every lens that ships at least one in-context mock, on or off — the
    /// layout menu has to list a pack you have not switched on yet.
    readonly property var mockPacks: root.catalog.filter(e => e.providesMocks === true)

    function _collectFrom(property, key) {
        const out = [];
        const list = root.live;
        for (let i = 0; i < list.length; i++) {
            const items = list[i].instance[property] || [];
            // A lens ON something: it claims sources, or it ships a look.
            const scoped = (list[i].sources || []).length > 0 || (list[i].skins || []).length > 0;
            for (let j = 0; j < items.length; j++) {
                const row = {
                    "lensId": list[i].id,
                    "lensName": list[i].name,
                    "scoped": scoped,
                    // Kept under the old names too: the layout menu and the IPC
                    // read `extensionId`, and those files are not ours.
                    "extensionId": list[i].id,
                    "extensionName": list[i].name
                };
                row[key] = items[j];
                out.push(row);
            }
        }
        return out;
    }

    // ── enabled state ────────────────────────────────────────────────────────
    function _enabledMap() {
        try {
            const m = JSON.parse(store.enabledJson);
            return (m && typeof m === "object") ? m : ({});
        } catch (e) {
            return ({});
        }
    }

    /*
     * AN ADULT LENS IS NOT A LENS WHILE ADULT CONTENT IS OFF.
     *
     * The manifest has carried `adult` since the first lens shipped and nothing
     * ever read it: the pornhub lens was listed, enablable and openable with the
     * adult switch off, and it would happily fetch a page and draw it — which is
     * the same hole the query-string `-nsfw` was, in a different room.
     *
     * Checked here rather than at the call sites because `isEnabled` is the one
     * thing the rail, the host, the settings list and the keyboard shortcuts all
     * ask. A stored `true` from when the switch was on is left alone in the file
     * and simply not honoured, so turning the switch back on restores exactly
     * what was enabled before rather than making you set it up again.
     */
    function isAdult(id) {
        for (let i = 0; i < root.catalog.length; i++)
            if (root.catalog[i].id === id)
                return root.catalog[i].adult === true;
        return false;
    }

    function isEnabled(id) {
        if (!Prefs.showNsfw && root.isAdult(id))
            return false;

        const map = root._enabledMap();
        if (map[id] !== undefined)
            return map[id] === true;
        // Never toggled — fall back to what the manifest asked for.
        for (let i = 0; i < root.catalog.length; i++)
            if (root.catalog[i].id === id)
                return root.catalog[i].enabledByDefault === true;
        return false;
    }

    function setEnabled(id, on) {
        // Refused rather than stored: a switch that silently remembers "on" for
        // something it will not turn on is a switch that lies twice.
        if (on && !Prefs.showNsfw && root.isAdult(id))
            return;

        const map = root._enabledMap();
        map[id] = !!on;
        store.enabledJson = JSON.stringify(map);
        root._persist();
        if (on) {
            root._instantiate(id);
        } else {
            if (root.activeId === id)
                root.close();
            root._destroy(id);
        }
        root.catalogUpdated();
    }

    function toggle(id) {
        root.setEnabled(id, !root.isEnabled(id));
    }

    function find(id) {
        for (let i = 0; i < root.catalog.length; i++)
            if (root.catalog[i].id === id)
                return root.catalog[i];
        return null;
    }

    function instanceOf(id) {
        const entry = root.find(id);
        return entry ? entry.instance : null;
    }

    // ── scanning ────────────────────────────────────────────────────────────
    /*
     * A FolderListModel is asynchronous in two ways that both bite here: it
     * stays READY WITH ITS OLD CONTENTS for a moment after `folder` is
     * assigned, and a folder that does not exist falls back to the PROCESS'S
     * WORKING DIRECTORY rather than reporting empty. Measured, not assumed:
     * the first version of this scanned eleven directories of the checkout and
     * found no lenses at all.
     *
     * So the scan is not a sequence of steps, it is a settling process. Every
     * Ready collects again, entries outside the search path are discarded, each
     * directory is read exactly once, and the catalogue is published when
     * nothing has arrived for a moment. Running it twice costs nothing.
     */
    property var _pending: []
    property var _found: []
    property var _seen: ({})

    function rescan() {
        root.scanning = true;
        root._pending = [];
        root._found = [];
        root._seen = ({});
        for (let i = 0; i < root._models.length; i++) {
            const scanner = root._models[i];
            if (!scanner)
                continue;
            const wanted = String(root.searchPaths[i].url);
            if (String(scanner.model.folder) === wanted)
                root._collect(i);      // already there; no status change is coming
            else
                scanner.model.folder = root.searchPaths[i].url;
        }
        settle.restart();
    }

    function _collect(index) {
        const scanner = root._models[index];
        if (!scanner || scanner.model.status !== FolderListModel.Ready)
            return;
        const spec = root.searchPaths[index];
        const prefix = String(spec.url).replace(/^file:\/\//, "");
        for (let i = 0; i < scanner.model.count; i++) {
            const dir = String(scanner.model.get(i, "filePath"));
            if (dir.indexOf(prefix + "/") !== 0)
                continue;                      // the working-directory fallback
            if (root._seen[dir])
                continue;
            root._seen[dir] = true;
            root._pending.push(dir);
            root._readManifest(dir, spec, index);
        }
        settle.restart();
    }

    function _readManifest(dir, spec, priority) {
        const xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return;
            const text = xhr.responseText || "";
            let manifest = null;
            if (text.length) {
                try {
                    manifest = JSON.parse(text);
                } catch (e) {
                    root.lensError(dir, `${spec.manifest} is not valid JSON`);
                }
            }
            if (manifest && manifest.id)
                root._found.push(root._entryFrom(manifest, dir, spec, priority));
            // Dropped from pending whether or not it parsed, or the scan hangs.
            const at = root._pending.indexOf(dir);
            if (at >= 0)
                root._pending.splice(at, 1);
            settle.restart();
        };
        xhr.open("GET", "file://" + dir + "/" + spec.manifest);
        xhr.send();
    }

    function _entryFrom(manifest, dir, spec, priority) {
        const legacy = spec.manifest !== "lens.json";
        const skins = [];
        const declared = Array.isArray(manifest.skins) ? manifest.skins : [];
        for (let i = 0; i < declared.length; i++) {
            const skin = declared[i];
            if (!skin || !skin.id || !skin.entry)
                continue;
            skins.push({
                "id": String(skin.id),
                "name": String(skin.name || skin.id),
                "description": String(skin.description || ""),
                "entry": String(skin.entry)
            });
        }
        return {
            "id": String(manifest.id),
            "name": String(manifest.name || manifest.id),
            "description": String(manifest.description || ""),
            "version": String(manifest.version || "0"),
            "author": String(manifest.author || ""),
            "icon": String(manifest.icon || (legacy ? "extension" : "lens_blur")),
            // A picture beside the lens (its own app-style tile); `icon` stays the fallback.
            "iconImage": manifest.iconImage ? "file://" + dir + "/" + String(manifest.iconImage) : "",
            "entry": String(manifest.entry || "Main.qml"),
            "sources": Array.isArray(manifest.sources) ? manifest.sources.map(String) : [],
            "skins": skins,
            "defaultSkin": String(manifest.defaultSkin || (skins.length > 0 ? skins[0].id : "")),
            "rail": manifest.rail === true,
            /*
             * DECLARED ADULT BY ITS AUTHOR.
             *
             * Read here so quarry's own blur and hide settings have something
             * to act on for a whole lens, the way a board's `ws_board` flag
             * works inside one. A key a manifest is told to write and the
             * loader drops is a trap: it looks set and does nothing.
             */
            "adult": manifest.adult === true,
            "legacy": legacy,
            // Declared, not discovered: the layout menu lists a mock pack you
            // have not switched on, and switching it on is what loads it.
            "providesMocks": manifest.providesMocks === true,
            "enabledByDefault": manifest.enabledByDefault === true,
            "origin": spec.origin,
            "priority": priority,
            "dir": dir,
            "instance": null,
            "error": ""
        };
    }

    /// Rebuild the catalogue from whatever has been found so far, keeping the
    /// instances that are already running. Idempotent on purpose.
    function _publish() {
        // A later search path wins, so a user lens shadows a built-in.
        const byId = {};
        for (let i = 0; i < root._found.length; i++) {
            const entry = root._found[i];
            const held = byId[entry.id];
            if (!held || entry.priority >= held.priority)
                byId[entry.id] = entry;
        }
        const live = {};
        for (let i = 0; i < root.catalog.length; i++)
            live[root.catalog[i].id] = root.catalog[i];

        const list = [];
        for (const id in byId) {
            const entry = byId[id];
            const running = live[id];
            if (running && running.instance && running.dir === entry.dir) {
                entry.instance = running.instance;
                entry.error = running.error;
            }
            list.push(entry);
        }
        list.sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()));

        // A lens that moved directory or left the disk drops out of the
        // catalogue; without this its instance keeps running, keeps fetching
        // on its own timers, and can never be reached again.
        const kept = {};
        for (let i = 0; i < list.length; i++)
            kept[list[i].id] = true;
        for (const id in live) {
            if (kept[id] || !live[id].instance)
                continue;
            if (root.activeId === id)
                root.close();
            live[id].instance.active = false;
            live[id].instance.destroy();
        }

        root.catalog = list;
        root.scanning = false;
        root.catalogUpdated();

        // Only once what is switched on is actually known — `_hydrate` does
        // this pass itself when the file lands.
        if (root._hydrated)
            for (let i = 0; i < list.length; i++)
                if (root.isEnabled(list[i].id))
                    root._instantiate(list[i].id);
    }

    property Timer _settle: Timer {
        id: settle
        interval: 220
        onTriggered: {
            if (root._pending.length > 0) {
                settle.restart();
                return;
            }
            root._publish();
        }
    }

    /*
     * One FolderListModel per search path, built by hand with its slot number
     * as an initial property. An Instantiator over plain objects does NOT
     * inject `index` — measured: every scan threw "cannot read property
     * 'manifest' of undefined" and the lens list came back empty.
     */
    property var _models: []

    property Component _scannerComponent: Component {
        id: scannerComponent

        QtObject {
            id: scanner
            property int slot: 0
            readonly property FolderListModel model: FolderListModel {
                showFiles: false
                showDirs: true
                showDotAndDotDot: false
                onStatusChanged: if (status === FolderListModel.Ready && root.scanning)
                    root._collect(scanner.slot)
            }
        }
    }

    // ── instantiation ────────────────────────────────────────────────────────
    /*
     * Where lens instances are parented. LensHost assigns this from the visual
     * tree; without a parent, a Component a lens creates has nowhere to render.
     */
    property var container: null

    function _updateEntry(id, changes) {
        const list = root.catalog.slice();
        for (let i = 0; i < list.length; i++) {
            if (list[i].id !== id)
                continue;
            const copy = {};
            for (const k in list[i])
                copy[k] = list[i][k];
            for (const k in changes)
                copy[k] = changes[k];
            list[i] = copy;
            break;
        }
        root.catalog = list;
    }

    function _instantiate(id) {
        const entry = root.find(id);
        if (!entry || entry.instance)
            return;
        if (!root.container)
            return;      // LensHost isn't up yet; it retries once it is

        const url = "file://" + entry.dir + "/" + entry.entry;
        const component = Qt.createComponent(url, Component.PreferSynchronous);
        if (component.status === Component.Error) {
            const message = component.errorString();
            root._updateEntry(id, {
                "error": message
            });
            root.lensError(id, message);
            console.warn("[lens]", id, "failed to load:", message);
            return;
        }

        const instance = component.createObject(root.container, {
            "lensId": entry.id,
            "extensionId": entry.id,
            "name": entry.name,
            "description": entry.description,
            "version": entry.version,
            "author": entry.author,
            "lensDir": entry.dir,
            "adult": entry.adult === true,
            "skinId": root.skinOf(entry.id),
            "settings": root.settingsOf(entry.id)
        });
        if (!instance) {
            root._updateEntry(id, {
                "error": "createObject returned null"
            });
            root.lensError(id, "Could not create the lens object.");
            return;
        }

        root._updateEntry(id, {
            "instance": instance,
            "error": ""
        });
        // Set last: it fires activated(), which may read anything above.
        instance.active = true;
    }

    function _destroy(id) {
        const entry = root.find(id);
        if (!entry || !entry.instance)
            return;
        const instance = entry.instance;
        instance.active = false;       // fires deactivated() so it can clean up
        root._updateEntry(id, {
            "instance": null
        });
        instance.destroy();
    }

    // Called by LensHost once it can host instances.
    function containerReady(item) {
        root.container = item;
        if (!root._hydrated)
            return;      // _hydrate() creates them once the file is read
        for (let i = 0; i < root.catalog.length; i++)
            if (root.isEnabled(root.catalog[i].id))
                root._instantiate(root.catalog[i].id);
    }

    /*
     * WHICH LENSES ARE ON, AND WHICH SKIN EACH WEARS, ON DISK.
     *
     * A FileView rather than QtCore.Settings: QSettings needs
     * QCoreApplication's organisation identifiers, a quickshell config sets
     * none, and it silently persisted NOTHING while warning twice per startup.
     * Prefs documents the same trap.
     *
     * Reads `extensions.json` when `lenses.json` is absent, so switching to
     * lenses does not switch everyone's packs back off.
     */
    /*
     * WRITTEN ON CHANGE, NOT ON A TIMER.
     *
     * This was a 250ms debounce, and it lost picked boards: every write makes
     * the watcher fire, the reload that follows puts the file's older contents
     * back into the adapter, and anything still sitting in the debounce window
     * was overwritten by what it was meant to replace. A save that must
     * survive a crash has no business waiting either. The file is a few
     * hundred bytes; it is written the moment something changes.
     */
    /// True once the file on disk has actually been read. NOTHING is written
    /// before that: a lens instantiated during the read holds defaults, and
    /// saving those would erase the real state before it arrived.
    property bool _hydrated: false

    /// What is known to be on disk. Compared before every write so a reload of
    /// our own write cannot start a write/watch loop.
    property string _onDisk: ""

    function _snapshot() {
        return store.enabledJson + "\u0000" + store.skinJson + "\u0000" + store.settingsJson;
    }

    /// True between asking for a write and hearing that it landed.
    property bool _writing: false

    function _persist() {
        if (!root._hydrated || root._snapshot() === root._onDisk)
            return;
        root._onDisk = root._snapshot();
        root._writing = true;
        stateFile.writeAdapter();
    }

    /*
     * The file has landed. Hand every running lens what was actually saved —
     * the scan and the read race, and the lens that won the race is holding
     * defaults it would otherwise save over the top.
     */
    function _hydrate() {
        /*
         * A READ THAT ARRIVES MID-WRITE IS ALREADY OUT OF DATE.
         *
         * The watcher fires on our own write, and a reload that overtakes it
         * hands back the file as it was BEFORE the change — which would then
         * be pushed into the live lens and computed from next time. What we
         * have is newer by construction, so it is put back and written again.
         */
        if (root._writing && root._onDisk.length > 0 && root._snapshot() !== root._onDisk) {
            const held = root._onDisk.split("\u0000");
            store.enabledJson = held[0];
            store.skinJson = held[1];
            store.settingsJson = held[2];
            stateFile.writeAdapter();
            return;
        }
        root._hydrated = true;
        root._onDisk = root._snapshot();
        for (let i = 0; i < root.catalog.length; i++) {
            const entry = root.catalog[i];
            const on = root.isEnabled(entry.id);
            if (on && !entry.instance) {
                root._instantiate(entry.id);
                continue;
            }
            if (!on && entry.instance) {
                // Closed first: destroying the open lens leaves the host
                // drawing a skin whose `lens` is a dead object.
                if (root.activeId === entry.id)
                    root.close();
                root._destroy(entry.id);
                continue;
            }
            if (entry.instance) {
                entry.instance.settings = root.settingsOf(entry.id);
                entry.instance.skinId = root.skinOf(entry.id);
            }
        }
        root.catalogUpdated();
    }

    property FileView _stateFile: FileView {
        id: stateFile
        path: `${Quickshell.env("HOME")}/.config/quarry/lenses.json`
        watchChanges: true
        onFileChanged: stateFile.reload()
        onLoaded: root._hydrate()
        onSaved: root._writing = false
        onSaveFailed: error => {
            // Marked as on disk before it was; the next change must not be
            // skipped as "already saved".
            root._writing = false;
            root._onDisk = "";
            console.warn("[lens] state not saved:", error);
        }
        onLoadFailed: error => {
            /*
             * Every outcome has to end somewhere. A file that vanished after
             * we had read it is rewritten; a missing one migrates the old
             * name; anything else — a permission or I/O error — still counts
             * as hydrated, or `_persist` would refuse for the whole session
             * and nothing would ever be saved again.
             */
            if (root._hydrated) {
                root._onDisk = "";
                root._persist();
                return;
            }
            if (error === FileViewError.FileNotFound) {
                // Only now does the old file become interesting; see below for
                // why it is not given a path until this moment.
                legacyState.path = `${Quickshell.env("HOME")}/.config/quarry/extensions.json`;
                legacyState.reload();
            }
            else
                root._hydrate();
        }

        JsonAdapter {
            id: store
            property string enabledJson: "{}"
            property string skinJson: "{}"
            property string settingsJson: "{}"
        }
    }

    /*
     * ONE-SHOT MIGRATION — AND IT HAS TO BE ONE SHOT.
     *
     * This is read only when `lenses.json` is missing. It had a `path` from
     * the start, and a FileView with a path loads by itself: so the old file
     * was adopted on EVERY launch, stamping September's list over whatever was
     * enabled since and writing that back. A lens switched on in the menu came
     * back off at the next start, for ever, and the switch looked broken.
     *
     * So it has no path until the primary file is found missing, and it adopts
     * nothing once the real state is in hand.
     */
    property FileView _legacyState: FileView {
        id: legacyState
        path: ""
        onLoaded: {
            if (!root._hydrated) {
                try {
                    const old = JSON.parse(legacyState.text());
                    if (old && old.enabledJson)
                        store.enabledJson = old.enabledJson;
                } catch (e) {}
            }
            root._hydrate();
            root._onDisk = "";
            root._persist();
        }
        onLoadFailed: {
            if (legacyState.path.length === 0)
                return;             // never asked for: nothing to migrate
            root._hydrate();
            root._onDisk = "";
            root._persist();
        }
    }

    Component.onCompleted: {
        const built = [];
        for (let i = 0; i < root.searchPaths.length; i++)
            built.push(scannerComponent.createObject(root, {
                "slot": i
            }));
        root._models = built;
        root.rescan();
    }
}
