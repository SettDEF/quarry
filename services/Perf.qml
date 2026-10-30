pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.common

/*
 * The budget, readable without a screen.
 *
 * Frame rate can only be measured while something is actually rendering, but
 * memory and layout cost can be measured any time — and on this desktop the
 * window usually must NOT be raised to run a test, so everything here is also
 * reachable over IPC.
 */
Singleton {
    id: root

    property int frames: 0
    property real fps: 0
    property bool rendering: false

    // Frame-time statistics, collected only while a scroll test runs — the
    // budget is about the worst frame, not the average, and an average hides
    // exactly the stutter people notice.
    /*
     * Blanks: the flicker, counted.
     *
     * A tile "blanks" when it was showing a picture and stops showing one while
     * still having an item — which is exactly what the eye reads as blinking
     * during a scroll. Frame timings cannot see this: a wall can blink at a
     * perfect 60 fps. So ThumbImage reports every transition and the number
     * either is zero or it is not.
     */
    // How many tile pictures have ever become ready. Zero here with a nonzero
    // "served" means loads start and never finish — which looks identical to a
    // gallery that is simply empty.
    property int ready: 0
    /*
     * TILES THAT SHOULD BE SHOWING A PICTURE AND ARE NOT.
     *
     * Live, not cumulative: each tile adds itself while it is starved and takes
     * itself away when its picture appears, so a healthy wall sits at or near
     * zero and a wall with holes in it reports exactly how many.
     *
     * Every other counter here records an EVENT — tiles ready, decode errors —
     * and a tile that was never asked to load raises none of them. "Empty tiles"
     * has been reported four separate times and each time every counter looked
     * healthy while the screen had holes in it. This is the one that would have
     * said so.
     */
    property int starved: 0
    property int errors: 0
    property string lastError: ""

    property int blanks: 0
    property int blanksOffscreen: 0
    property var blankReasons: ({})

    function noteBlank(reason) {
        const seen = root.blankReasons;
        seen[reason] = (seen[reason] || 0) + 1;
        root.blankReasons = seen;
    }

    property bool measuring: false
    property real worstFrameMs: 0
    property int measuredFrames: 0
    property int slowFrames: 0       // > 16.6 ms — a missed frame at 60 Hz
    property int badFrames: 0        // > 32 ms  — visible hitch

    /*
     * The budget is the display, not 60.
     *
     * This panel runs at 180 Hz, so a frame has 5.5 ms, and "avg 5.0 ms" — which
     * reads fine against a 60 Hz budget — is a scroll that misses often enough
     * to feel like lag. Measuring against the refresh rate the machine actually
     * has is the difference between a number that looks good and a scroll that
     * is good.
     */
    /*
     * The budget comes from what the app actually achieves, not from what
     * anyone claims.
     *
     * Hardcoding 180 was wrong on every other machine. But asking Qt is wrong
     * too: `screen.refreshRate` answers 60 for this window while the frame
     * counter plainly reports 180 rendered frames a second, so trusting it
     * would have tripled the budget and declared every frame comfortably on
     * time.
     *
     * So: the fastest rate the app has been observed to sustain. It converges
     * within a second or two of rendering, needs nothing from the compositor,
     * and is by definition a budget the machine has already met.
     */
    property real peakFps: 0
    readonly property real refreshHz: Math.max(30, root.peakFps)
    readonly property real frameBudgetMs: 1000 / root.refreshHz
    property int missedFrames: 0     // over the real budget
    property real measuredMs: 0

    function tick(frameSeconds) {
        root.frames++;
        if (!root.measuring)
            return;
        const ms = frameSeconds * 1000;
        root.measuredFrames++;
        root.measuredMs += ms;
        if (ms > root.worstFrameMs)
            root.worstFrameMs = ms;
        if (ms > root.frameBudgetMs)
            root.missedFrames++;
        if (ms > 16.6)
            root.slowFrames++;
        if (ms > 32)
            root.badFrames++;
    }

    function beginMeasure() {
        root.blanks = 0;
        root.blanksOffscreen = 0;
        root.blankReasons = ({});
        root.worstFrameMs = 0;
        root.measuredFrames = 0;
        root.slowFrames = 0;
        root.missedFrames = 0;
        root.badFrames = 0;
        root.measuredMs = 0;
        root.measuring = true;
    }

    function endMeasure() {
        root.measuring = false;
    }

    // Resident memory of this process, straight from /proc.
    property int rssKb: 0

    property var geometry: null      // set by the active layout
    property var wall: null          // the active scrollable, for scripted tests

    readonly property string rssMbText: `${Math.round(root.rssKb / 1024)} MB`

    function collect() {
        gc();
    }

    function sample() {
        statusFile.reload();
        return root.report();
    }

    function report() {
        const geom = root.geometry;
        return JSON.stringify({
            "fps": root.fps,
            "rendering": root.rendering,
            "rssMb": Math.round(root.rssKb / 1024),
            "placeMs": geom ? geom.lastPlaceMs : -1,
            "placeCount": geom ? geom.lastPlaceCount : -1,
            "totalHeight": geom ? Math.round(geom.totalHeight) : -1,
            "scroll": {
                "blanks": root.blanks,
                "blanksOffscreen": root.blanksOffscreen,
                "blankReasons": root.blankReasons,
                "frames": root.measuredFrames,
                "avgFrameMs": root.measuredFrames > 0 ? Math.round(root.measuredMs / root.measuredFrames * 100) / 100 : 0,
                "worstFrameMs": Math.round(root.worstFrameMs * 100) / 100,
                "budgetMs": Math.round(root.frameBudgetMs * 100) / 100,
                "missedBudget": root.missedFrames,
                "over16ms": root.slowFrames,
                "over32ms": root.badFrames
            },
            "decodeInFlight": ThumbGate.inFlight,
            "decodeQueued": ThumbGate.queueLength,
            "decodeServed": ThumbGate.served,
            "decodeReclaimed": ThumbGate.leaked,
            "items": Catalog.count,
            "backend": Catalog.backend,
            "socketTimeouts": Client.timeouts,
            "tilesReady": root.ready,
            "tilesStarved": root.starved,
            // How many tiles are actually playing, and how many wanted to but did
            // not get a slot. A cap nobody can see is a cap nobody can tune.
            "playing": PlayGate.playing,
            // Rows whose real file has been found — see Playback. Zero on a
            // wall of tube rows means autoplay has nothing to play.
            "resolved": Playback.known,
            "holders": PlayGate.holderList,
            "playWaiting": PlayGate.waiting,
            // "All in view": video tiles past the threshold should equal `playing`.
            "videosInView": Scripts._tiles.filter(t => t && t.isVideo && t.visible && t.visibleRatio * 100 >= Prefs.autoplayThreshold).length,
            "soundToken": PlayGate.soundToken,
            "holdMs": Math.max(0, Math.round(Scripts._holdUntil - Date.now())),
            "tileErrors": root.errors,
            "lastTileError": root.lastError,
            "thumbsCached": Catalog.thumbsCached,
            "thumbsFailed": Catalog.thumbsFailed,
            "brokenRetired": Catalog.brokenSeen,
            "pagesResident": Catalog.pagesResident,
            "pageLoads": Catalog.pageLoads,
            "itemLookups": Catalog.lookups(),
            "pagesEvicted": Catalog.pagesEvicted
        }, null, 0);
    }

    FileView {
        id: statusFile
        path: "/proc/self/status"
        onLoaded: {
            const m = /VmRSS:\s+(\d+) kB/.exec(statusFile.text());
            if (m)
                root.rssKb = parseInt(m[1]);
        }
    }

    property Timer _sampler: Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: {
            root.fps = root.frames;
            // Ignore the first partial second and any stall: a peak is only
            // meaningful from a full sample.
            if (root.frames > root.peakFps && root.frames < 1000)
                root.peakFps = root.frames;
            // FrameAnimation only ticks while the window is actually drawing, so
            // zero here means "not on screen", not "stalled".
            root.rendering = root.frames > 0;
            root.frames = 0;
            statusFile.reload();
        }
    }
}
