import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import qs.modules.common
import qs.modules.widgets
import qs.services

/*
 * One picture, filling the pane, with what you need to decide about it.
 *
 * Deliberately not a lightbox with a caption: the questions being asked here are
 * "is this the right shape for the slot I have in mind", "where did it come
 * from", and "send it there" — so the panel states the real dimensions and
 * aspect, the source and its licence, and the export targets, and the arrow
 * keys step through the result set without going back to the wall.
 *
 * The preview is the daemon's largest ladder step rather than the original:
 * several sources refuse hotlinked requests outright, and a 4000px decode to
 * fill a 900px pane is waste even where they do not.
 */
Item {
    // ── the sidebar's pieces ────────────────────────────────────────────────

    id: root

    property int index: -1
    /*
     * The record on screen — changed only when the PICTURE changes.
     *
     * Opened on a row whose page had not loaded, the viewer stayed empty; a
     * binding that re-read on every page load fixed that and broke everything
     * else, because each read is a fresh copy of the same row: the video
     * restarted every few seconds and a revealed picture blurred itself again.
     * So the row is re-read when pages land, and adopted only if it is a
     * different row (or the first one).
     */
    property var item: null
    // For the `app video` probe: the player, as numbers.
    readonly property alias videoView: video
    readonly property bool posterCovering: preview.visible && video.visible
    /// Set when the search changed under an open picture (a tag was added):
    /// the picture stays until you step or open another.
    property bool _pinned: false
    /*
     * THE PICTURE THAT WAS OPENED, BY ID.
     *
     * An offset is not a picture: the crawl appends rows, a page is re-fetched,
     * and the row at index 40,000 becomes somebody else's. So the viewer is
     * opened WITH the record that was clicked, remembers its id, and follows
     * that id when the numbering moves under it. Without this the viewer opened
     * on an unresolved index simply kept showing the last picture — which is
     * what "it doesn't open the right media" looks like from the outside.
     */
    property string _openedId: ""
    // Whichever is richer: the enriched copy once it lands, the catalogue row
    // until then.
    readonly property var shown: (root.enrichedItem && root.item && root.enrichedItem.id === root.item.id) ? root.enrichedItem : root.item
    /// For the Slideshow: what is open, and how far into it a video is (seconds).
    function videoState() {
        const isVideo = !!root.shown && root.shown.family === "video";
        return {
            "id": root.shown ? String(root.shown.id) : "",
            "video": isVideo,
            "position": isVideo ? (video.probe.position || 0) / 1000 : 0,
            "duration": isVideo ? (video.probe.duration || 0) / 1000 : 0
        };
    }
    /// Covered because it is adult and the setting says so.
    ///
    /// Reset on every item, so stepping through a result with the arrow keys
    /// does not uncover the next picture because you uncovered the last one.
    //
    //     * Whether the side panel is showing. A viewer is for looking at the
    //     * picture; the facts about it are a thing you ask for.
    //     *
    //     * It said exactly that and then defaulted to TRUE with nothing anywhere
    //     * able to close it — so a third of the viewer was permanently spent on
    //     * metadata, and on a video the picture got whatever was left over. It is
    //     * off until asked for now, `i` or the button turns it over, and the choice
    //     * is remembered: this is a habit, not a per-picture decision.
    //
    property bool infoOpen: Prefs.detailInfoOpen
    property bool revealed: false
    readonly property bool blurred: Prefs.blurNsfw && !root.revealed && !!root.shown && root.shown.nsfw === true
    // A picture opened from a menu may have no offset at all — its page has
    // been evicted — and it still opens, on the record itself.
    readonly property bool open: root.index >= 0 || root.item !== null

    /*
     * THE VIEWER TAKES THE SURFACE WHILE IT IS UP — see Host.claimView.
     *
     * The wall underneath never stops being visible, so it cannot notice that
     * it is no longer what you are looking at. Claiming here says so, and the
     * Host's claim stack hands the wall back on close.
     */
    onOpenChanged: {
        if (root.open)
            Host.claimView(sideScroll, root);
        else
            Host.releaseView(root);
    }
    /// Rows that are a still of a video: an engine's result, or a page that
    /// says so. The daemon reads the page and swaps in the real file.
    readonly property bool mightBeVideo: {
        const it = root.shown;
        if (!it || it.family === "video" || !it.page_url || it.page_url.length === 0)
            return false;

        if (["bing", "duckduckgo", "google", "searxng", "qwant", "yandex", "brave"].indexOf(it.source) >= 0)
            return true;

        return /video|clip|watch|tube|gifs?$/i.test(`${it.title || ""} ${it.page_url}`);
    }
    /// Drawn in a window of its own rather than over the gallery.
    property bool inOwnWindow: false
    /// Whether that window is currently filling the screen.
    property bool fullscreen: false
    property var enrichedItem: null
    // The source's own "more like this", when it has one.
    property var related: []
    readonly property string aspectLabel: {
        if (!root.item || root.shown.w <= 0 || root.shown.h <= 0)
            return "—";

        const gcd = (a, b) => {
            return b === 0 ? Math.max(a, 1) : gcd(b, a % b);
        };
        const divisor = gcd(root.shown.w, root.shown.h);
        const rw = root.shown.w / divisor;
        const rh = root.shown.h / divisor;
        // 43:18 is technically right and tells nobody anything.
        return (rw <= 32 && rh <= 32) ? `${rw}:${rh}` : (root.shown.w / root.shown.h).toFixed(2) + ":1";
    }

    signal exportRequested(var item, string targetId)
    signal targetsRequested(var item)
    signal similarRequested(var item, string method)
    signal wallpaperRequested(var item, string monitor)
    signal copyRequested(var item, string what)
    signal openRequested(var item, string where)
    signal hideRequested(var item)
    signal keepRequested(var item)
    /// Asked for the window to fill the screen, or stop. The viewer does not
    /// own a window, so whoever does answers this.
    signal fullscreenToggled()
    /// Asked to move this picture into a window of its own.
    signal windowRequested()

    function _syncItem() {
        // Gone from every page we hold — the offset is all that is left.

        if (root._pinned && root.item)
            return ;

        if (root.index < 0) {
            // close() clears the item; an index-less open keeps the record it
            // was handed.
            if (root._openedId.length === 0)
                root.item = null;

            return ;
        }
        const next = Catalog.itemAt(root.index);
        // The page is not here yet. Keep what was opened rather than the
        // picture before it; the page landing brings us back.
        if (!next)
            return ;

        if (root._openedId.length > 0 && next.id !== root._openedId) {
            const moved = Catalog.indexOfId(root._openedId);
            // Inside the result, not merely found: a result that shrank can
            // hand back an offset that no longer exists, stranding the viewer.
            if (moved >= 0 && moved < Catalog.count) {
                if (moved !== root.index)
                    root.index = moved;
 // re-enters; then the ids agree
                return ;
            }
        }
        if (!root.item || root.item.id !== next.id)
            root.item = next;

        root._openedId = next.id;
    }

    function playFromPage() {
        const before = root.shown;
        Catalog.resolveVideo(before, function(payload) {
            if (!payload || !payload.url || root.shown !== before)
                return ;

            root.item = Object.assign({
            }, before, {
                "family": "video",
                "url": payload.url,
                "duration": payload.duration || before.duration
            });
        });
    }

    /// `item` is the record that was clicked. It is what gets shown; the index
    /// is only where to step from.
    function openAt(index, item) {
        root._pinned = false;
        if (item) {
            root.item = item;
            root._openedId = item.id;
        } else {
            // Opened on an offset alone (the `detail` IPC does this). Keeping
            // the last record would show THAT picture at this offset, which is
            // "it opened the wrong thing" with no way to tell.
            root.item = null;
            root._openedId = "";
        }
        root.index = index;
        root.forceActiveFocus();
        /*
         * OPENING SOMETHING IS AN EVENT SCRIPTS CARE ABOUT.
         *
         * "Fade what I have already seen" is one of the most-installed kinds
         * of userscript on the adult script sites, and every one of them
         * needs exactly this moment: the point where a person chose to look
         * at something. Nothing here records anything — a script does, if it
         * wants to.
         */
        if (Prefs.scriptsEnabled && root.item)
            Scripts.emit("item.open", {
            "item": root.item,
            "index": index
        });

        // Opening something is the moment its details are worth a request.
        root.related = [];
        Catalog.enrich(root.item, function(err, item, related) {
            if (err || !item || !root.item || item.id !== root.item.id)
                return ;

            root.enrichedItem = item;
            root.related = related || [];
        });
    }

    function close() {
        root._pinned = false;
        root._openedId = "";
        root.item = null;
        root.index = -1;
    }

    /// Add a tag to the search you already have, or take it back out — and
    /// stay on this picture, so several can be added in a row.
    function toggleTag(token) {
        const words = (Catalog.query || "").split(/\s+/).filter((w) => {
            return w.length > 0;
        });
        const at = words.indexOf(token);
        if (at >= 0)
            words.splice(at, 1);
        else
            words.push(token);
        root._pinned = true;
        Catalog.query = words.join(" ");
        Toast.show(at >= 0 ? `Removed ${token} from your search` : `Added ${token} to your search`);
    }

    function step(delta) {
        root._pinned = false;
        /*
         * Step from where the picture on screen actually is.
         *
         * `index` can be stale — a tag added under an open picture, or an
         * open with no offset at all — and stepping from a stale number walks
         * off into whatever is there. The id is the truth; the offset is
         * only where to step from.
         */
        const base = root.item ? Catalog.indexOfId(root.item.id) : -1;
        const from = base >= 0 ? base : root.index;
        const next = from + delta;
        if (next >= 0 && next < Catalog.count) {
            // Stepping asks for an OFFSET, so the id being followed is
            // whatever lands there.
            const previous = root.index;
            root._openedId = "";
            root.index = next;
            // Stepping from the id can land on the offset already held — the
            // number does not change, so no notification fires and the picture
            // would not move. Read it here instead.
            if (previous === next)
                root._syncItem();

        }
    }

    function humanBytes(bytes) {
        const units = ["B", "KB", "MB", "GB"];
        let value = bytes;
        let unit = 0;
        while (value >= 1024 && unit < units.length - 1) {
            value /= 1024;
            unit++;
        }
        return unit === 0 ? `${bytes} B` : `${value.toFixed(value >= 100 ? 0 : 1)} ${units[unit]}`;
    }

    function relativeAge(seconds) {
        if (!seconds)
            return "—";

        const delta = Math.max(0, Math.floor(Date.now() / 1000) - seconds);
        if (delta < 90)
            return "just now";

        if (delta < 5400)
            return `${Math.floor(delta / 60)} min ago`;

        if (delta < 172800)
            return `${Math.floor(delta / 3600)} hours ago`;

        return `${Math.floor(delta / 86400)} days ago`;
    }

    onIndexChanged: root._syncItem()
    onInfoOpenChanged: Prefs.detailInfoOpen = root.infoOpen
    onShownChanged: root.revealed = false
    visible: root.open
    focus: root.open
    Keys.onPressed: (event) => {
        /*
         * A video owns a player's keys while one is on screen.
         *
         * The pane below has the whole map — seek, frame step, save the frame,
         * loop, speed — and asked for focus to receive it, but this view takes
         * focus when it opens and never gives it back, so none of it ever ran.
         * It is offered the key first now, and says whether it took it.
         */
        if (video.visible && video.handleKey(event)) {
            event.accepted = true;
            return ;
        }
        switch (event.key) {
        case Qt.Key_Escape:
            // Filling the screen is a state you back out of, the way every
            // player and every browser does, before it closes anything.
            if (root.fullscreen)
                root.fullscreenToggled();
            else
                root.close();
            event.accepted = true;
            break;
        case Qt.Key_F:
        case Qt.Key_F11:
            root.fullscreenToggled();
            event.accepted = true;
            break;
        case Qt.Key_Left:
        case Qt.Key_Up:
            root.step(-1);
            event.accepted = true;
            break;
        case Qt.Key_Right:
        case Qt.Key_Down:
            root.step(1);
            event.accepted = true;
            break;
        case Qt.Key_Space:
            // A still advances; a video would have been handled above, where
            // space plays and pauses as it does in every player.
            root.step(1);
            event.accepted = true;
            break;
        case Qt.Key_I:
            // The panel is a question you ask, so one key asks it and the same
            // key takes it back.
            root.infoOpen = !root.infoOpen;
            event.accepted = true;
            break;
        case Qt.Key_E:
            root.targetsRequested(root.item);
            event.accepted = true;
            break;
        }
    }

    Connections {
        function onPageEpochChanged() {
            root._syncItem();
        }

        function onChanged() {
            root._syncItem();
        }

        target: Catalog
    }

    ItemMenu {
        id: itemMenu

        onExportRequested: (it, targetId) => {
            return root.exportRequested(it, targetId);
        }
        onTargetsRequested: (it) => {
            return root.targetsRequested(it);
        }
        onWallpaperRequested: (it, monitor) => {
            return root.wallpaperRequested(it, monitor);
        }
        onCopyRequested: (it, what) => {
            return root.copyRequested(it, what);
        }
        onOpenRequested: (it, where) => {
            return root.openRequested(it, where);
        }
        onSimilarRequested: (it, method) => {
            return root.similarRequested(it, method);
        }
        onHideRequested: (it) => {
            return root.hideRequested(it);
        }
    }

    // Right-click on Similar: pick HOW to look, the same list the tile menu
    // cascades into.
    MenuPopup {
        id: similarMenu

        function openAt(x, y) {
            similarMenu.x = Math.max(8, Math.min(x, root.width - similarMenu.implicitWidth - 8));
            similarMenu.y = Math.max(8, Math.min(y, root.height - similarMenu.implicitHeight - 8));
            similarMenu.open();
        }

        minWidth: 280

        Repeater {
            model: similarMenu.visible ? Catalog.similarMethods(root.shown) : []

            delegate: MenuRow {
                required property var modelData

                text: modelData.label
                icon: modelData.icon
                hint: modelData.hint
                onTriggered: {
                    similarMenu.close();
                    root.similarRequested(root.shown, modelData.id);
                }
            }

        }

    }

    /*
     * The overlay is modal, and has to actually behave that way.
     *
     * A scrim over a Flickable stops clicks and stops nothing else: the wheel
     * went straight through and scrolled the gallery behind the picture you
     * were looking at. So the wheel is taken here — and rather than swallowing
     * it, it does the obvious thing and steps through the results, which is
     * what a wheel means in something that shows one image at a time.
     */
    WheelHandler {
        property real accumulated: 0

        enabled: root.open
        // Both, so a touchpad is caught as well as a mouse.
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: (event) => {
            /*
             * Accept it, or it keeps going.
             *
             * A handler that acts on a wheel event but never marks it accepted
             * does not consume it — Qt carries on to the handlers underneath,
             * which is how the gallery kept scrolling behind an overlay that
             * was, supposedly, taking the wheel.
             */
            event.accepted = true;
            /*
             * Only over the picture. Scrolling the sidebar is reading the
             * sidebar — it used to step to the next picture at the same time,
             * so the thing you were reading about changed under you.
             */
            const at = mediaPane.mapFromItem(root, event.x, event.y);
            if (at.x < 0 || at.y < 0 || at.x > mediaPane.width || at.y > mediaPane.height) {
                accumulated = 0;
                return ;
            }
            accumulated += event.angleDelta.y;
            // A notch is 120; requiring a full one keeps a touchpad's fine
            // scrolling from flicking through ten pictures at once.
            while (Math.abs(accumulated) >= 120) {
                root.step(accumulated > 0 ? -1 : 1);
                accumulated -= (accumulated > 0 ? 120 : -120);
            }
        }
    }

    // Nothing behind this reacts to hovering either, which is what stops a tile
    // underneath lighting up through the scrim.
    HoverHandler {
        enabled: root.open
        cursorShape: Qt.ArrowCursor
    }

    // A scrim, and a click-out that closes: the wall behind is still the thing
    // you came from.
    Rectangle {
        anchors.fill: parent
        color: Appearance.colors.colLayer0Base
        // Near-opaque: the wall behind is where you came from, not something to
        // read while looking at one picture.
        opacity: 0.985

        // Every button, not just the left one — the same hole the sheets had.
        // `acceptedButtons` defaults to Qt.LeftButton, so a right click here
        // was never accepted and reached the wall behind, opening a tile menu
        // underneath the viewer. Only the left button closes; the rest are
        // swallowed rather than becoming a second way out.
        TapHandler {
            acceptedButtons: Qt.AllButtons
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: (point, button) => {
                if (button === Qt.LeftButton)
                    root.close();

            }
        }

    }

    RowLayout {
        anchors.fill: parent
        anchors.margins: 18
        spacing: 18

        // ── the picture ──────────────────────────────────────────────────────
        Item {
            // The position in the results lives in the viewer bar now.

            id: mediaPane

            Layout.fillWidth: true
            Layout.fillHeight: true

            //
            //             * THE ONE CONTROL THAT ASKS FOR THE FACTS.
            //             *
            //             * `infoOpen` existed, defaulted to on, and had nothing anywhere
            //             * that could turn it off — so the panel was not a thing you asked
            //             * for, it was a thing you lived with. It sits over the picture's
            //             * top-right corner rather than in the panel, because the panel is
            //             * the thing it opens: a button that only exists while what it
            //             * controls is already showing cannot bring it back.
            //
            //
            //             * THE VIEWER'S OWN BAR.
            //             *
            //             * Back, where you are in the results, and the way to the next one —
            //             * the three things a viewer has to answer — in one row over the top
            //             * of the picture, instead of a lone info button in a corner and a
            //             * counter floating under the image.
            //
            RowLayout {
                id: viewerBar

                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                z: 30
                spacing: 8

                Rectangle {
                    implicitWidth: backRow.implicitWidth + 24
                    implicitHeight: 40
                    radius: 20
                    color: backMouse.containsMouse ? Appearance.colors.colLayer2Hover : Appearance.colors.colLayer2

                    Row {
                        id: backRow

                        anchors.centerIn: parent
                        spacing: 6

                        MaterialSymbol {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "arrow_back"
                            iconSize: 20
                            color: Appearance.colors.colOnLayer2
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Back"
                            font.pixelSize: Appearance.font.pixelSize.smallie
                            font.weight: Font.Medium
                            color: Appearance.colors.colOnLayer2
                        }

                    }

                    MouseArea {
                        id: backMouse

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.close()
                    }

                    Behavior on color {
                        animation: Appearance.animation.stateChange.colorAnimation.createObject(this)
                    }

                }

                Item {
                    Layout.fillWidth: true
                }

                Rectangle {
                    implicitWidth: countLabel.implicitWidth + 28
                    implicitHeight: 40
                    radius: 20
                    color: Appearance.colors.colLayer2

                    StyledText {
                        id: countLabel

                        anchors.centerIn: parent
                        text: `${Number(root.index + 1).toLocaleString(Qt.locale("en_US"), "f", 0)} of ${Number(Catalog.count).toLocaleString(Qt.locale("en_US"), "f", 0)}`
                        font.pixelSize: Appearance.font.pixelSize.smallie
                        color: Appearance.colors.colOnLayer2
                    }

                }

                Item {
                    Layout.fillWidth: true
                }

                Rectangle {
                    implicitWidth: navRow.implicitWidth + 8
                    implicitHeight: 40
                    radius: 20
                    color: Appearance.colors.colLayer2

                    Row {
                        id: navRow

                        anchors.centerIn: parent
                        spacing: 0

                        IconButton {
                            icon: "chevron_left"
                            size: 36
                            tooltip: "Previous  (←)"
                            enabled: root.index > 0
                            onClicked: root.step(-1)
                        }

                        IconButton {
                            icon: "chevron_right"
                            size: 36
                            tooltip: "Next  (→)"
                            enabled: root.index + 1 < Catalog.count
                            onClicked: root.step(1)
                        }

                        IconButton {
                            icon: root.infoOpen ? "right_panel_close" : "right_panel_open"
                            size: 36
                            toggled: root.infoOpen
                            tooltip: root.infoOpen ? "Hide details  (i)" : "Show details  (i)"
                            onClicked: root.infoOpen = !root.infoOpen
                        }
                        /*
                         * Both of these live HERE, not in a settings menu.
                         *
                         * "Open media in its own window" was a switch and
                         * nothing else, so the answer to "I want this in a
                         * second window" was to go and find it. A window is
                         * something you ask for about THIS picture, at the
                         * moment you want it.
                         */

                        IconButton {
                            visible: !root.inOwnWindow
                            icon: "open_in_new"
                            size: 36
                            tooltip: "Open in its own window"
                            onClicked: root.windowRequested()
                        }

                        IconButton {
                            icon: root.fullscreen ? "fullscreen_exit" : "fullscreen"
                            size: 36
                            toggled: root.fullscreen
                            tooltip: root.fullscreen ? "Leave full screen  (f)" : "Full screen  (f)"
                            onClicked: root.fullscreenToggled()
                        }

                    }

                }

            }

            // Big, quiet arrows at the edges while the pointer is over the
            // picture: stepping is the most common thing done in here.
            HoverHandler {
                id: paneHover
            }

            Repeater {
                model: [-1, 1]

                delegate: Rectangle {
                    required property int modelData
                    readonly property bool usable: modelData < 0 ? root.index > 0 : root.index + 1 < Catalog.count

                    z: 25
                    anchors.verticalCenter: parent.verticalCenter
                    x: modelData < 0 ? 8 : parent.width - width - 8
                    width: 52
                    height: 52
                    radius: 26
                    color: sideMouse.containsMouse ? Appearance.colors.colLayer3Hover : Appearance.colors.colLayer2
                    opacity: paneHover.hovered && usable ? 0.92 : 0
                    visible: opacity > 0

                    MaterialSymbol {
                        anchors.centerIn: parent
                        text: parent.modelData < 0 ? "chevron_left" : "chevron_right"
                        iconSize: 28
                        color: Appearance.colors.colOnLayer2
                    }

                    MouseArea {
                        id: sideMouse

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.step(parent.modelData)
                    }

                    Behavior on opacity {
                        NumberAnimation {
                            duration: Appearance.animDur(160)
                            easing.type: Easing.OutCubic
                        }

                    }

                }

            }

            // A model is opened, not looked at: the picture is the fallback
            // while it downloads, and the real thing takes over.
            ModelView {
                id: model3d

                anchors.fill: parent
                visible: root.shown && root.shown.family === "model"
                item: visible ? root.shown : null
            }

            /*
             * A video plays here, over its own poster frame.
             *
             * `active` is the overlay being open AND this being the item shown
             * — not just "is a video". A player left decoding behind a closed
             * overlay is a video you cannot see spending a core on it, and the
             * detail view keeps the previous item alive for its close
             * animation, so both conditions are load-bearing.
             */
            VideoView {
                id: video

                anchors.fill: parent
                // Above the poster: its picture is transparent until the first
                // frame, so the poster still shows through — but the controls
                // stay on top and usable while it loads (or when it never does).
                z: 2
                visible: root.shown && root.shown.family === "video"
                item: root.shown
                active: visible && root.open && Prefs.videoAutoplay
                // A running slideshow moves on at the end, so the clip must have one.
                looping: !Scripts.slideshowRunning
                onEnded: Scripts.emit("videoend", { "id": root.shown ? String(root.shown.id) : "" })
                // A frame written out is a real file on disk, so it says where
                // — and puts the path on the clipboard, because the next thing
                // anyone does with it is open it somewhere else.
                onFrameGrabbed: (path) => {
                    Sys.copyText(path);
                    Toast.show("Frame saved — path copied");
                }
            }

            /*
             * The picture you already have, while the one you asked for arrives.
             *
             * The full-size step is a real download now (the daemon fetches the
             * ORIGINAL for anything above a preview, which is the whole reason
             * the detail view stopped being blocky) — so opening an item went
             * from instant-but-soft to a spinner over an empty pane. The wall
             * has already cached a small step for this exact item; showing it
             * costs nothing, and ThumbImage crossfades when the real one lands.
             *
             * Behind the real preview, and only while that is not ready, so it
             * never competes with the picture it is standing in for.
             */
            ThumbImage {
                id: lowres

                anchors.fill: parent
                z: -1
                visible: !preview.ready
                item: root.item
                /*
                 * The step the wall already warmed — a cache hit, never a
                 * fetch. It exists so the pane is never empty while the full
                 * picture arrives; it must not become a second download, which
                 * is the whole complaint it was accused of.
                 */
                size: Catalog.tileThumbSize
                gated: false
                smoothing: true
                fillMode: Image.PreserveAspectFit
            }

            ThumbImage {
                id: preview

                anchors.fill: parent
                // Under the video too: the poster frame is what fills the pane
                // until the first frame decodes, and stays behind it after.
                visible: (!model3d.visible || model3d.modelPath.length === 0) && !video.ready
                item: root.item
                /*
                 * FULL QUALITY, ONCE.
                 *
                 * This picked a ladder step from the pane's width, which meant
                 * opening a picture fetched a *reduction* of it — and since the
                 * wall's tile is already on screen behind, you watched the same
                 * image arrive twice, the second one only slightly better than
                 * the first. That reads as the app loading everything twice,
                 * because it is.
                 *
                 * It asks for the original now. The ladder never upscales, so a
                 * request above the source's own size returns the source: one
                 * fetch, the best there is, and nothing after it.
                 */
                size: 4096
                // There is one of these, and it should not wait behind a wall
                // of tiles for a decode slot.
                gated: false
                /*
                 * ALWAYS smooth here, whatever the tile setting says.
                 *
                 * `Prefs.tileSmoothing` is off by default and it is the right
                 * default for the WALL: tiles are drawn at roughly their native
                 * size, where filtering costs a little per frame and shows
                 * nothing. This is one picture scaled to fill a pane — it is
                 * always being resampled, so nearest-neighbour is visible every
                 * time, as blocky edges going up and shimmer coming down.
                 */
                smoothing: true
                fillMode: Image.PreserveAspectFit
                /*
                 * The same promise as the wall keeps, kept here too.
                 *
                 * A blur that only covers the thumbnail is not a blur — the
                 * next click is the full-size picture. It is one click to
                 * uncover rather than a setting to find, because by the time
                 * you have opened something you have decided to look at it.
                 */
                layer.enabled: root.blurred

                layer.effect: MultiEffect {
                    blurEnabled: true
                    blur: 1
                    blurMax: 64
                    autoPaddingEnabled: false
                }

            }

            Rectangle {
                anchors.centerIn: parent
                width: reveal.implicitWidth + 32
                height: 40
                radius: Appearance.rounding.small
                color: Appearance.colors.colLayer1
                visible: root.blurred

                RowLayout {
                    id: reveal

                    anchors.centerIn: parent
                    spacing: 8

                    MaterialSymbol {
                        text: "visibility"
                        iconSize: 18
                        color: Appearance.colors.colOnLayer1
                    }

                    StyledText {
                        text: "Adult — click to show"
                        color: Appearance.colors.colOnLayer1
                    }

                }

                TapHandler {
                    onTapped: root.revealed = true
                }

            }

            LoadingIndicator {
                anchors.centerIn: parent
                // Only when there is nothing to look at. A spinner over a
                // picture that is already showing reads as "broken", not "busy".
                visible: preview.loading && !lowres.ready
            }

            StyledText {
                anchors.centerIn: parent
                visible: preview.failed
                text: "That source will not serve this image directly."
                color: Appearance.colors.colSubtext
            }

        }

        // ── what it is, and where it can go ──────────────────────────────────
        //
        //         * THE SIDEBAR, IN THE DESKTOP'S OWN LANGUAGE.
        //         *
        //         * Styled after the shell this runs inside (illogical-impulse): the
        //         * panel is the window's darkest layer with a hairline border, and
        //         * everything in it sits on tonal cards one layer up — depth from
        //         * surfaces, never from outlines. Actions are quick-toggle tiles that
        //         * are pills at rest and square off as the pointer reaches them;
        //         * sections fold behind collapsible headers. It reads as part of the
        //         * desktop rather than as a different application's dialog.
        //
        Rectangle {
            id: sidebar

            Layout.preferredWidth: root.infoOpen ? Math.round(Math.min(400, Math.max(280, root.width * 0.27))) : 0
            Layout.fillHeight: true
            visible: Layout.preferredWidth > 0
            clip: true
            radius: 19
            color: Appearance.colors.colLayer0
            border.width: 1
            border.color: Appearance.colors.colLayer0Border

            // Content scrolling up fades out under the header instead of
            // being sliced off at a hard edge.
            Rectangle {
                anchors.top: sideScroll.top
                anchors.left: sideScroll.left
                anchors.right: sideScroll.right
                height: 18
                z: 1
                visible: sideScroll.contentY > 1

                gradient: Gradient {
                    GradientStop {
                        position: 0
                        color: Appearance.colors.colLayer0
                    }

                    GradientStop {
                        position: 1
                        color: ColorUtils.transparentize(Appearance.colors.colLayer0, 1)
                    }

                }

            }

            // ── the header: pinned, never scrolled away ─────────
            SideCard {
                id: headerCard

                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: 10
                // Pinned: the name and the way out stay where you look for
                // them, and the rest scrolls under its edge.
                z: 2

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2

                        StyledText {
                            Layout.fillWidth: true
                            text: {
                                if (!root.shown)
                                    return "";

                                const t = root.shown.title && root.shown.title.length > 0 ? root.shown.title : root.shown.slug;
                                return /^[0-9]+$/.test(String(t)) ? `${root.shown.source} #${t}` : t;
                            }
                            font.family: Appearance.font.family.title
                            font.pixelSize: Appearance.font.pixelSize.larger
                            font.weight: Font.DemiBold
                            color: Appearance.colors.colOnLayer1
                            wrapMode: Text.Wrap
                            maximumLineCount: 3
                            elide: Text.ElideRight
                        }

                        // Facts as small tonal chips rather than a
                        // run-on line of dots.
                        Flow {
                            Layout.fillWidth: true
                            Layout.topMargin: 6
                            spacing: 5

                            Repeater {
                                // Where it is from, what it is and what it is
                                // for — each one searchable, like a tag.
                                model: {
                                    if (!root.shown)
                                        return [];

                                    const out = [{
                                        "label": root.shown.source,
                                        "token": `source:${root.shown.source}`
                                    }];
                                    if (root.shown.family && root.shown.family !== "raster")
                                        out.push({
                                        "label": root.shown.family,
                                        "token": `family:${root.shown.family}`
                                    });

                                    if (root.shown.kind)
                                        out.push({
                                        "label": root.shown.kind,
                                        "token": `kind:${root.shown.kind}`
                                    });

                                    if (root.shown.family !== "vector" && root.shown.w > 0)
                                        out.push({
                                        "label": `${root.shown.w} × ${root.shown.h}`,
                                        "token": ""
                                    });

                                    if (root.shown.duration > 0)
                                        out.push({
                                        "label": `${Math.floor(root.shown.duration / 60)}:${String(Math.floor(root.shown.duration % 60)).padStart(2, "0")}`,
                                        "token": ""
                                    });

                                    if (root.shown.author && root.shown.author.length > 0 && root.shown.author.indexOf(" ") < 0)
                                        out.push({
                                        "label": `by ${root.shown.author}`,
                                        "token": `author:${root.shown.author}`
                                    });

                                    return out;
                                }

                                delegate: QueryChip {
                                    required property var modelData

                                    chipHeight: 28
                                    label: modelData.label
                                    token: modelData.token
                                }

                            }

                        }

                    }

                    IconButton {
                        Layout.alignment: Qt.AlignTop
                        icon: "close"
                        size: 34
                        tooltip: "Close  (Esc)"
                        onClicked: root.close()
                    }

                }

            }

            Flickable {
                id: sideScroll

                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.topMargin: headerCard.height + 20
                anchors.bottomMargin: 10
                // The scrollbar lives in the right-hand gutter, beside the
                // cards rather than over their edges.
                anchors.rightMargin: 4
                contentWidth: width
                contentHeight: infoColumn.implicitHeight
                interactive: contentHeight > height
                boundsBehavior: Flickable.StopAtBounds
                clip: true
                // The side panel is not always up — claim as it appears, not
                // only when the viewer opens, or the claim is refused for
                // being invisible and the wall behind keeps the slot.
                onVisibleChanged: if (root.open)
                    Host.claimView(sideScroll, root)

                ColumnLayout {
                    id: infoColumn

                    // Clear of the scrollbar when there is one.
                    width: sideScroll.width - 12
                    spacing: 10

                    // ── export: to a real destination, in one click ──────
                    //
                    //                     * "Export / Original size" was a button named after a
                    //                     * default nobody chose. The destinations are the point:
                    //                     * the ones you use, as chips you can hit directly, with the
                    //                     * current one as the big tile and what it will produce.
                    //
                    SideCard {
                        id: exportCard

                        readonly property var destinations: {
                            const ids = [];
                            for (const id of Targets.recent.concat(["steam-avatar", "discord-avatar", "x-avatar", "original"])) if (ids.indexOf(id) < 0 && Targets.byId(id)) {
                                ids.push(id);
                            }
                            return ids.slice(0, 5).map((id) => {
                                return Targets.byId(id);
                            });
                        }
                        readonly property var active: Targets.byId(Slots.activeTargetId)

                        padding: 6

                        SideTile {
                            Layout.fillWidth: true
                            implicitHeight: 64
                            primary: true
                            icon: exportCard.active ? exportCard.active.icon : "download"
                            label: Slots.current ? Slots.current.verb : !exportCard.active ? "Export" : exportCard.active.id === "original" ? "Save the original" : `Export for ${exportCard.active.label}`
                            sublabel: {
                                const r = exportCard.active && exportCard.active.recipe;
                                if (!r)
                                    return "";

                                const it = root.shown;
                                const size = r.width > 0 ? `${r.width} × ${r.height}` : "full size";
                                /*
                                 * A recipe's format applies to what it
                                 * re-encodes. "Save the original" re-encodes
                                 * nothing, and a video is copied whatever the
                                 * recipe says — so the card read "full size ·
                                 * PNG" over a clip it was about to save as m4v.
                                 */
                                const untouched = exportCard.active.id === "original" || r.fit === "none" || (it && (it.family === "video" || it.family === "audio"));
                                const format = untouched && it && it.ext ? it.ext : (r.format || "png");
                                return `${size} · ${String(format).toUpperCase()}`;
                            }
                            trailing: "arrow_forward"
                            onClicked: root.exportRequested(root.shown, Slots.activeTargetId)
                        }

                        Flow {
                            Layout.fillWidth: true
                            Layout.leftMargin: 4
                            Layout.rightMargin: 4
                            Layout.topMargin: 2
                            Layout.bottomMargin: 4
                            spacing: 6

                            Repeater {
                                model: exportCard.destinations

                                delegate: Rectangle {
                                    id: destChip

                                    required property var modelData
                                    readonly property bool current: exportCard.active && exportCard.active.id === modelData.id

                                    implicitHeight: 34
                                    implicitWidth: destRow.implicitWidth + 24
                                    radius: destMouse.containsMouse ? Appearance.rounding.small : height / 2
                                    color: destChip.current ? Appearance.colors.colSecondaryContainer : destMouse.containsMouse ? Appearance.colors.colLayer3Hover : Appearance.colors.colLayer2

                                    Row {
                                        id: destRow

                                        anchors.centerIn: parent
                                        spacing: 6

                                        MaterialSymbol {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: destChip.modelData.icon
                                            iconSize: 17
                                            color: destChip.current ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer2
                                        }

                                        StyledText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: destChip.modelData.label
                                            font.pixelSize: Appearance.font.pixelSize.smaller
                                            color: destChip.current ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer2
                                        }

                                    }

                                    MouseArea {
                                        id: destMouse

                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.exportRequested(root.shown, destChip.modelData.id)
                                    }

                                    StyledToolTip {
                                        visible: destMouse.containsMouse
                                        text: `Export for ${destChip.modelData.label}`
                                    }

                                    Behavior on radius {
                                        NumberAnimation {
                                            duration: Appearance.animation.elementMoveFast.duration
                                            easing.type: Easing.OutCubic
                                        }

                                    }

                                    Behavior on color {
                                        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(destChip)
                                    }

                                }

                            }

                            // Everything else, with a crop you can adjust.
                            Rectangle {
                                id: moreChip

                                implicitHeight: 34
                                implicitWidth: moreRow.implicitWidth + 24
                                radius: moreMouse.containsMouse ? Appearance.rounding.small : height / 2
                                color: moreMouse.containsMouse ? Appearance.colors.colLayer3Hover : "transparent"
                                border.width: 1
                                border.color: Appearance.colors.colOutlineVariant

                                Row {
                                    id: moreRow

                                    anchors.centerIn: parent
                                    spacing: 6

                                    MaterialSymbol {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "crop"
                                        iconSize: 17
                                        color: Appearance.colors.colOnLayer1
                                    }

                                    StyledText {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "More & crop…"
                                        font.pixelSize: Appearance.font.pixelSize.smaller
                                        color: Appearance.colors.colOnLayer1
                                    }

                                }

                                MouseArea {
                                    id: moreMouse

                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.targetsRequested(root.shown)
                                }

                                Behavior on radius {
                                    NumberAnimation {
                                        duration: Appearance.animation.elementMoveFast.duration
                                        easing.type: Easing.OutCubic
                                    }

                                }

                            }

                        }

                    }

                    // ── quick actions: square tiles, icon over label ─────
                    SideCard {
                        padding: 6

                        GridLayout {
                            Layout.fillWidth: true
                            columns: 3
                            rowSpacing: 6
                            columnSpacing: 6

                            Repeater {
                                model: [{
                                    "icon": "play_circle",
                                    "label": "Play video",
                                    "act": "resolve",
                                    "only": root.mightBeVideo
                                }, {
                                    "icon": "content_copy",
                                    "label": "Copy",
                                    "act": "copy-image"
                                }, {
                                    "icon": "bookmark_add",
                                    "label": "Keep",
                                    "act": "keep"
                                }, {
                                    "icon": "image_search",
                                    "label": "Similar",
                                    "act": "similar"
                                }, {
                                    "icon": "dashboard_customize",
                                    "label": "Board",
                                    "act": "board"
                                }, {
                                    "icon": "link",
                                    "label": "Link",
                                    "act": "copy-url"
                                }, {
                                    "icon": "open_in_new",
                                    "label": "Source",
                                    "act": "page"
                                }]

                                delegate: Rectangle {
                                    id: quick

                                    required property var modelData
                                    readonly property bool usable: {
                                        if (modelData.act === "page")
                                            return !!root.shown && !!root.shown.page_url && root.shown.page_url.length > 0;

                                        if (modelData.act === "similar")
                                            return !!root.shown && ((root.shown.phash && root.shown.phash.length > 0) || (root.shown.dominant && root.shown.dominant.length > 0));

                                        return true;
                                    }

                                    // `only` is a condition the tile exists under at all —
                                    // "Play video" has nothing to do on a picture.
                                    visible: quick.modelData.only === undefined || quick.modelData.only
                                    Layout.fillWidth: true
                                    implicitHeight: visible ? 72 : 0
                                    opacity: usable ? 1 : 0.4
                                    radius: quickMouse.containsPress ? Appearance.rounding.small : quickMouse.containsMouse ? Appearance.rounding.normal : Appearance.rounding.large
                                    color: quickMouse.containsPress ? Appearance.colors.colLayer2Active : quickMouse.containsMouse ? Appearance.colors.colLayer2Hover : Appearance.colors.colLayer2

                                    Column {
                                        anchors.centerIn: parent
                                        spacing: 6

                                        MaterialSymbol {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: quick.modelData.icon
                                            iconSize: 24
                                            color: Appearance.colors.colOnLayer2
                                        }

                                        StyledText {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: quick.modelData.label
                                            font.pixelSize: Appearance.font.pixelSize.smaller
                                            color: Appearance.colors.colOnLayer2
                                        }

                                    }

                                    StyledToolTip {
                                        visible: quickMouse.containsMouse && quick.modelData.act === "similar"
                                        text: "Find similar everywhere  ·  right-click to choose how"
                                    }

                                    MouseArea {
                                        id: quickMouse

                                        anchors.fill: parent
                                        hoverEnabled: true
                                        enabled: quick.usable
                                        cursorShape: Qt.PointingHandCursor
                                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                                        onClicked: (mouse) => {
                                            if (mouse.button === Qt.RightButton) {
                                                if (quick.modelData.act === "similar") {
                                                    const at = quickMouse.mapToItem(root, mouse.x, mouse.y);
                                                    similarMenu.openAt(at.x, at.y);
                                                }
                                                return ;
                                            }
                                            switch (quick.modelData.act) {
                                            case "copy-image":
                                                root.copyRequested(root.shown, "image");
                                                break;
                                            case "keep":
                                                root.keepRequested(root.shown);
                                                break;
                                            case "resolve":
                                                root.playFromPage();
                                                break;
                                            case "similar":
                                                root.similarRequested(root.shown, "all");
                                                break;
                                            case "board":
                                                // Catalog says where it went.
                                                Catalog.placeOnBoardNamed(Catalog.boards.length > 0 ? Catalog.boards[0].name : "Reference", root.shown);
                                                break;
                                            case "copy-url":
                                                root.copyRequested(root.shown, "url");
                                                break;
                                            case "page":
                                                root.openRequested(root.shown, "page");
                                                break;
                                            }
                                        }
                                    }

                                    Behavior on radius {
                                        NumberAnimation {
                                            duration: Appearance.animation.elementMoveFast.duration
                                            easing.type: Easing.OutCubic
                                        }

                                    }

                                    Behavior on color {
                                        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(quick)
                                    }

                                }

                            }

                        }

                    }

                    // ── wallpaper ───────────────────────────────────────
                    SideCard {
                        padding: 6
                        visible: !!root.shown && root.shown.family !== "vector" && root.shown.family !== "model" && !(Slots.current && Slots.current.targetId.startsWith("wallpaper-"))

                        SideHeader {
                            id: wallpaperHeader

                            icon: "wallpaper"
                            title: "Set as wallpaper"
                            value: {
                                const n = Targets.all.filter((t) => {
                                    return t.group === "Desktop";
                                }).length;
                                return `${n} display${n === 1 ? "" : "s"}`;
                            }
                            open: true
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            visible: wallpaperHeader.open

                            Repeater {
                                model: Targets.all.filter((t) => {
                                    return t.group === "Desktop";
                                })

                                delegate: SideTile {
                                    required property var modelData
                                    readonly property string output: modelData.id.replace("wallpaper-", "")

                                    Layout.fillWidth: true
                                    icon: output.startsWith("eDP") || output.startsWith("LVDS") ? "laptop" : "desktop_windows"
                                    label: output.startsWith("eDP") || output.startsWith("LVDS") ? "Built-in display" : "External display"
                                    sublabel: `${output} · ${modelData.recipe.width} × ${modelData.recipe.height}`
                                    trailing: "arrow_forward"
                                    onClicked: root.wallpaperRequested(root.shown, modelData.id)
                                }

                            }

                        }

                    }

                    // ── about ───────────────────────────────────────────
                    // ── tags ────────────────────────────────────────────
                    SideCard {
                        padding: 6
                        visible: !!root.shown && !!root.shown.tags && root.shown.tags.length > 0

                        SideHeader {
                            id: tagsHeader

                            icon: "sell"
                            title: "Tags"
                            value: root.shown && root.shown.tags ? `${root.shown.tags.length}` : ""
                            open: true
                        }

                        Flow {
                            Layout.fillWidth: true
                            Layout.leftMargin: 6
                            Layout.rightMargin: 6
                            Layout.bottomMargin: 6
                            spacing: 6
                            visible: tagsHeader.open

                            Repeater {
                                model: (root.shown && root.shown.tags) ? root.shown.tags.slice(0, 24) : []

                                delegate: QueryChip {
                                    required property string modelData

                                    label: modelData
                                    token: `tag:${String(modelData).replace(/\s+/g, "_")}`
                                }

                            }

                        }

                    }

                    SideCard {
                        padding: 6

                        SideHeader {
                            id: aboutHeader

                            icon: "info"
                            title: "About"
                            value: root.shown && root.shown.author && root.shown.author.length > 0 ? root.shown.author : (root.shown ? root.shown.source : "")
                            open: true
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.leftMargin: 10
                            Layout.rightMargin: 10
                            Layout.bottomMargin: 6
                            spacing: 8
                            visible: aboutHeader.open

                            GridLayout {
                                Layout.fillWidth: true
                                columns: 2
                                columnSpacing: 14
                                rowSpacing: 6

                                Repeater {
                                    model: root.shown ? [["Size", root.shown.family === "vector" ? "Vector · any size" : `${root.shown.w} × ${root.shown.h}`], ["Aspect", root.shown.family === "vector" ? "" : root.aspectLabel], ["Type", `${root.shown.kind} · ${root.shown.family}`], ["Source", root.shown.source], ["Author", root.shown.author && root.shown.author.length > 0 ? root.shown.author : "—"], ["Licence", root.shown.license && root.shown.license.length > 0 ? root.shown.license : "—"], ["File", root.shown.bytes > 0 ? root.humanBytes(root.shown.bytes) + " · " + root.shown.ext : (root.shown.ext || "—")], ["Found", root.relativeAge(root.shown.added_at)]].filter((p) => {
                                        return p[1] && p[1] !== "—" && p[1].length > 0;
                                    }).reduce((acc, p) => {
                                        return acc.concat(p);
                                    }, []) : []

                                    delegate: StyledText {
                                        required property var modelData
                                        required property int index

                                        Layout.fillWidth: index % 2 === 1
                                        text: modelData
                                        font.pixelSize: Appearance.font.pixelSize.smallie
                                        color: index % 2 === 0 ? Appearance.colors.colSubtext : Appearance.colors.colOnLayer1
                                        elide: Text.ElideRight
                                    }

                                }

                            }

                            SideTile {
                                Layout.fillWidth: true
                                visible: !!root.shown && !!root.shown.dominant && root.shown.dominant.length > 0
                                swatch: root.shown && root.shown.dominant ? root.shown.dominant : ""
                                label: root.shown && root.shown.dominant ? root.shown.dominant.toUpperCase() : ""
                                sublabel: "Find pictures in this colour"
                                trailing: "palette"
                                onClicked: {
                                    Catalog.query = `color:${root.shown.dominant} dist<25`;
                                    root.close();
                                }
                            }

                        }

                    }

                    // ── the source's own "more like this" ───────────────
                    SideCard {
                        padding: 6
                        visible: root.related.length > 0

                        SideHeader {
                            id: relatedHeader

                            icon: "collections"
                            title: "More like this"
                            value: `${Math.min(8, root.related.length)}`
                            open: true
                        }

                        Flow {
                            Layout.fillWidth: true
                            Layout.margins: 6
                            spacing: 6
                            visible: relatedHeader.open

                            Repeater {
                                model: root.related.slice(0, 8)

                                delegate: Rectangle {
                                    required property string modelData

                                    width: 64
                                    height: 64
                                    radius: Appearance.rounding.small
                                    color: Appearance.colors.colLayer2
                                    clip: true

                                    Image {
                                        anchors.fill: parent
                                        asynchronous: true
                                        cache: false
                                        fillMode: Image.PreserveAspectCrop
                                        sourceSize.width: 128
                                        source: `https://cdn.pfps.gg/pfps/${parent.modelData}.png`
                                        onStatusChanged: {
                                            if (status === Image.Error) {
                                                source = `https://cdn.pfps.gg/pfps/${parent.modelData}.jpeg`;
                                            }
                                        }
                                    }

                                    TapHandler {
                                        onTapped: {
                                            Catalog.query = `id:pfps.gg:${parent.modelData}`;
                                            root.close();
                                        }
                                    }

                                }

                            }

                        }

                    }

                    // ── footer ──────────────────────────────────────────
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: 6
                        Layout.rightMargin: 2
                        Layout.topMargin: 2
                        spacing: 6

                        Repeater {
                            model: [["←→", "step"], ["E", "export"], ["i", "details"]]

                            delegate: Row {
                                required property var modelData

                                spacing: 4

                                Rectangle {
                                    width: keyLabel.implicitWidth + 10
                                    height: 18
                                    radius: 5
                                    color: Appearance.colors.colLayer2

                                    StyledText {
                                        id: keyLabel

                                        anchors.centerIn: parent
                                        text: modelData[0]
                                        font.pixelSize: Appearance.font.pixelSize.smallest
                                        color: Appearance.colors.colSubtext
                                    }

                                }

                                StyledText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: modelData[1]
                                    font.pixelSize: Appearance.font.pixelSize.smallest
                                    color: Appearance.colors.colSubtext
                                }

                            }

                        }

                        Item {
                            Layout.fillWidth: true
                        }

                        // Quiet until reached for: the one destructive action.
                        TextButton {
                            text: "Hide"
                            icon: "visibility_off"
                            destructive: true
                            onClicked: root.hideRequested(root.shown)
                        }

                    }

                }

                ScrollBar.vertical: StyledScrollBar {
                    policy: parent.contentHeight > parent.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                    opacity: 0.32
                }

            }

            Behavior on Layout.preferredWidth {
                NumberAnimation {
                    duration: Appearance.animDur(300)
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Appearance.animationCurves.emphasizedDecel
                }

            }

        }

    }

    /*
     * A FACT YOU CAN SEARCH BY — source, kind, family, tag.
     *
     * Each is two things you might want: "show me this" and "add this to what
     * I am already looking at". The chip is the first, its + is the second,
     * and one already in the search is highlighted with a check that takes it
     * back out. A chip with no token (a size, a duration) is just a label.
     */
    component QueryChip: Rectangle {
        id: chip

        property string label: ""
        property string token: ""
        property real chipHeight: 30
        readonly property bool searchable: chip.token.length > 0
        readonly property bool inQuery: chip.searchable && (Catalog.query || "").split(/\s+/).indexOf(chip.token) >= 0
        readonly property bool hovered: chipMouse.containsMouse || addMouse.containsMouse
        readonly property color fg: chip.inQuery ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer3

        implicitHeight: chip.chipHeight
        implicitWidth: chipText.implicitWidth + 24 + (chip.searchable ? addButton.width - 6 : 0)
        radius: chip.searchable && chip.hovered ? Appearance.rounding.small : height / 2
        color: chip.inQuery ? Appearance.colors.colSecondaryContainer : chipMouse.containsPress ? Appearance.colors.colLayer3Active : chip.searchable && chip.hovered ? Appearance.colors.colLayer3Hover : Appearance.colors.colLayer3

        StyledText {
            id: chipText

            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: chip.label
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: chip.fg
        }

        MouseArea {
            id: chipMouse

            anchors.fill: parent
            anchors.rightMargin: chip.searchable ? addButton.width : 0
            enabled: chip.searchable
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: (mouse) => {
                if (mouse.button === Qt.RightButton) {
                    root.toggleTag(chip.token);
                    return ;
                }
                Catalog.query = chip.token;
                root.close();
            }
        }

        StyledToolTip {
            visible: chipMouse.containsMouse
            text: `Show everything with ${chip.token}  ·  right-click to add it to your search`
        }

        Rectangle {
            id: addButton

            visible: chip.searchable
            anchors.right: parent.right
            anchors.rightMargin: 2
            anchors.verticalCenter: parent.verticalCenter
            width: chip.chipHeight - 4
            height: chip.chipHeight - 4
            radius: height / 2
            color: addMouse.containsMouse ? ColorUtils.transparentize(chip.fg, 0.85) : "transparent"

            MaterialSymbol {
                anchors.centerIn: parent
                text: chip.inQuery ? "check" : "add"
                iconSize: 16
                color: chip.fg
                // Quiet until the chip is reached for — the + is for the
                // second intent, not the first thing you see.
                opacity: chip.inQuery || chip.hovered ? 1 : 0.45
            }

            MouseArea {
                id: addMouse

                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleTag(chip.token)
            }

            StyledToolTip {
                visible: addMouse.containsMouse
                text: chip.inQuery ? "Remove from your search" : "Add to your search"
            }

        }

        Behavior on radius {
            NumberAnimation {
                duration: Appearance.animation.elementMoveFast.duration
                easing.type: Easing.OutCubic
            }

        }

        Behavior on color {
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(chip)
        }

    }

    /// A tonal card on the sidebar: one surface layer up, no border.
    component SideCard: Rectangle {
        id: card

        property int padding: 12
        default property alias body: cardColumn.data

        Layout.fillWidth: true
        implicitHeight: cardColumn.implicitHeight + card.padding * 2
        radius: Appearance.rounding.normal
        color: Appearance.colors.colLayer1

        ColumnLayout {
            id: cardColumn

            x: card.padding
            y: card.padding
            width: card.width - card.padding * 2
            spacing: 6
        }

    }

    /*
     * A quick-toggle tile: a pill at rest that squares off to a rounded
     * rectangle under the pointer and further while pressed — the shell's own
     * shape morph. `primary` is the filled accent tile; the rest are tonal.
     */
    component SideTile: Rectangle {
        id: tile

        property string icon: ""
        property string label: ""
        property string sublabel: ""
        property string trailing: ""
        property string swatch: ""
        property bool primary: false
        property bool danger: false
        readonly property color base: tile.primary ? Appearance.colors.colPrimary : tile.danger ? Appearance.colors.colErrorContainer : Appearance.colors.colLayer2
        readonly property color fg: tile.primary ? Appearance.colors.colOnPrimary : tile.danger ? Appearance.colors.colOnErrorContainer : Appearance.colors.colOnLayer2

        signal clicked()

        implicitHeight: tile.sublabel.length > 0 ? 56 : 48
        implicitWidth: tileRow.implicitWidth + 28
        opacity: tile.enabled ? 1 : 0.4
        radius: tileMouse.containsPress ? Appearance.rounding.normal : tileMouse.containsMouse ? Appearance.rounding.large : Math.min(height / 2, 28)
        color: tileMouse.containsPress ? ColorUtils.mix(tile.base, tile.fg, 0.82) : tileMouse.containsMouse ? ColorUtils.mix(tile.base, tile.fg, 0.9) : tile.base

        RowLayout {
            id: tileRow

            anchors.fill: parent
            anchors.leftMargin: 14
            anchors.rightMargin: 14
            spacing: 10

            Rectangle {
                visible: tile.swatch.length > 0
                Layout.preferredWidth: 24
                Layout.preferredHeight: 24
                radius: 12
                color: tile.swatch.length > 0 ? tile.swatch : "transparent"
                border.width: 1
                border.color: Appearance.colors.colOutlineVariant
            }

            MaterialSymbol {
                visible: tile.icon.length > 0
                text: tile.icon
                iconSize: 22
                fill: tile.primary ? 1 : 0
                color: tile.fg
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                StyledText {
                    Layout.fillWidth: true
                    text: tile.label
                    elide: Text.ElideRight
                    font.pixelSize: Appearance.font.pixelSize.smallie
                    font.weight: Font.Medium
                    color: tile.fg
                }

                StyledText {
                    Layout.fillWidth: true
                    visible: tile.sublabel.length > 0
                    text: tile.sublabel
                    elide: Text.ElideRight
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: tile.fg
                    opacity: 0.75
                }

            }

            MaterialSymbol {
                visible: tile.trailing.length > 0
                text: tile.trailing
                iconSize: 18
                color: tile.fg
                opacity: 0.8
            }

        }

        MouseArea {
            id: tileMouse

            anchors.fill: parent
            hoverEnabled: true
            enabled: tile.enabled
            cursorShape: Qt.PointingHandCursor
            onClicked: tile.clicked()
        }

        Behavior on radius {
            NumberAnimation {
                duration: Appearance.animation.elementMoveFast.duration
                easing.type: Appearance.animation.elementMoveFast.type
                easing.bezierCurve: Appearance.animation.elementMoveFast.bezierCurve
            }

        }

        Behavior on color {
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(tile)
        }

    }

    /// A collapsible section header: icon, title, a quiet value, and a chevron.
    component SideHeader: Rectangle {
        id: header

        property string icon: ""
        property string title: ""
        property string value: ""
        property bool open: true

        Layout.fillWidth: true
        implicitHeight: 46
        radius: Appearance.rounding.small
        color: headerMouse.containsMouse ? Appearance.colors.colLayer1Hover : ColorUtils.transparentize(Appearance.colors.colLayer1Hover, 1)

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            spacing: 10

            MaterialSymbol {
                text: header.icon
                iconSize: 20
                color: Appearance.colors.colOnLayer1
            }

            StyledText {
                text: header.title
                font.pixelSize: Appearance.font.pixelSize.smallie
                font.weight: Font.Medium
                color: Appearance.colors.colOnLayer1
            }

            StyledText {
                Layout.fillWidth: true
                text: header.value
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignRight
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colSubtext
            }

            MaterialSymbol {
                text: "keyboard_arrow_down"
                iconSize: 20
                color: Appearance.colors.colSubtext
                rotation: header.open ? 180 : 0

                Behavior on rotation {
                    NumberAnimation {
                        duration: Appearance.animation.elementMoveFast.duration
                        easing.type: Easing.OutCubic
                    }

                }

            }

        }

        MouseArea {
            id: headerMouse

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: header.open = !header.open
        }

        Behavior on color {
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(header)
        }

    }

}
