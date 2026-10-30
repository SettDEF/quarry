import QtQuick
import Quickshell
import Quickshell.Io
pragma Singleton

/*
 * Persisted preferences.
 *
 * QtCore.Settings is what Rodded uses, but it needs QCoreApplication's
 * organisation identifiers, which a quickshell config does not set — it warns
 * and then persists nothing. So this follows the house pattern instead: a
 * FileView with a JsonAdapter, exactly like the `ii` config's Persistent.qml,
 * writing ~/.config/quarry/prefs.json.
 */
Singleton {
    // A list already prints the title and the source in the row, so
    // the picture beside them needs none of it.

    id: root

    /*
     * WHICH APP'S PREFERENCES THESE ARE.
     *
     * This file is shared by symlink with cairn and scree, and it used to
     * hardcode quarry's directory — so scree read quarry's `transparency: 0.8`
     * and opened 80% see-through, a setting somebody made for a picture
     * gallery and never for a disk tool.
     *
     * `QS_PREFS_APP` names the app; unset stays quarry, so nothing about the
     * gallery changes.
     */
    readonly property string app: Quickshell.env("QS_PREFS_APP") || "quarry"
    readonly property string dir: `${Quickshell.env("HOME")}/.config/${root.app}`
    property alias s: adapter
    /*
     * EVERY LAYOUT KEEPS ITS OWN MIND.
     *
     * A wall and a compact list are not the same screen with different
     * geometry: on the wall the picture is the point and a caption is noise, in
     * a list the caption IS the row. One global set of toggles meant every
     * choice was a compromise between the two, so the wall carried furniture it
     * did not want and the list went without what it needed.
     *
     * This is a map of layout id → what that layout shows: each badge, each
     * hover button, the size of a tile, its own sort. Unset keys fall through
     * to `layoutDefaults`, so a new option appears everywhere with a sensible
     * value and nobody's saved file needs migrating.
     */
    property alias layoutOptions: adapter.layoutOptions
    /// What a layout shows when nothing has been chosen for it. Deliberately
    /// different per layout — that is the whole point of the feature.
    readonly property var layoutDefaults: ({
        "wall": {
            "badges": true,
            "length": true,
            "ring": true,
            "strip": true,
            "title": true,
            "meta": true,
            "export": true,
            "open": true,
            "keep": false,
            "board": false,
            "wallpaper": false,
            "copy": false,
            "similar": false,
            "hide": false,
            "tileSize": 0,
            "gap": 10,
            "sort": ""
        },
        "grid": {
            "badges": true,
            "length": true,
            "ring": true,
            "strip": true,
            "title": true,
            "meta": true,
            "export": true,
            "open": true,
            "keep": false,
            "board": false,
            "wallpaper": false,
            "copy": false,
            "similar": false,
            "hide": false,
            "tileSize": 184,
            "gap": 10,
            "sort": ""
        },
        "compact": {
            "badges": true,
            "length": true,
            "ring": false,
            "strip": false,
            "title": false,
            "meta": false,
            "export": true,
            "open": false,
            "keep": true,
            "board": false,
            "wallpaper": false,
            "copy": true,
            "similar": false,
            "hide": true,
            "tileSize": 72,
            "gap": 6,
            "sort": ""
        }
    })
    // Convenience aliases so views read `Prefs.layoutMode`, not `Prefs.s.layoutMode`.
    property alias transparency: adapter.transparency
    /*
     * cairn's two, which had no alias.
     *
     * `Prefs.autoRefresh` therefore read `undefined` — the settings switch was
     * permanently off, and pressing it assigned to nothing. Every preference
     * here needs its line; the adapter is not reachable from outside without
     * one.
     */
    property alias autoRefresh: adapter.autoRefresh
    property alias openByTime: adapter.openByTime
    property alias editorFontSize: adapter.editorFontSize
    property alias editorLineHeight: adapter.editorLineHeight
    property alias editorTabWidth: adapter.editorTabWidth
    property alias editorAutoIndent: adapter.editorAutoIndent
    property alias animationSpeed: adapter.animationSpeed
    property alias layoutMode: adapter.layoutMode
    property alias wallColumns: adapter.wallColumns
    property alias gridTileSize: adapter.gridTileSize
    property alias animateOnHover: adapter.animateOnHover
    /*
     * PLAY WHAT IS ON SCREEN, not what the pointer is on.
     *
     * Hovering to play is fine when you are choosing; it is the wrong gesture
     * when the wall is scrolling itself. Off by default because it costs
     * decoders — see PlayGate, which caps how many run at once.
     */
    property alias autoplayInView: adapter.autoplayInView
    /// How many may play at once. See PlayGate — the cost is decoders.
    property alias autoplaySlots: adapter.autoplaySlots
    property alias autoplayThreshold: adapter.autoplayThreshold
    property alias snapToVideo: adapter.snapToVideo
    property alias dwellMaxSeconds: adapter.dwellMaxSeconds
    property alias snapTolerance: adapter.snapTolerance
    /// Autoscroll holds whenever a new video starts playing.
    property alias dwellOnVideo: adapter.dwellOnVideo
    property alias dwellSeconds: adapter.dwellSeconds
    /// Autoscroll holds while the pointer is on a picture.
    property alias pauseOnHover: adapter.pauseOnHover
    /// After you drag or flick it yourself, autoscroll comes back by itself.
    property alias resumeAfterTouch: adapter.resumeAfterTouch
    property alias idleSeconds: adapter.idleSeconds
    /// Eased autoscroll, and how much of the last frame's motion carries over.
    property alias smoothScroll: adapter.smoothScroll
    property alias scrollSmoothness: adapter.scrollSmoothness
    /// The pointer's height on the wall sets the pace.
    property alias pointerSteersSpeed: adapter.pointerSteersSpeed
    /// A short slowdown right after you scroll it yourself.
    property alias dampenAfterTouch: adapter.dampenAfterTouch
    /// How the wait on a video is worked out: its whole length, a fraction of
    /// it, or the fixed number of seconds.
    property alias dwellMode: adapter.dwellMode
    property alias dwellPercent: adapter.dwellPercent
    // Persisted like the rest, so a session that wanted the numbers keeps them.
    property alias showStats: adapter.showStats
    property alias tileClip: adapter.tileClip
    property alias tileRadius: adapter.tileRadius
    property alias tileSmoothing: adapter.tileSmoothing
    property alias recentQueries: adapter.recentQueries
    property alias videoSound: adapter.videoSound
    property alias videoVolume: adapter.videoVolume
    property alias detailInfoOpen: adapter.detailInfoOpen
    property alias boardGround: adapter.boardGround
    property alias boardPieces: adapter.boardPieces
    property alias hoverSound: adapter.hoverSound
    property alias wallpaperSound: adapter.wallpaperSound
    property alias videoAutoplay: adapter.videoAutoplay
    /// "auto", or a rendition label ("720p", "Original"): which size to play
    /// when a video has several.
    property alias videoQuality: adapter.videoQuality
    /// Whether searches, opens and exports are written down at all.
    property alias keepHistory: adapter.keepHistory
    property alias showNsfw: adapter.showNsfw
    property alias blurNsfw: adapter.blurNsfw
    property alias windowWidth: adapter.windowWidth
    property alias windowHeight: adapter.windowHeight
    property alias mediaOwnWindow: adapter.mediaOwnWindow
    property alias mediaFullscreen: adapter.mediaFullscreen
    property alias morseDaemon: adapter.morseDaemon
    property alias mediaWindowWidth: adapter.mediaWindowWidth
    property alias mediaWindowHeight: adapter.mediaWindowHeight
    property alias railExpanded: adapter.railExpanded
    /// What was being searched for, so a reload comes back to it — see Catalog.
    property alias lastQuery: adapter.lastQuery
    /// The stored settings have been read: until then every value is a default,
    /// and restoring from one would restore nothing.
    property bool loaded: false
    property alias fetchMode: adapter.fetchMode
    property alias railGroups: adapter.railGroups
    property alias browserEnabled: adapter.browserEnabled
    property alias browserSourceInApp: adapter.browserSourceInApp
    property alias browserPersist: adapter.browserPersist
    // User scripts — services/Scripts.qml.
    property alias scriptsEnabled: adapter.scriptsEnabled
    property alias disabledScripts: adapter.disabledScripts
    property alias scriptStore: adapter.scriptStore
    property alias openDocks: adapter.openDocks
    property alias historyLayout: adapter.historyLayout
    property alias scrollPositions: adapter.scrollPositions
    // Coalesce writes: a slider drag would otherwise write on every frame.
    // Declared outside FileView, whose default property takes the adapter only.
    property Timer _writeTimer

    // Default layout is remembered per kind — avatars want Grid, wallpapers Wall.
    function layoutForKind(kind) {
        const key = "layout_" + kind;
        const map = adapter.layoutByKind;
        if (map && map[key])
            return map[key];

        return (kind === "avatar" || kind === "icon" || kind === "emote") ? "grid" : "wall";
    }

    function setLayoutForKind(kind, layout) {
        const map = Object.assign({
        }, adapter.layoutByKind || {
        });
        map["layout_" + kind] = layout;
        adapter.layoutByKind = map;
    }

    /// Everything a layout shows, defaults filled in. Read this, not the raw map.
    function layoutSettings(layout) {
        const base = root.layoutDefaults[layout] || root.layoutDefaults["wall"];
        const saved = (adapter.layoutOptions || {
        })[layout] || {
        };
        return Object.assign({
        }, base, saved);
    }

    /// One option of one layout, remembered.
    function setLayoutOption(layout, key, value) {
        const all = Object.assign({
        }, adapter.layoutOptions || {
        });
        const mine = Object.assign({
        }, all[layout] || {
        });
        mine[key] = value;
        all[layout] = mine;
        adapter.layoutOptions = all;
    }

    /// Back to what the layout ships with.
    function resetLayoutOptions(layout) {
        const all = Object.assign({
        }, adapter.layoutOptions || {
        });
        delete all[layout];
        adapter.layoutOptions = all;
    }

    /// Where this screen was left. 0 when it has never been seen.
    function positionFor(key) {
        const held = root.scrollPositions[String(key)];
        return held === undefined ? 0 : Number(held);
    }

    /*
     * Remember a position — capped, and only for screens with a name.
     *
     * Two hundred entries is a person's whole browsing life; an uncapped map
     * is a settings file that grows for ever and eventually costs a second
     * to parse at launch.
     */
    function rememberPosition(key, y) {
        const id = String(key || "");
        if (id.length === 0)
            return ;

        const next = Object.assign({
        }, root.scrollPositions);
        next[id] = Math.max(0, Math.round(y));
        const keys = Object.keys(next);
        if (keys.length > 200) {
            for (const gone of keys.slice(0, keys.length - 200)) delete next[gone]
        }
        root.scrollPositions = next;
    }

    FileView {
        id: view

        path: `${root.dir}/prefs.json`
        watchChanges: true
        onFileChanged: view.reload()
        onAdapterUpdated: writeTimer.restart()
        // Once the stored settings are actually in hand — not at startup,
        // when the adapter still holds nothing but defaults.
        // No file yet (a first run) is still "read": there is nothing to wait for.
        onLoadFailed: root.loaded = true
        onLoaded: {
            root.loaded = true;
            if (adapter.browserSourceReviewed)
                return ;

            adapter.browserSourceReviewed = true;
            adapter.browserSourceInApp = false;
        }

        JsonAdapter {
            //             * Sound from a tile the pointer merely crossed. OFF.
            //             *
            //             * The wall was silent by decision, not by omission — sound belonged
            //             * to the one thing you had chosen to look at. That is still the
            //             * right default: a wall where audio starts because the pointer
            //             * moved is startling, and worse, moving across a row would fire
            //             * several in a second. On, only the hovered tile is ever audible.

            id: adapter

            property real transparency: 0
            /*
             * cairn's, living here because this file is now genuinely shared
             * by three apps and each reads its OWN prefs.json — quarry's copy
             * simply never writes this one.
             */
            property int autoRefresh: 0
            /// cairn's: open on "newest first" rather than on the ranking.
            property bool openByTime: false
            // knap's. Here for the same reason cairn's are: this file is genuinely
            // shared by four apps now, and each reads its OWN prefs.json.
            property int editorFontSize: 15
            property real editorLineHeight: 1.45
            property int editorTabWidth: 4
            property bool editorAutoIndent: true
            property real animationSpeed: 1
            property string layoutMode: "wall"
            /// layout id → the options changed for it. Only differences are
            /// stored; see `layoutDefaults`.
            property var layoutOptions: ({
            })
            property int wallColumns: 0 // 0 = automatic from width
            property int gridTileSize: 184 // the Steam avatar size, as a nod
            property bool showNsfw: false
            property bool blurNsfw: true
            // Render tuning, exposed so the cost of each can be measured rather
            // than argued about. See PERF.md.
            property bool animateOnHover: true
            // See the alias above: off until asked for, because it costs
            // decoders rather than just a setting.
            property bool autoplayInView: true
            // 0 = every video in view (see autoplayThreshold); otherwise the N nearest the middle.
            property int autoplaySlots: 0
            // Percent of a tile on screen before it plays, when every video in view plays.
            property int autoplayThreshold: 60
            // Autoscroll centres a playing video that reaches the middle before it holds on it.
            property bool snapToVideo: true
            // Cap on "whole video" / "part of it" waits, seconds.
            property int dwellMaxSeconds: 30
            property int snapTolerance: 60
            // On by default, but it can only happen when autoplay is: nothing
            // elects a player otherwise, so the scroll never holds.
            property bool dwellOnVideo: true
            property int dwellSeconds: 5
            property bool pauseOnHover: false  // off, as in Reddtastic: on a full wall the pointer is always over a picture
            property bool resumeAfterTouch: true
            property int idleSeconds: 3
            property bool smoothScroll: true
            // How much of the previous frame's motion survives. 0 is the
            // stepped scroll exactly; past ~0.9 it drifts after you stop.
            property real scrollSmoothness: 0.6
            property bool pointerSteersSpeed: false
            property bool dampenAfterTouch: true
            property string dwellMode: "full"
            property int dwellPercent: 80
            /// The live fps/memory/decode readout in the corner. OFF: it is
            /// debug output, and it sits on top of the pictures — which is
            /// exactly where a picture is guaranteed to be. Kept because it is
            /// what found the wall's zero-height columns, not because it earns
            /// permanent space.
            property bool showStats: false
            property bool tileClip: true
            property real tileRadius: 12
            property bool tileSmoothing: false
            /// Sound in the detail view's player. OFF: a gallery that makes
            /// noise when you click a thumbnail is startling in a way no
            /// setting makes up for after the fact.
            property bool videoSound: false
            /// How loud, 0..1. Persisted because a volume you have to set again
            /// every time you open a clip is not a volume control.
            property real videoVolume: 0.8
            /// The viewer's side panel. OFF: the viewer is for looking at the
            /// picture, and the facts about it are a thing you ask for.
            property bool detailInfoOpen: false
            /*
             * HOW SOLID THE BOARD IS. Both 1 — opaque — by default.
             *
             * `boardGround` is the canvas behind the pictures and `boardPieces`
             * is the pictures themselves, and they are separate because the
             * useful state is one of them: a clear ground with solid pictures
             * leaves reference floating over whatever you are drawing in, which
             * is the entire reason to want a transparent reference board. Fading
             * the pictures as well is for tracing, which is a different job.
             */
            property real boardGround: 1
            property real boardPieces: 1
            property bool hoverSound: false
            /// Sound from a video wallpaper. OFF — a desktop background that
            /// makes noise is a surprise you cannot trace to anything you did.
            property bool wallpaperSound: false
            /// Start playing when a video is opened. ON — you opened it.
            property bool videoAutoplay: true
            property string videoQuality: "auto"
            property bool keepHistory: true
            property int windowWidth: 1280
            property int windowHeight: 840
            // Open media in a window of its own rather than over the gallery,
            // so the wall stays usable behind it.
            property bool mediaOwnWindow: false
            /// That window opens filling the screen.
            property bool mediaFullscreen: false
            // Where morsed lives, when it is not installed anywhere standard.
            // The Morse lens starts it from here; empty means "look on PATH
            // and in the usual places".
            property string morseDaemon: ""
            property int mediaWindowWidth: 1100
            property int mediaWindowHeight: 700
            // The navigation rail: names and counts, or icons only.
            property bool railExpanded: true
            // "endless", "search" or "catalog" — see Catalog.fetchMode.
            property string fetchMode: "endless"
            // Which rail groups are unfolded: { media, kinds, library }.
            property var railGroups: ({
            })
            property var layoutByKind: ({
            })
            /// The last searches that were actually run. Persisted, because a
            /// history that resets every launch is not a history.
            property var recentQueries: []
            /// The in-app browser (modules/gallery/BrowserView.qml).
            property bool browserEnabled: true
            /*
             * WHOSE BROWSER A LINK OPENS IN — the desktop's, by default.
             *
             * quarry has a browser window of its own now, and it is the right
             * place for a page a LENS reaches for: the source behind a tile,
             * a performer's page, a thread's original formatting. It is the
             * wrong place for a link somebody sent you. That link belongs to
             * the browser you are already signed in to, with your extensions,
             * your history and your tabs — which is where every other app on
             * the desktop sends it.
             *
             * Either route stays one click away, and this is the switch.
             */
            property bool browserSourceInApp: false
            /*
             * WHETHER THAT DEFAULT HAS BEEN APPLIED TO AN EXISTING SETTINGS
             * FILE — which a default cannot do by itself.
             *
             * `browserSourceInApp` used to default to true, so every settings
             * file written before this has `true` in it EXPLICITLY. Flipping
             * the default changes nothing for anybody who has already run
             * quarry: they keep opening links in quarry's own window and the
             * new default is invisible. (The same trap caught Morse's
             * autostart on the same afternoon.)
             *
             * So the switch is thrown once, here, and remembered. Turn it
             * back on afterwards and it stays on.
             */
            property bool browserSourceReviewed: false
            /*
             * USER SCRIPTS — see services/Scripts.qml.
             *
             * On by default: a folder with nothing in it costs one `ls` every
             * two seconds and a person who has never written one never learns
             * the feature exists if it ships switched off.
             */
            property bool scriptsEnabled: true
            /// Ids a person turned off. Only the exceptions are stored, so a
            /// script added later is on until it is not.
            property var disabledScripts: []
            /// Per script key/value, the `@grant storage` side of the API.
            property var scriptStore: ({
            })
            /*
             * WHICH SCRIPT DOCKS ARE SHOWING.
             *
             * A dock is a script's own strip of controls, switched on from the
             * overflow menu — so it has to survive a restart the way any other
             * switched-on thing does. Held by script id: a dock whose script
             * is gone leaves an id nobody matches, which costs nothing.
             */
            property var openDocks: []
            /// How the history screen draws itself — the same four shapes
            /// the gallery and the lenses use.
            property string historyLayout: "compact"
            /*
             * WHERE YOU WERE, PER SCREEN.
             *
             * Closing quarry lost your place in a wall of 165,000 —
             * which is the one thing a catalogue that big cannot afford,
             * because scrolling back to where you were is not a scroll,
             * it is an expedition. Keyed by screen (the gallery's layout
             * and query, a lens and its subreddit or board or chat, the
             * rail), so two screens never fight over one number.
             */
            property var scrollPositions: ({
            })
            /// Off the record unless asked: a page read inside quarry should
            /// not leave a second browser profile on the disk.
            property bool browserPersist: false
            property string lastQuery: ""
        }

    }

    _writeTimer: Timer {
        id: writeTimer

        interval: 250
        onTriggered: view.writeAdapter()
    }

}
