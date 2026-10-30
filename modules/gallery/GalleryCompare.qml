import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick

/*
 * Compare — two to four finalists, side by side, at exactly the same size.
 *
 * The wall answers "what is there"; this answers the last question before an
 * export: "which of these". That only works if the candidates are the same
 * size, so every pane is the same width and the picture is fitted, never
 * cropped — a crop would be the layout deciding part of what you are judging.
 *
 * **The window moves, the panes do not.** The selection is the current result
 * index and the N-1 after it, so stepping is one arrow key and never a
 * click-to-select dance: left and right slide the whole comparison through the
 * result set. It is a horizontal ListView over the same windowed model every
 * other layout uses, so Qt creates a pane as it approaches the viewport and
 * destroys it after it leaves — `reuseItems: false` for the same reason as the
 * wall, because re-pointing a live pane at another item is a picture that
 * blinks while you are looking straight at it.
 *
 * **Keep is the exit.** Choosing one runs the export flow for it and the
 * others fade out and give it the pane — the comparison is over, and a layout
 * that still shows four candidates after you picked one is asking you to pick
 * again.
 */
Item {
    id: root

    // 2–4: past four the panes are smaller than the detail view and the
    // comparison stops being one.
    property int upTo: 3
    property real gap: 10

    signal activated(var item, int index)
    signal contextRequested(var item, real sceneX, real sceneY)
    signal quickExport(var item)

    /*
     * The leftmost pane's result index — derived from the scroll position, not
     * bound to it. A ListView owns its own `contentX`; binding it fights that
     * ownership and Qt settles the fight by ignoring the binding (see the same
     * note in GalleryWall).
     */
    property int startIndex: 0

    // Set by keep(): the losers fade first, then the winner takes the pane.
    property string keptId: ""
    property bool collapsed: false

    readonly property int panes: root.collapsed ? 1 : Math.max(2, Math.min(4, root.upTo))
    readonly property real paneWidth: Math.max(80, (root.width - root.gap * (root.panes + 1)) / root.panes)
    readonly property real stride: root.paneWidth + root.gap

    /*
     * Ladder step for a pane, in real pixels.
     *
     * A pane is several times a wall tile, so asking for the tile step would
     * upscale a 320px thumbnail across a third of the window — which is the
     * one thing this layout must not do, since it exists to show what the
     * picture actually looks like.
     */
    readonly property int ladder: {
        const want = Math.ceil(root.paneWidth * (Screen.devicePixelRatio || 1));
        for (const step of [320, 640, 1280])
            if (step >= want)
                return step;
        return 1280;
    }

    function moveTo(index) {
        const last = Math.max(0, Catalog.count - root.panes);
        const target = Math.max(0, Math.min(index, last));
        sweep.stop();
        glide.stop();
        glide.from = list.contentX;
        glide.to = target * root.stride;
        glide.start();
        if (target + root.panes * 4 > Catalog.count)
            Catalog.loadMore();
    }

    // Keep this one: export it, then let it have the pane to itself.
    function keep(record) {
        if (!record)
            return;
        root.keptId = record.id;
        root.quickExport(record);
        collapse.restart();
    }

    function reset() {
        const at = root.startIndex;
        root.keptId = "";
        root.collapsed = false;
        // After the pane count changes every delegate is a different width, so
        // the position is only meaningful once that has been laid out.
        Qt.callLater(() => list.positionViewAtIndex(at, ListView.Beginning));
    }

    Timer {
        id: collapse
        interval: Appearance.animDur(200)
        onTriggered: {
            const winner = root.startIndex + root.keptPane;
            root.collapsed = true;
            Qt.callLater(() => list.positionViewAtIndex(winner, ListView.Beginning));
        }
    }

    // Which of the visible panes was kept, so the collapse lands on it rather
    // than on whatever happens to be leftmost.
    property int keptPane: 0

    // The perf harness drives whichever layout is showing, and for this one a
    // sweep is a genuine worst case: full-pane pictures created and destroyed
    // several at a time.
    function scrollTest(durationMs, distancePx) {
        glide.stop();
        sweep.stop();
        list.contentX = 0;
        sweep.from = 0;
        sweep.to = Math.min(distancePx, Math.max(0, list.contentWidth - list.width));
        sweep.duration = durationMs;
        Perf.beginMeasure();
        sweep.start();
    }

    NumberAnimation {
        id: sweep
        target: list
        property: "contentX"
        easing.type: Easing.Linear
        onFinished: Perf.endMeasure()
    }

    NumberAnimation {
        id: glide
        target: list
        property: "contentX"
        duration: Appearance.animDur(180)
        easing.type: Easing.OutCubic
    }

    // Arrow keys move the whole comparison; the number keys keep a pane, which
    // is the only two-handed thing this layout asks for.
    focus: root.visible && root.enabled
    Keys.onPressed: event => {
        switch (event.key) {
        case Qt.Key_Left:
            root.moveTo(root.startIndex - 1);
            event.accepted = true;
            break;
        case Qt.Key_Right:
            root.moveTo(root.startIndex + 1);
            event.accepted = true;
            break;
        case Qt.Key_Up:
        case Qt.Key_PageUp:
            root.moveTo(root.startIndex - root.panes);
            event.accepted = true;
            break;
        case Qt.Key_Down:
        case Qt.Key_PageDown:
            root.moveTo(root.startIndex + root.panes);
            event.accepted = true;
            break;
        case Qt.Key_1:
        case Qt.Key_2:
        case Qt.Key_3:
        case Qt.Key_4:
            {
                const which = event.key - Qt.Key_1;
                // Nothing at that offset yet means nothing to keep — better
                // than keeping whatever lands there a moment later.
                const picked = which < root.panes ? Catalog.itemAt(root.startIndex + which) : null;
                if (picked) {
                    root.keptPane = which;
                    root.keep(picked);
                }
                event.accepted = true;
                break;
            }
        case Qt.Key_Escape:
            if (root.keptId.length > 0) {
                root.reset();
                event.accepted = true;
            }
            break;
        }
    }

    // ── how many, and where in the results ───────────────────────────────────
    Row {
        id: bar
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.rightMargin: root.gap
        height: 34
        spacing: 6
        visible: !root.collapsed

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            rightPadding: 8
            text: Catalog.count > 0 ? `${root.startIndex + 1}–${Math.min(Catalog.count, root.startIndex + root.panes)} of ${Catalog.count}` : ""
            font.family: Appearance.font.family.monospace
            font.pixelSize: Appearance.font.pixelSize.smallest
            color: Appearance.colors.colSubtext
        }

        Repeater {
            model: [2, 3, 4]

            delegate: PillTab {
                required property int modelData
                label: String(modelData)
                active: root.upTo === modelData
                accent: "primary"
                horizontalPadding: 10
                verticalPadding: 5
                onTriggered: root.upTo = modelData
            }
        }
    }

    ListView {
        id: list
        // The wheel steps this strip (handler below); this tells the window's
        // MomentumInjector the list is taken, so it does not add a pixel scroller.
        Item {
            readonly property Item flickable: list
        }
        anchors.fill: parent
        anchors.topMargin: bar.visible ? bar.height + 4 : 0
        anchors.leftMargin: root.gap
        anchors.rightMargin: root.gap
        anchors.bottomMargin: kept.visible ? kept.height + root.gap : 0
        orientation: ListView.Horizontal
        clip: true
        model: Catalog.count
        spacing: root.gap
        // A pane on either side of the comparison, so an arrow key shows a
        // picture rather than a placeholder that fills in afterwards.
        cacheBuffer: Math.ceil(root.paneWidth * 2)
        // Same reason as the wall: a delegate re-pointed at another item while
        // it is on screen is a picture that blinks.
        reuseItems: false
        // While one is kept the comparison is decided; letting it be dragged
        // would silently un-decide it.
        interactive: !root.collapsed
        flickDeceleration: Appearance.scroll.deceleration
        maximumFlickVelocity: Appearance.scroll.maxVelocity
        snapMode: ListView.SnapToItem

        onContentXChanged: {
            root.startIndex = Math.max(0, Math.round(list.contentX / root.stride));
            if (contentWidth <= 0)
                return;
            if (contentX + width > contentWidth - width)
                Catalog.loadMore();
        }

        // A result set that does not fill the panes is already at its end and
        // would otherwise wait for a scroll that never comes.
        onCountChanged: {
            if (contentWidth > 0 && contentWidth <= width * 2)
                Catalog.loadMore();
        }

        delegate: Item {
            id: pane
            required property int index

            /*
             * Assigned, and re-assigned when a page lands.
             *
             * `Catalog.itemAt(index)` in a binding reads a page map that is
             * mutated rather than reassigned, so the binding never re-runs and
             * a pane created before its page arrived stays empty for ever.
             */
            property var record: null

            function refill() {
                pane.record = Catalog.itemAt(pane.index);
            }

            Component.onCompleted: pane.refill()
            onIndexChanged: pane.refill()

            Connections {
                target: Catalog
                function onPageEpochChanged() {
                    if (!pane.record)
                        pane.refill();
                }
                function onChanged() {
                    pane.refill();
                }
            }

            width: root.paneWidth
            height: list.height

            readonly property bool isKept: root.keptId.length > 0 && pane.record && pane.record.id === root.keptId
            readonly property bool dropped: root.keptId.length > 0 && !pane.isKept

            opacity: pane.dropped ? 0 : 1
            scale: pane.dropped ? 0.94 : 1

            Behavior on opacity {
                NumberAnimation {
                    duration: Appearance.animDur(180)
                }
            }

            Behavior on scale {
                NumberAnimation {
                    duration: Appearance.animDur(180)
                    easing.type: Easing.OutCubic
                }
            }

            Rectangle {
                anchors.fill: parent
                radius: Appearance.rounding.normal
                color: Appearance.colors.colLayer2
                border.width: pane.isKept ? 2 : (paneHover.hovered ? 1 : 0)
                border.color: pane.isKept ? Appearance.colors.colPrimary : Appearance.colors.colLayer0Border

                ThumbImage {
                    id: picture
                    anchors.fill: parent
                    anchors.margins: 10
                    anchors.bottomMargin: facts.height + 6
                    item: pane.record
                    size: root.ladder
                    // Whole picture, never cropped: a crop here would be the
                    // layout choosing part of what is being judged.
                    fillMode: Image.PreserveAspectFit
                    // Line art on transparency reads as a photo bleeding to the
                    // edge unless it is inset — the same treatment the tiles
                    // give a vector, so a candidate does not change character
                    // between the wall and the comparison.
                    contentMargins: pane.record && pane.record.family === "vector" ? Math.round(picture.width * 0.12) : 0
                    priority: Math.abs(pane.x - (list.contentX + list.width / 2))
                }

                MaterialSymbol {
                    anchors.centerIn: picture
                    visible: !picture.ready
                    text: "compare"
                    iconSize: 32
                    color: Appearance.colors.colOnLayer1Inactive
                }

                // The keyboard hint, which is also the pane's position in the
                // comparison rather than in the catalogue.
                Rectangle {
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.margins: 10
                    width: 24
                    height: 24
                    radius: Appearance.rounding.full
                    visible: !root.collapsed && pane.index >= root.startIndex && pane.index < root.startIndex + root.panes
                    color: Appearance.colors.colLayer0Base
                    opacity: 0.9

                    StyledText {
                        anchors.centerIn: parent
                        text: String(pane.index - root.startIndex + 1)
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: Appearance.colors.colOnLayer0
                    }
                }

                // ── the facts, and the way out ───────────────────────────────
                Item {
                    id: facts
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: 10
                    height: 44

                    Column {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.right: actions.left
                        anchors.rightMargin: 8
                        spacing: 1

                        StyledText {
                            width: parent.width
                            text: pane.record ? (pane.record.title && pane.record.title.length > 0 ? pane.record.title : pane.record.slug) : ""
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: Appearance.colors.colOnLayer0
                            elide: Text.ElideRight
                        }

                        StyledText {
                            width: parent.width
                            text: pane.record ? `${pane.record.source} · ${pane.record.family === "vector" ? "vector" : pane.record.w + "×" + pane.record.h}` : ""
                            font.family: Appearance.font.family.monospace
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            color: Appearance.colors.colSubtext
                            elide: Text.ElideRight
                        }
                    }

                    Row {
                        id: actions
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 4

                        IconButton {
                            icon: "open_in_full"
                            size: 32
                            tooltip: "Open"
                            onClicked: root.activated(pane.record, pane.index)
                        }

                        TextButton {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Keep"
                            icon: "check_circle"
                            variant: "tonal"
                            horizontalPadding: 14
                            implicitHeight: 34
                            enabled: root.keptId.length === 0
                            onClicked: {
                                root.keptPane = Math.max(0, pane.index - root.startIndex);
                                root.keep(pane.record);
                            }
                        }
                    }
                }

                HoverHandler {
                    id: paneHover
                }

                TapHandler {
                    acceptedButtons: Qt.RightButton
                    onTapped: eventPoint => {
                        const scene = pane.mapToItem(null, eventPoint.position.x, eventPoint.position.y);
                        root.contextRequested(pane.record, scene.x, scene.y);
                    }
                }
            }
        }
    }

    // ── what happened, once something was kept ───────────────────────────────
    Rectangle {
        id: kept
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: root.gap
        anchors.rightMargin: root.gap
        height: 48
        radius: Appearance.rounding.normal
        color: Appearance.colors.colSecondaryContainer
        visible: root.keptId.length > 0

        Row {
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            MaterialSymbol {
                anchors.verticalCenter: parent.verticalCenter
                text: "check_circle"
                iconSize: Appearance.font.pixelSize.larger
                color: Appearance.colors.colOnSecondaryContainer
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Kept · exporting to " + (Targets.recent.length > 0 ? (Targets.byId(Targets.recent[0]) ? Targets.byId(Targets.recent[0]).label : Targets.recent[0]) : "your last target")
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colOnSecondaryContainer
            }
        }

        TextButton {
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: "Compare again"
            icon: "undo"
            onClicked: root.reset()
        }
    }

    /*
     * The wheel steps the comparison, it does not scroll it.
     *
     * SmoothWheel is the right helper for a vertical gallery and does nothing
     * here — it reads `contentHeight`, which for a horizontal list never
     * exceeds the viewport. And pixel-scrolling a comparison sideways would
     * leave it halfway between two sets: the unit of this layout is the window
     * of N, so a notch moves the window by one.
     */
    WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        // Disabled with the view: input that keeps working while the gallery is
        // behind a modal overlay is the overlay not being modal.
        enabled: root.enabled && !root.collapsed
        property real accumulated: 0
        onWheel: event => {
            event.accepted = true;
            accumulated += event.angleDelta.y !== 0 ? event.angleDelta.y : event.pixelDelta.y * 4;
            // A full notch per step, so a touchpad's fine scrolling does not
            // fling the window through ten candidates at once.
            while (Math.abs(accumulated) >= 120) {
                root.moveTo(root.startIndex + (accumulated > 0 ? -1 : 1));
                accumulated -= (accumulated > 0 ? 120 : -120);
            }
        }
    }
}
