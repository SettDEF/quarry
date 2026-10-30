import qs.modules.common
import qs.services
import QtQuick

/*
 * A catalogue item's picture. Use this; do not load thumbnails by hand.
 *
 * It exists because the obvious way to write this is wrong twice over, and both
 * mistakes were made three times in this codebase before it was factored out:
 *
 * **Never bind `source`.** `source: Catalog.thumbFor(item, size)` reads
 * catalogue state inside a binding and the arriving path assigns the same
 * property — a binding loop, reported by Qt and paid for in frames.
 *
 * **Never clear the old picture first.** A pooled tile re-pointed at a new item
 * clears to nothing the moment `source` changes and stays blank until the next
 * decode finishes: that is the flicker while scrolling. So there are two
 * layers, the incoming one loads hidden, and they cross-fade only when it is
 * actually ready.
 *
 * Loads go through ThumbGate when `gated`, so a fast scroll cannot queue four
 * hundred decodes for tiles nobody will see. A detail view sets `gated: false`:
 * there is one of it, and it should not wait behind a wall.
 */
Item {
    id: root

    property var item: null
    /*
     * THE LADDER STEP TO ASK FOR — AND WHEN TO ACT ON A CHANGE.
     *
     * `size` is bound to how big the picture is being DRAWN, which changes
     * continuously while a window is resized or a board is zoomed. Acted on
     * directly, every intermediate width crossed a ladder boundary and threw
     * away a perfectly good decoded picture to fetch another size — so
     * dragging a window edge made the whole wall reload, repeatedly, for
     * pictures that were already on screen.
     *
     * So a change WAITS. During the drag the GPU scales what is already
     * decoded — slightly soft — and the sharper step is fetched once you stop.
     * That is what every map and every image viewer does, for this reason.
     *
     * The first size is applied immediately: there is nothing on screen to
     * keep, and making the first paint wait a fifth of a second to avoid a
     * reload that cannot happen would be a poor trade.
     */
    property int size: 320
    property int _appliedSize: 0

    Timer {
        id: settleSize
        interval: 200
        onTriggered: root._appliedSize = root.size
    }
    property bool gated: true
    property bool smoothing: Prefs.tileSmoothing
    property real priority: 0
    property int fillMode: Image.PreserveAspectCrop
    property real contentMargins: 0

    // Ready means THIS item's picture is up — see `ownPicture`.
    readonly property bool ready: (layerA.status === Image.Ready || layerB.status === Image.Ready) && root.ownPicture

    /*
     * Report the flicker rather than claim it is gone.
     *
     * Going from showing a picture to showing nothing, while still having an
     * item, is the blink. Perf counts these during a scroll test, so "no
     * blinking" is a measurement instead of an assurance.
     */
    property bool _wasReady: false
    onReadyChanged: {
        if (root._wasReady && !root.ready && root.item) {
            // Split, rather than tuned: a tile going empty while it is on
            // screen is the flicker; a tile clearing as it leaves the pool is
            // housekeeping nobody can see. Counting them together would let one
            // hide behind the other, in either direction.
            if (root.visible) {
                Perf.blanks++;
                // Why, not just how many: the visible layer should never lose
                // its picture, so each of these is a specific mistake and the
                // reason names it.
                Perf.noteBlank(`lastAssign=${root._lastAssign} A=${layerA.source.toString().slice(-12)}:${layerA.status} B=${layerB.source.toString().slice(-12)}:${layerB.status} showingA=${root.showingA}`);
            }
            else
                Perf.blanksOffscreen++;
        }
        root._wasReady = root.ready;
    }
    readonly property bool failed: !root.ready && (layerA.status === Image.Error || layerB.status === Image.Error)
    readonly property bool loading: !root.ready && !root.failed && root.source.length > 0

    property string source: ""

    /*
     * A BETTER COPY OF THE SAME PICTURE MUST NOT ANIMATE.
     *
     * The crossfade exists so that changing to a DIFFERENT picture is not a
     * jump cut. But the same picture arriving at a higher ladder step goes
     * through the same path — so a tile, or a board piece after a zoom, would
     * fade out and back in while showing you the identical image. Nothing has
     * changed except the resolution, and the eye reads that pulse as the
     * picture flickering for no reason.
     *
     * So: the fade is for a new picture. A sharper copy of the one already on
     * screen swaps underneath you and the picture stands still.
     */
    property string _lastId: ""
    /*
     * WHOSE PICTURE IS ON SCREEN.
     *
     * Keeping the old picture until the new one is ready is what stops the
     * flicker — for the SAME item at a new size. For a different item it
     * showed the wrong picture: step to a video whose poster would not load
     * and the previous item's image stayed up, under the new title, looking
     * exactly like the new item's picture. A picture is only ever drawn for
     * the item it was loaded for; a different item shows nothing until its
     * own arrives.
     */
    property string _shownId: ""
    readonly property bool ownPicture: root._shownId.length > 0 && root._shownId === root._lastId

    /*
     * On screen, has a row, has a path — and is drawing nothing.
     *
     * Counted in `Perf.starved` so a wall with holes in it can be measured
     * instead of noticed. See the note there.
     */
    readonly property bool starved: root.visible && !!root.item
        && root.source.length > 0 && !root.ownPicture

    onStarvedChanged: Perf.starved += root.starved ? 1 : -1
    property bool _upgrade: false
    readonly property int _fadeMs: root._upgrade ? 0 : Appearance.animDur(110)
    property bool showingA: true
    readonly property Image visibleLayer: root.showingA ? layerA : layerB
    readonly property Image spareLayer: root.showingA ? layerB : layerA

    property string _token: ""

    function refresh() {
        const id = root.item ? String(root.item.id) : "";
        // Same row, new source: it is the same picture at a different size.
        root._upgrade = id.length > 0 && id === root._lastId;
        root._lastId = id;
        root.source = root.item ? Catalog.thumbFor(root.item, root._appliedSize || root.size) : "";
    }

    /*
     * A `file://` source that will not load is a thumbnail that has been
     * evicted since the page was fetched — the one place in the app that can
     * know it, because only the loader touches the disk. Telling the catalogue
     * strikes the path off and asks the daemon for the picture properly.
     */
    function _localVanished(failed) {
        const path = String(failed);
        if (path.indexOf("file://") !== 0 || !root.item)
            return ;

        Catalog.thumbVanished(root.item, root._appliedSize || root.size);
    }

    function _release() {
        if (root._token.length > 0) {
            ThumbGate.done(root._token);
            root._token = "";
        }
    }

    property string _lastAssign: "none"

    function _start() {
        const target = root.spareLayer;
        // The spare is by definition not the visible layer — but if that ever
        // stops being true, the visible picture is thrown away, so it is worth
        // asserting rather than assuming.
        if (target === root.visibleLayer) {
            root._lastAssign = "SPARE-IS-VISIBLE";
            return;
        }
        root._lastAssign = (target === layerA ? "A" : "B") + "@" + root.source.slice(-12);
        if (target.source == root.source) {
            /*
             * The SPARE already holds this picture.
             *
             * Assigning the same source is a no-op, so `onStatusChanged` never
             * fires and `_layerReady` never runs — the same "loaded but never
             * shown" hole as the one above, reached by the other door. A
             * delegate recycled back onto a row it showed a moment ago lands
             * here.
             */
            target.forId = root._lastId;
            if (target.status === Image.Ready)
                root._layerReady(target);

            return ;
        }
        if (target.source != root.source) {
            /*
             * `sourceSize` is set here, not bound.
             *
             * Bound to a property that changes — the tile's ladder step — it
             * invalidates whatever the layer has already decoded, so *both*
             * layers reload at once and the visible one goes blank. That was
             * the last of the flicker. Setting it immediately before the
             * source means a size change takes effect on the next picture
             * rather than destroying the current one.
             */
            target.sourceSize.width = root._appliedSize || root.size;
            // Which ROW this load belongs to — see `_layerReady`. Matching on
            // the filename cannot tell "the same picture, smaller" from "a
            // different row", and those need opposite answers.
            target.forId = root._lastId;
            target.source = root.source;
        }
    }

    /*
     * THE ANSWER ARRIVES LATER, AND NOTHING WAS LISTENING FOR IT.
     *
     * `Catalog.thumbFor` returns "" while it asks the daemon — deliberately, so
     * a tile never shows a remote URL that a hotlink-blocking source will 403.
     * When the path lands it emits `thumbReady`. That signal had NO CONSUMER
     * anywhere in the app, so a tile whose thumbnail was not already cached sat
     * empty for good: the picture existed, on disk, and nothing ever told the
     * cell to look again.
     *
     * It hid behind the record's own `thumb_local`, which is returned
     * immediately and covers the common case — but only for sizes at or under
     * `recordThumbSize` (320). A display with a device pixel ratio above 1
     * pushes a wall tile to the 640 rung, which skips `thumb_local` entirely,
     * and then EVERY cold tile depended on this signal. That is why a wall of
     * 11,319 vectors drew nothing while every counter reported success.
     */
    property Connections _thumbArrived: Connections {
        target: Catalog

        function onThumbReady(id, path) {
            if (path.length === 0 || !root.item || String(root.item.id) !== id)
                return ;

            // Only if we are still waiting: a tile that already has its picture
            // must not be re-sourced by a late answer for a different size.
            if (root.source.length === 0)
                root.refresh();

        }
    }

    onItemChanged: root.refresh()

    // Leaving the pool is the moment to let the pixmaps go.
    onVisibleChanged: {
        if (!root.visible && !root.item) {
            layerA.source = "";
            layerB.source = "";
        }
    }
    onSizeChanged: {
        if (root._appliedSize === 0)
            root._appliedSize = root.size;      // nothing to keep yet
        else
            settleSize.restart();
    }
    on_AppliedSizeChanged: root.refresh()
    Component.onCompleted: {
        // Seed it, or the first paint waits for a size change that may never
        // come — a tile whose width never moves would sit empty forever.
        if (root._appliedSize === 0)
            root._appliedSize = root.size;
        root.refresh();
    }
    Component.onDestruction: {
        root._release();
        // A tile destroyed while starved must not leave its count behind.
        if (root.starved)
            Perf.starved -= 1;

    }

    onSourceChanged: {
        root._release();

        if (root.source.length === 0) {
            /*
             * Nothing to show *yet* is not the same as nothing to show.
             *
             * A recycled tile asks the catalogue for a path and gets an empty
             * string back while the daemon fetches the thumbnail. Clearing the
             * layers here is what produced 125 blank flashes in a six-second
             * sweep: the picture that was there is thrown away to display a
             * hole, and the hole lasts until a network round trip finishes.
             *
             * So the old frame stays until a new one is ready. Only an item
             * that is genuinely gone clears the tile.
             */
            /*
             * Two ways to have no path, and only one of them should clear.
             *
             * A recycled tile is briefly item-less: records arrive by page, and
             * during a fast scroll `Catalog.itemAt` returns null until the page
             * lands. Clearing then is what remained of the flicker — 59 visible
             * blanks in a six-second sweep, all of them a picture thrown away
             * for a page fetch.
             *
             * So the last frame stays while the tile is on screen. Pixmaps are
             * released when the tile leaves the pool instead, which is where
             * nobody can see it happen.
             */
            if (!root.visible) {
                layerA.source = "";
                layerB.source = "";
            }
            return;
        }
        if (root.visibleLayer.source == root.source) {
            /*
             * ALREADY ON SCREEN — BUT THE TILE HAS TO BE TOLD.
             *
             * Nothing to load, so this returned. It also never set `_shownId`,
             * and `ownPicture` is `_shownId === _lastId` — so the tile drew its
             * ground colour with the right picture decoded in the layer behind
             * it. That is the tile that is EMPTY AFTER LEAVING THE VIEWER.
             *
             * The sequence: the wall stays visible behind the detail view, the
             * model window drops the far page, `item` goes null for a moment —
             * `_lastId` becomes "" while `_shownId` still holds the row, so the
             * picture is hidden on purpose. The page comes back, `_lastId` is
             * the row again and `source` is the same path it always was, and
             * this early return skipped the one line that would have shown it
             * again. Nothing else ever fired, so the hole was permanent.
             *
             * Adopting it is the whole fix: the picture is right, it is loaded,
             * and it belongs to the row being asked for.
             */
            root.visibleLayer.forId = root._lastId;
            root._shownId = root._lastId;
            return;
        }

        if (!root.gated) {
            root._start();
            return;
        }

        const token = root.source + "#" + Math.random();
        root._token = token;
        ThumbGate.request(token, root.priority, function () {
            // `root` is null when the item was destroyed while queued, and the
            // slot still has to go back.
            if (!root || root._token !== token) {
                ThumbGate.done(token);
                return;
            }
            root._start();
        });
    }

    Connections {
        target: Catalog
        function onThumbReady(id, path) {
            if (!root.item || root.item.id !== id || path.length === 0)
                return;
            // The daemon finished a thumbnail for the row already on screen —
            // the same picture, sharper. No fade; see `_upgrade`.
            root._upgrade = true;
            root.source = path;
        }
    }

    function _layerReady(layer) {
        if (layer.source != root.source) {
            /*
             * A DIFFERENT SIZE OF THE SAME PICTURE IS NOT A STALE LOAD.
             *
             * A tile starts on the 320 the record carries, then measures itself
             * and asks for the 640. When the 320 finished decoding, this
             * compared filenames, saw `…-320.jpg != …-640.jpg` and threw a
             * perfectly good picture away — so the cell stayed EMPTY until the
             * larger one arrived, and if that request was still in flight it
             * simply sat there. Opening the same row showed it instantly,
             * because the detail view is ungated and asks once. That was the
             * whole of "some images are empty".
             *
             * A load for the row that is still on screen is shown. It is the
             * right picture, merely softer; the sharper one replaces it with no
             * fade when it lands (`_upgrade`). Only a load for a DIFFERENT ROW
             * is genuinely stale, and that is what is dropped.
             */
            if (layer.forId.length === 0 || layer.forId !== root._lastId) {
                Perf.lastError = "stale: " + layer.source.toString().slice(-24) + " != " + root.source.slice(-24);
                return;                  // a load for a row that has moved on
            }
        }
        Perf.ready++;
        root._shownId = root._lastId;
        root.showingA = (layer === layerA);
        root._release();
        dropSpare.restart();
    }

    /*
     * THE OUTGOING PICTURE IS LET GO ONCE THE FADE IS OVER.
     *
     * Two layers is what makes a tile change picture without blinking, and the
     * cost of that was being paid FOREVER: the layer that faded out kept its
     * source, so every delegate that had ever been recycled — which, after any
     * scroll at all, is all of them — held two decoded pixmaps instead of one.
     * At a 640 step that is a megabyte or three per tile, times a screen and a
     * half of them, and it is most of half a gigabyte of resident memory doing
     * nothing but remembering a picture that finished fading out.
     *
     * `visible: opacity > 0` had already taken it out of the scene graph, so it
     * cost no blending and nothing on screen said it was there. Only the memory
     * number did.
     *
     * It waits for the animation rather than clearing on the spot: dropping the
     * outgoing frame mid-fade is exactly the black flash the crossfade exists
     * to prevent.
     */
    Timer {
        id: dropSpare
        interval: Appearance.animDur(110) + 60
        onTriggered: root._dropSpare()
    }

    function _dropSpare() {
        const shown = root.visibleLayer;
        // Only when there is definitely a picture on screen to keep. If the
        // visible layer is not ready, or has moved on to a source that has not
        // arrived yet, the outgoing frame is still the only thing being drawn.
        if (shown.status !== Image.Ready || shown.source != root.source)
            return;
        const spare = root.spareLayer;
        /*
         * ONLY THE OLD PICTURE, NEVER THE NEXT ONE.
         *
         * A recycled tile assigns its new source to the spare layer and waits
         * for it. Clearing "the hidden layer" without checking WHAT it holds
         * cancelled those loads mid-flight, so the tile started over — the
         * decode count for a sweep went from 630 to 1102 and a sweep grew a
         * 285 ms hitch. The spare is only stale when it is not the source this
         * tile is currently trying to show.
         */
        if (spare.source != "" && spare.source != root.source)
            spare.source = "";
    }

    Image {
        id: layerA

        // The row this layer's picture belongs to, stamped by `_start`.
        property string forId: ""

        anchors.fill: parent
        anchors.margins: root.contentMargins
        asynchronous: true
        // A fully transparent layer still costs a blend; take it out of the
        // scene instead.
        visible: opacity > 0
        // Smoothing only helps when the pixmap is being scaled, and the ladder
        // step is chosen to match the draw size.
        smooth: root.smoothing
        /*
         * Not cached.
         *
         * With one delegate per item and a screen-and-a-half of cache buffer,
         * a tile that scrolls back is still alive and costs nothing; one that
         * is not is a re-decode of a small local file. Keeping every pixmap
         * ever decoded is what makes memory climb through a long scroll.
         */
        cache: false
        fillMode: root.fillMode
        opacity: root.showingA && root.ownPicture ? 1 : 0
        Behavior on opacity {
            NumberAnimation {
                duration: root._fadeMs
            }
        }
        onStatusChanged: {
            if (status === Image.Ready)
                root._layerReady(layerA);
            else if (status === Image.Error) {
                Perf.errors++;
                Perf.lastError = "error: " + layerA.source.toString().slice(-40);
                root._release();
                root._localVanished(layerA.source);
            }
        }
    }

    Image {
        id: layerB

        property string forId: ""

        anchors.fill: parent
        anchors.margins: root.contentMargins
        asynchronous: true
        visible: opacity > 0
        smooth: root.smoothing
        cache: false
        fillMode: root.fillMode
        opacity: !root.showingA && root.ownPicture ? 1 : 0
        Behavior on opacity {
            NumberAnimation {
                duration: root._fadeMs
            }
        }
        onStatusChanged: {
            if (status === Image.Ready)
                root._layerReady(layerB);
            else if (status === Image.Error) {
                root._release();
                root._localVanished(layerB.source);
            }
        }
    }
}
