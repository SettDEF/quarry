import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/*
 * One row per item: thumbnail, name, and the facts.
 *
 * The wall and the grid answer "which of these looks right". This answers the
 * other question — "what *is* this one" — without opening anything: source,
 * real dimensions, aspect, kind and tags, aligned in columns so twenty rows can
 * be compared by moving your eyes down one of them.
 *
 * It is also the cheapest layout by far: one small thumbnail per row instead of
 * a screen full of large ones, which makes it the honest choice for triaging a
 * few thousand rows after a crawl.
 */
Item {
    id: root
    /// The shell draws ONE scrollbar, on the window's edge — see shell.qml.
    readonly property alias flickable: list

    /*
     * THE SURFACE ON SCREEN, PUBLISHED — see Host.claimView.
     *
     * Autoscroll and any extension that scrolls read it from the Host instead
     * of walking the window for the biggest list they can find.
     */
    function _publishView() {
        if (root.visible)
            Host.claimView(list, root);
        else
            Host.releaseView(root);
    }

    onVisibleChanged: root._publishView()
    Component.onDestruction: Host.releaseView(root)
    Component.onCompleted: root._publishView()

    property real rowHeight: 76
    property real gap: 10

    signal activated(var item, int index)
    signal contextRequested(var item, real sceneX, real sceneY)
    signal quickExport(var item)
    /// A quick action other than export was pressed on a tile — the shell does
    /// the same things for these ids as the right-click menu does.
    signal quickAction(var item, string id)

    /// What this layout shows, remembered for this layout alone.
    readonly property string layoutId: "compact"
    readonly property var options: Prefs.layoutSettings(root.layoutId)

    // The perf harness drives whichever layout is showing.
    function scrollTest(durationMs, distancePx) {
        sweep.stop();
        list.contentY = 0;
        sweep.from = 0;
        sweep.to = Math.min(distancePx, Math.max(0, list.contentHeight - list.height));
        sweep.duration = durationMs;
        Perf.beginMeasure();
        sweep.start();
    }

    NumberAnimation {
        id: sweep
        target: list
        property: "contentY"
        easing.type: Easing.Linear
        onFinished: Perf.endMeasure()
    }

    ListView {
        id: list
        anchors.fill: parent
        anchors.leftMargin: root.gap
        anchors.rightMargin: root.gap
        clip: true
        model: Catalog.count
        spacing: 2
        cacheBuffer: Math.max(0, Math.ceil(root.height * 3))
        // Same reasoning as the wall: a delegate that is re-pointed at a new
        // item while on screen is a picture that blinks.
        reuseItems: false
        flickDeceleration: Appearance.scroll.deceleration
        maximumFlickVelocity: Appearance.scroll.maxVelocity

        onContentYChanged: {
            if (contentHeight <= 0)
                return;
            if (contentY + height > contentHeight - height * 3)
                Catalog.loadMore();
        }

        onCountChanged: {
            if (contentHeight > 0 && contentHeight <= height * 3)
                Catalog.loadMore();
        }

        delegate: Rectangle {
            id: row
            required property int index

            property var record: null

            function refill() {
                row.record = Catalog.itemAt(row.index);
            }

            Component.onCompleted: row.refill()
            onIndexChanged: row.refill()

            Connections {
                target: Catalog
                function onPageEpochChanged() {
                    if (!row.record)
                        row.refill();
                }
            }

            width: list.width
            height: root.rowHeight
            radius: Appearance.rounding.small
            color: rowHover.hovered ? Appearance.colors.colLayer2Hover : "transparent"

            RowLayout {
                anchors.fill: parent
                anchors.margins: 8
                spacing: 12

                ThumbImage {
                    id: rowThumb
                    Layout.preferredWidth: root.rowHeight - 16
                    Layout.preferredHeight: root.rowHeight - 16
                    item: row.record
                    size: 160
                    priority: Math.abs(row.y - (list.contentY + list.height / 2))
                    fillMode: Image.PreserveAspectCrop

                    // Failed and still-loading drew the same empty square, so a
                    // row that would never fill looked like a slow one.
                    MaterialSymbol {
                        anchors.centerIn: parent
                        visible: rowThumb.failed
                        text: "broken_image"
                        iconSize: 20
                        color: Appearance.colors.colSubtext
                        opacity: 0.7
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    StyledText {
                        Layout.fillWidth: true
                        text: row.record ? (row.record.title && row.record.title.length > 0 ? row.record.title : row.record.slug) : ""
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: Appearance.colors.colOnLayer0
                        elide: Text.ElideRight
                    }

                    StyledText {
                        Layout.fillWidth: true
                        text: row.record ? (row.record.tags || []).slice(0, 5).join("  ") : ""
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: Appearance.colors.colSubtext
                        elide: Text.ElideRight
                        visible: text.length > 0
                    }
                }

                // Facts in fixed columns, monospaced: the point of this layout
                // is that they line up down the screen.
                StyledText {
                    Layout.preferredWidth: 96
                    text: row.record ? row.record.source : ""
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: Appearance.colors.colSubtext
                    elide: Text.ElideRight
                }

                StyledText {
                    Layout.preferredWidth: 92
                    horizontalAlignment: Text.AlignRight
                    text: row.record ? (row.record.family === "vector" ? "vector" : `${row.record.w}×${row.record.h}`) : ""
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: Appearance.colors.colSubtext
                }

                StyledText {
                    Layout.preferredWidth: 64
                    horizontalAlignment: Text.AlignRight
                    text: row.record ? row.record.kind : ""
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: Appearance.colors.colSubtext
                }

                // The same two actions the tiles offer, in the same order.
                IconButton {
                    icon: "crop"
                    size: 30
                    visible: rowHover.hovered
                    onClicked: root.quickExport(row.record)
                }

                IconButton {
                    icon: "open_in_full"
                    size: 30
                    visible: rowHover.hovered
                    onClicked: root.activated(row.record, row.index)
                }
            }

            HoverHandler {
                id: rowHover
            }

            TapHandler {
                acceptedButtons: Qt.LeftButton
                onTapped: root.activated(row.record, row.index)
            }

            TapHandler {
                acceptedButtons: Qt.RightButton
                onTapped: eventPoint => {
                    const scene = row.mapToItem(null, eventPoint.position.x, eventPoint.position.y);
                    root.contextRequested(row.record, scene.x, scene.y);
                }
            }
        }
    }

    // Here from the first frame; the window's injector only adds one on its next scan.
    Momentum {
        flickable: list
    }
}
