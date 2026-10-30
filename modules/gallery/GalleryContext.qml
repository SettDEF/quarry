import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects

/*
 * In-context — the candidate drawn into the slot it is going to.
 *
 * Every other layout answers "is this a good picture". This answers the only
 * question that actually decides an export: "is this a good *avatar*", "is this
 * a good *wallpaper*". Those are different questions, and a 400px tile cannot
 * answer either of them — a face that reads beautifully at tile size is a
 * smudge at 32px in a member list, and a wallpaper's best third is exactly
 * where the bar sits.
 *
 * **So the mocks draw at the target's real pixel size.** Each one has a design
 * size in *device* pixels — a Steam avatar is 184 of them, a Discord member row
 * shows 32 — and is scaled by a single factor that fits it into its card and is
 * never allowed above 1.0. At 100% the avatar on your screen is the same number
 * of physical pixels as the avatar on Steam. Stretching the picture to fill the
 * pane would look better and would be a lie, which is the whole reason this
 * layout exists.
 *
 * The mocks are drawn in QML rather than composited by the daemon: this is
 * chrome around a picture, and the picture is already a real ladder step at the
 * right size. When Phase 7 lands `export.preview`, the pane's image swaps to
 * the real export and nothing else here changes.
 */
Item {
    id: root

    signal activated(var item, int index)
    signal contextRequested(var item, real sceneX, real sceneY)
    signal exportRequested(var item, string targetId)

    // Which result is on the stage. The filmstrip and the arrow keys move it.
    property int index: 0

    /*
     * Assigned, never bound.
     *
     * `Catalog.itemAt(index)` in a binding reads a page map that is mutated in
     * place rather than reassigned, so the binding never re-runs and the stage
     * would keep showing nothing after the page it asked for arrived.
     */
    property var record: null

    function refill() {
        root.record = Catalog.itemAt(root.index);
    }

    onIndexChanged: root.refill()
    Component.onCompleted: root.refill()

    Connections {
        target: Catalog
        function onPageEpochChanged() {
            if (!root.record)
                root.refill();
        }
        function onChanged() {
            root.refill();
        }
    }

    // Logical pixels per real pixel. Everything in a mock is specified in real
    // pixels, because that is the unit the target is specified in.
    readonly property real dpr: Screen.devicePixelRatio || 1

    // Never magnify: a 32px avatar blown up to fill a card is the mistake this
    // layout was built to stop.
    function fitInto(availW, availH, designW, designH) {
        if (designW <= 0 || designH <= 0 || availW <= 0 || availH <= 0)
            return 1;
        return Math.min(1, Math.min(availW * root.dpr / designW, availH * root.dpr / designH));
    }

    // Nearest ladder step at or above the size the mock actually draws.
    function ladderFor(devicePixels) {
        for (const step of [160, 320, 640, 1280])
            if (step >= devicePixels)
                return step;
        return 1280;
    }

    // The wallpaper target for the screen this window is on — the same id
    // Targets derives from the connected monitors, so the export that follows
    // the preview is the one that was previewed.
    readonly property string wallpaperTargetId: {
        const own = "wallpaper-" + Screen.name;
        if (Targets.byId(own))
            return own;
        const any = Targets.all.find(t => t.id.indexOf("wallpaper-") === 0);
        return any ? any.id : "original";
    }

    readonly property int screenW: Math.round(Screen.width * root.dpr)
    readonly property int screenH: Math.round(Screen.height * root.dpr)

    function step(delta) {
        const next = root.index + delta;
        if (next < 0 || next >= Catalog.count)
            return;
        root.index = next;
        strip.positionViewAtIndex(next, ListView.Contain);
        if (next + 40 > Catalog.count)
            Catalog.loadMore();
    }

    /*
     * The harness drives whichever layout is showing.
     *
     * The stage is three pictures and does not scroll, so the sweep runs the
     * filmstrip — which is the part of this layout with a per-item cost, and
     * therefore the part worth measuring.
     */
    function scrollTest(durationMs, distancePx) {
        sweep.stop();
        strip.contentX = 0;
        sweep.from = 0;
        sweep.to = Math.min(distancePx, Math.max(0, strip.contentWidth - strip.width));
        sweep.duration = durationMs;
        Perf.beginMeasure();
        sweep.start();
    }

    NumberAnimation {
        id: sweep
        target: strip
        property: "contentX"
        easing.type: Easing.Linear
        onFinished: Perf.endMeasure()
    }

    focus: root.visible && root.enabled
    Keys.onPressed: event => {
        switch (event.key) {
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
        case Qt.Key_Return:
        case Qt.Key_Enter:
            root.activated(root.record, root.index);
            event.accepted = true;
            break;
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 8

            /*
             * A fixed share of the stage, not a stretch factor.
             *
             * Both columns hold Rectangles, which have no implicit width, so a
             * layout asked to divide "extra" space between two zero-width items
             * gave the desktop essentially all of it and squeezed the avatars
             * to a fifteen-pixel sliver. The split is stated instead.
             */
            ColumnLayout {
                Layout.fillWidth: false
                Layout.preferredWidth: Math.round((root.width - 8) * 0.38)
                Layout.fillHeight: true
                spacing: 8

                /*
                 * MOCKS FROM PACKS.
                 *
                 * The Steam profile header used to be written out here. It is
                 * an extension now -- the in-context layout answers "is this a
                 * good *avatar*", and which avatars matter is personal, so the
                 * panes you do not want should not cost you a third of the
                 * stage. `extensions/steam-profile` is the pack, and the layout
                 * menu's Mockups submenu is where you switch it on.
                 *
                 * Nothing here knows what a Steam profile is any more.
                 */
                Repeater {
                    model: Extensions.contextMocks

                    delegate: ContextMock {
                        required property var modelData

                        label: modelData.mock.label
                        detail: modelData.mock.detail
                        targetId: modelData.mock.targetId
                        designW: modelData.mock.designW
                        designH: modelData.mock.designH
                        content: modelData.mock.component
                        record: root.record
                        dpr: root.dpr

                        onExportClicked: root.exportRequested(root.record, modelData.mock.targetId)
                    }
                }

                /*
                 * Nothing at all is worse than an empty column: with every
                 * pack switched off this side of the stage was a blank third
                 * of the window with no explanation and no way back.
                 */
                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: Extensions.contextMocks.length === 0
                    radius: Appearance.rounding.normal
                    color: Appearance.colors.colLayer2

                    StyledText {
                        anchors.centerIn: parent
                        anchors.margins: 16
                        width: parent.width - 32
                        horizontalAlignment: Text.AlignHCenter
                        text: "No mockup packs are on.\nThe layout button’s ⌄ menu has them."
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                        wrapMode: Text.WordWrap
                    }
                }

                // ── Discord member row ───────────────────────────────────────
                Rectangle {
                    id: discordCard
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: Appearance.rounding.normal
                    color: Appearance.colors.colLayer2

                    /*
                     * 32 real pixels, and that is the point.
                     *
                     * The Discord avatar target uploads 512², but a member list
                     * draws it at 32 — so this is where an avatar with a busy
                     * background or a face that needs its detail is exposed,
                     * and no amount of looking at the 512 preview shows it.
                     */
                    readonly property int designW: 340
                    readonly property int designH: 216
                    readonly property real fit: root.fitInto(width - 24, height - 52, discordCard.designW, discordCard.designH)
                    function u(px) {
                        return px * discordCard.fit / root.dpr;
                    }

                    MockCaption {
                        label: "Discord member list"
                        detail: "shown at 32px"
                        fit: discordCard.fit
                        onExportClicked: root.exportRequested(root.record, "discord-avatar")
                    }

                    Item {
                        width: discordCard.u(discordCard.designW)
                        height: discordCard.u(discordCard.designH)
                        anchors.centerIn: parent
                        anchors.verticalCenterOffset: 14

                        Rectangle {
                            anchors.fill: parent
                            radius: discordCard.u(10)
                            color: Appearance.colors.colSurfaceContainerHighest
                        }

                        Column {
                            anchors.fill: parent
                            anchors.margins: discordCard.u(8)
                            spacing: discordCard.u(4)

                            Repeater {
                                // The neighbours matter: an avatar is judged
                                // against the ones above and below it, never on
                                // its own.
                                model: 4

                                delegate: Item {
                                    id: member
                                    required property int index
                                    readonly property bool mine: member.index === 1
                                    width: discordCard.u(discordCard.designW - 16)
                                    height: discordCard.u(44)

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: discordCard.u(6)
                                        visible: member.mine
                                        color: Appearance.colors.colLayer3
                                    }

                                    Item {
                                        id: memberAvatar
                                        x: discordCard.u(8)
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: discordCard.u(32)
                                        height: width

                                        Rectangle {
                                            anchors.fill: parent
                                            radius: Appearance.rounding.full
                                            visible: !member.mine
                                            color: Appearance.colors.colLayer4
                                        }

                                        ThumbImage {
                                            anchors.fill: parent
                                            visible: member.mine
                                            item: member.mine ? root.record : null
                                            size: root.ladderFor(32 * discordCard.fit)
                                            gated: false
                                            fillMode: Image.PreserveAspectCrop
                                            layer.enabled: true
                                            layer.smooth: true
                                            layer.effect: OpacityMask {
                                                maskSource: Rectangle {
                                                    width: memberAvatar.width
                                                    height: memberAvatar.height
                                                    radius: Appearance.rounding.full
                                                }
                                            }
                                        }
                                    }

                                    StyledText {
                                        x: discordCard.u(52)
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: member.mine ? "you" : "someone else"
                                        font.pixelSize: Appearance.font.pixelSize.small * discordCard.fit
                                        color: member.mine ? Appearance.colors.colOnLayer2 : Appearance.colors.colOnLayer1Inactive
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ── the desktop ──────────────────────────────────────────────────
            Rectangle {
                id: desktopCard
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: Appearance.rounding.normal
                color: Appearance.colors.colLayer2

                // The monitor this window is on, at its real pixel count —
                // which is exactly the wallpaper target's recipe, so the
                // preview and the export are the same rectangle.
                readonly property real fit: root.fitInto(width - 24, height - 52, root.screenW, root.screenH)
                function u(px) {
                    return px * desktopCard.fit / root.dpr;
                }

                MockCaption {
                    label: "Desktop · " + Screen.name
                    detail: `${root.screenW}×${root.screenH}`
                    fit: desktopCard.fit
                    onExportClicked: root.exportRequested(root.record, root.wallpaperTargetId)
                }

                Item {
                    id: screenMock
                    width: desktopCard.u(root.screenW)
                    height: desktopCard.u(root.screenH)
                    anchors.centerIn: parent
                    anchors.verticalCenterOffset: 14

                    Rectangle {
                        anchors.fill: parent
                        color: Appearance.colors.colLayer0Base
                        radius: desktopCard.u(12)
                    }

                    ThumbImage {
                        anchors.fill: parent
                        item: root.record
                        size: root.ladderFor(root.screenW * desktopCard.fit)
                        gated: false
                        // A wallpaper target is fit:cover, so the preview crops
                        // the same way the export will.
                        fillMode: Image.PreserveAspectCrop
                        layer.enabled: true
                        layer.smooth: true
                        layer.effect: OpacityMask {
                            maskSource: Rectangle {
                                width: screenMock.width
                                height: screenMock.height
                                radius: desktopCard.u(12)
                            }
                        }
                    }

                    // The bar, because "how does it look behind the bar" is the
                    // question a wallpaper is actually chosen on.
                    Rectangle {
                        x: desktopCard.u(40)
                        y: desktopCard.u(28)
                        width: parent.width - desktopCard.u(80)
                        height: desktopCard.u(56)
                        radius: Appearance.rounding.full
                        color: Appearance.colors.colLayer0Base
                        opacity: 0.86

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: desktopCard.u(20)
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: desktopCard.u(12)

                            Repeater {
                                model: 4

                                delegate: Rectangle {
                                    width: desktopCard.u(28)
                                    height: desktopCard.u(28)
                                    radius: Appearance.rounding.full
                                    color: Appearance.colors.colOnLayer0
                                    opacity: 0.55
                                }
                            }
                        }

                        Rectangle {
                            anchors.centerIn: parent
                            width: desktopCard.u(120)
                            height: desktopCard.u(22)
                            radius: Appearance.rounding.full
                            color: Appearance.colors.colOnLayer0
                            opacity: 0.55
                        }

                        Rectangle {
                            anchors.right: parent.right
                            anchors.rightMargin: desktopCard.u(20)
                            anchors.verticalCenter: parent.verticalCenter
                            width: desktopCard.u(150)
                            height: desktopCard.u(22)
                            radius: Appearance.rounding.full
                            color: Appearance.colors.colPrimary
                            opacity: 0.8
                        }
                    }

                    // A widget, so the busy corner of a wallpaper is visible as
                    // a busy corner rather than as a nice detail.
                    Rectangle {
                        x: desktopCard.u(40)
                        y: parent.height - height - desktopCard.u(40)
                        width: desktopCard.u(420)
                        height: desktopCard.u(240)
                        radius: desktopCard.u(24)
                        color: Appearance.colors.colLayer1
                        opacity: 0.9
                    }
                }
            }
        }

        // ── which candidate ──────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 96
            radius: Appearance.rounding.normal
            color: Appearance.colors.colLayer2

            ListView {
                id: strip
                // The wheel steps this strip (handler below); this tells the window's
                // MomentumInjector the list is taken, so it does not add a pixel scroller.
                Item {
                    readonly property Item flickable: strip
                }
                anchors.fill: parent
                anchors.margins: 8
                orientation: ListView.Horizontal
                clip: true
                model: Catalog.count
                spacing: 6
                // Clamped: the layout is measured before it has a width, and
                // a negative buffer is a warning at every reload.
                cacheBuffer: Math.max(0, Math.ceil(root.width * 1.5))
                // Same reason as every other layout here: a delegate re-pointed
                // at another item while on screen is a picture that blinks.
                reuseItems: false
                flickDeceleration: Appearance.scroll.deceleration
                maximumFlickVelocity: Appearance.scroll.maxVelocity

                onContentXChanged: {
                    if (contentWidth <= 0)
                        return;
                    if (contentX + width > contentWidth - width)
                        Catalog.loadMore();
                }

                onCountChanged: {
                    if (contentWidth > 0 && contentWidth <= width * 2)
                        Catalog.loadMore();
                }

                delegate: Rectangle {
                    id: frame
                    required property int index

                    // Assigned on index change and refilled when the page
                    // lands — see the note on `record` above.
                    property var record: null

                    function refill() {
                        frame.record = Catalog.itemAt(frame.index);
                    }

                    Component.onCompleted: frame.refill()
                    onIndexChanged: frame.refill()

                    Connections {
                        target: Catalog
                        function onPageEpochChanged() {
                            if (!frame.record)
                                frame.refill();
                        }
                        function onChanged() {
                            frame.refill();
                        }
                    }

                    width: strip.height
                    height: strip.height
                    radius: Appearance.rounding.small
                    color: Appearance.colors.colLayer3
                    border.width: frame.index === root.index ? 2 : 0
                    border.color: Appearance.colors.colPrimary

                    ThumbImage {
                        anchors.fill: parent
                        anchors.margins: 3
                        item: frame.record
                        size: 160
                        priority: Math.abs(frame.x - (strip.contentX + strip.width / 2))
                        fillMode: Image.PreserveAspectCrop
                    }

                    TapHandler {
                        acceptedButtons: Qt.LeftButton
                        onTapped: root.index = frame.index
                    }

                    TapHandler {
                        acceptedButtons: Qt.RightButton
                        onTapped: eventPoint => {
                            const scene = frame.mapToItem(null, eventPoint.position.x, eventPoint.position.y);
                            root.contextRequested(frame.record, scene.x, scene.y);
                        }
                    }
                }
            }

            /*
             * The wheel picks the next candidate rather than scrolling.
             *
             * SmoothWheel reads `contentHeight`, which a horizontal strip never
             * grows, so it would do nothing here — and stepping is what a wheel
             * means in a view showing one item at a time, exactly as the detail
             * view treats it.
             */
            WheelHandler {
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                // Disabled with the view, so nothing reacts behind a modal.
                enabled: root.enabled
                property real accumulated: 0
                onWheel: event => {
                    event.accepted = true;
                    accumulated += event.angleDelta.y !== 0 ? event.angleDelta.y : event.pixelDelta.y * 4;
                    while (Math.abs(accumulated) >= 120) {
                        root.step(accumulated > 0 ? -1 : 1);
                        accumulated -= (accumulated > 0 ? 120 : -120);
                    }
                }
            }
        }
    }

    // The header every mock carries: what slot it is, what size that slot is,
    // and how much the preview had to be shrunk to fit — because "shown at 46%"
    // is the difference between judging the real thing and judging a picture of
    // it.
    component MockCaption: Item {
        id: caption

        property string label: ""
        property string detail: ""
        property real fit: 1

        signal exportClicked

        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 34

        /*
         * A ROW, NOT TWO ANCHORED LABELS.
         *
         * Both were anchored to their own edge and neither knew the other was
         * there, so in a narrow window "Discord member list" ran straight
         * through "shown at 32px · 100%" and both became unreadable. The scale
         * is the number the pane exists to report, so it keeps its width and
         * the name gives way.
         */
        RowLayout {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 12
            anchors.rightMargin: 4
            spacing: 6

            StyledText {
                Layout.fillWidth: true
                text: caption.label
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colOnLayer2
                elide: Text.ElideRight
            }

            StyledText {
                text: `${caption.detail} · ${Math.round(caption.fit * 100)}%`
                font.family: Appearance.font.family.monospace
                font.pixelSize: Appearance.font.pixelSize.smallest
                color: caption.fit >= 0.999 ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
            }

            IconButton {
                icon: "crop"
                size: 28
                iconSize: Appearance.font.pixelSize.normal
                tooltip: "Export for this slot"
                onClicked: caption.exportClicked()
            }
        }
    }
}
