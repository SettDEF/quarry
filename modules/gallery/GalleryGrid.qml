import QtQuick
import QtQuick.Controls
import qs.modules.common
import qs.modules.widgets
import qs.services

/*
 * Uniform grid — the right default for avatars, icons and emotes, which are all
 * square anyway. GridView recycles its delegates natively, so the pooling
 * SlotGeometry does by hand is already handled here.
 */
Item {
    id: root

    /// The shell draws ONE scrollbar, on the window's edge — see shell.qml.
    readonly property alias flickable: grid

    /*
     * THE SURFACE ON SCREEN, PUBLISHED — see Host.claimView.
     *
     * Autoscroll and any extension that scrolls read it from the Host instead
     * of walking the window for the biggest list they can find.
     */
    function _publishView() {
        if (root.visible)
            Host.claimView(grid, root);
        else
            Host.releaseView(root);
    }

    onVisibleChanged: root._publishView()
    Component.onDestruction: Host.releaseView(root)
    Component.onCompleted: root._publishView()
    property real tileSize: 184
    property real gap: 10
    /// What this layout shows, remembered for this layout alone.
    readonly property string layoutId: "grid"
    readonly property var options: Prefs.layoutSettings(root.layoutId)
    readonly property int columnCount: Math.max(1, Math.floor((root.width - root.gap) / (root.tileSize + root.gap)))
    readonly property real cell: root.columnCount > 0 ? (root.width - root.gap) / root.columnCount : root.tileSize

    signal activated(var item, int index)
    signal contextRequested(var item, real sceneX, real sceneY)
    signal quickExport(var item)
    /// A quick action other than export was pressed on a tile — the shell does
    /// the same things for these ids as the right-click menu does.
    signal quickAction(var item, string id)

    // The perf harness drives whichever layout is showing, so the grid has to
    // offer the same scripted sweep the wall does.
    function scrollTest(durationMs, distancePx) {
        sweep.stop();
        grid.contentY = 0;
        sweep.from = 0;
        sweep.to = Math.min(distancePx, Math.max(0, grid.contentHeight - grid.height));
        sweep.duration = durationMs;
        Perf.beginMeasure();
        sweep.start();
    }

    NumberAnimation {
        id: sweep

        target: grid
        property: "contentY"
        easing.type: Easing.Linear
        onFinished: Perf.endMeasure()
    }

    // The same memory the wall has, under its own name so the two layouts do
    // not shove each other around.
    RememberScroll {
        view: grid
        key: `grid:${Catalog.query}`
    }

    GridView {
        id: grid

        anchors.fill: parent
        anchors.leftMargin: root.gap
        anchors.topMargin: root.gap
        clip: true
        model: Catalog.count
        cellWidth: root.cell
        cellHeight: root.cell
        cacheBuffer: Math.max(0, Math.ceil(root.height * 3))
        /*
         * Not reused.
         *
         * Recycling a delegate onto a different item is what makes a wall blink:
         * the picture it is showing is thrown away and the cell is empty until
         * the next decode lands. Measured at 78 blank flashes in one sweep here
         * while the wall — which stopped recycling — had zero. Creating and
         * destroying delegates costs less than the flicker did.
         */
        reuseItems: false
        flickDeceleration: Appearance.scroll.deceleration
        maximumFlickVelocity: Appearance.scroll.maxVelocity
        /*
         * Endless scroll, here too.
         *
         * This was wired into the wall only, so browsing in Grid — which is the
         * default for avatars and icons — simply stopped at the end of what had
         * already been crawled. Every layout that scrolls has to ask for more,
         * or "unlimited" is a property of one view rather than of the app.
         */
        onContentYChanged: {
            if (contentHeight <= 0)
                return ;

            if (contentY + height > contentHeight - height * 3)
                Catalog.loadMore();

        }
        // A first screen that does not fill the view is also "at the end".
        onCountChanged: {
            if (contentHeight > 0 && contentHeight <= height * 3)
                Catalog.loadMore();

        }

        delegate: Item {
            id: cellItem

            required property int index
            // Fetched per delegate, and delegates are recycled — so the number
            // of records alive is the number of cells on screen, not the size
            // of the catalog.
            // Assigned on recycle rather than bound — see GalleryWall.
            property var record: null

            onIndexChanged: cellItem.record = Catalog.itemAt(cellItem.index)
            Component.onCompleted: cellItem.record = Catalog.itemAt(cellItem.index)
            width: grid.cellWidth
            height: grid.cellHeight

            // Pages arrive after delegates are created; without this a cell
            // that was empty when it appeared stays empty.
            Connections {
                function onPageEpochChanged() {
                    if (!cellItem.record)
                        cellItem.record = Catalog.itemAt(cellItem.index);

                }

                target: Catalog
            }

            AssetTile {
                width: parent.width - root.gap
                height: parent.height - root.gap
                // At contact-sheet size a title strip and badges cover the
                // picture they are describing.
                showMeta: root.tileSize > 120
                options: root.options
                item: cellItem.record
                priority: Math.abs(cellItem.y - (grid.contentY + root.height / 2))
                viewOffset: cellItem.y - (grid.contentY + root.height / 2)
                viewHeight: root.height
                onActivated: root.activated(cellItem.record, cellItem.index)
                onContextRequested: (sx, sy) => {
                    return root.contextRequested(cellItem.record, sx, sy);
                }
                onQuickExport: root.quickExport(cellItem.record)
                onQuickAction: (id) => {
                    return root.quickAction(cellItem.record, id);
                }
            }

        }

    }

    // Here from the first frame; the window's injector only adds one on its next scan.
    Momentum {
        flickable: grid
    }

}
