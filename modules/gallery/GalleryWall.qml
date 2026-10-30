import QtQuick
import QtQuick.Controls
import qs.modules.common
import qs.modules.widgets
import qs.services

/*
 * Masonry wall.
 *
 * The layout is in SlotGeometry — flat arrays, no object per catalogue row, so
 * 137k items cost about a megabyte. This draws it.
 *
 * **One ListView per column, and that is the whole point.**
 *
 * The obvious approach is a fixed pool of tiles re-pointed at new items as the
 * window moves. It scrolls at 60 fps and it *blinks*, because every visible
 * tile changes its content on every scroll step and each change is a decode you
 * can watch happen. Chasing that with double buffers, prefetches and decode
 * warmers made it rarer and never made it right — a tile you are looking at
 * should not change what it is.
 *
 * So each column is a ListView over that column's items. Qt creates a delegate
 * when it approaches the viewport and destroys it when it leaves, and never
 * re-points one that is on screen. The lists are not interactive: they follow
 * one Flickable, so the columns scroll as a single surface with one scrollbar
 * and one set of momentum, while each list virtualises its own column.
 */
Item {
    // Above the flickable so it can offer the slot picker instead of a bare
    // grid; see EmptyState for why "no slot" and "no matches" read as two
    // different messages rather than one "no results".
    // The empty state is the window's, not the wall's — see EmptyState.qml.

    id: root

    /*
     * The pointer's height on the wall, published for autoscroll — see
     * Shell.pointerFrac. A HoverHandler rather than a MouseArea: it reports
     * where the pointer is without taking the press, so nothing about
     * clicking a tile changes.
     */
    HoverHandler {
        id: wallPointer

        onPointChanged: {
            if (!wallPointer.hovered || root.height <= 0)
                return ;

            Shell.pointerFrac = Math.max(0, Math.min(1, point.position.y / root.height));
        }
        onHoveredChanged: {
            if (!wallPointer.hovered)
                Shell.pointerFrac = -1;

        }
    }

    property real gap: 10
    property int requestedColumns: 0
    property real minColumnWidth: 300
    /// What this layout shows, remembered for this layout alone.
    readonly property string layoutId: "wall"
    readonly property var options: Prefs.layoutSettings(root.layoutId)
    /*
     * THE COLUMN COUNT HOLDS UNTIL IT IS CLEARLY WRONG.
     *
     * `round(width / 300)` flipped between 5 and 6 across a 150px change —
     * exactly what opening the sidebar is — and a new column count rebuilds
     * every column list and every tile on screen, which froze the window for
     * almost half a second at the start of the sidebar's animation. The count
     * now stays while its columns are within a comfortable range of the
     * preferred width, and only then moves to the nearest good count.
     */
    property int _autoColumns: 0
    readonly property int columnCount: root.requestedColumns > 0 ? root.requestedColumns : Math.max(1, root._autoColumns)
    readonly property real columnWidth: (root.width - root.gap * (root.columnCount + 1)) / root.columnCount
    // Same real-pixel reasoning as the tiles: warming a step nobody asks for is
    // a wasted fetch and a tile that still has to wait.
    readonly property int ladder: {
        const want = Math.ceil(root.columnWidth * (Screen.devicePixelRatio || 1));
        // 1920/2560 added: the ladder stopped at 1280, so once a column grew
        // past that in REAL pixels every tile was an upscale of a 1280 source
        // and there was no step left to ask for. The daemon caps nothing — it
        // renders whatever size it is asked for — so the ceiling was ours.
        for (const step of [160, 320, 640, 1280, 1920, 2560]) if (step >= want) {
            return step;
        }
        return 2560;
    }
    // Published for the perf harness, which drives scrolling from a terminal so
    // a measurement never needs a window raised over anything.
    /// Padding at the end of the scroll, so the final row can clear a dock that
    /// is drawn on top of the view rather than beside it.
    property real bottomInset: 0
    /// The shell draws ONE scrollbar, on the window's edge — see shell.qml.
    readonly property alias flickable: flick

    /*
     * THE SURFACE ON SCREEN, PUBLISHED — see Host.claimView.
     *
     * Autoscroll and any extension that scrolls read it from the Host instead
     * of walking the window for the biggest list they can find.
     */
    function _publishView() {
        if (root.visible)
            Host.claimView(flick, root);
        else
            Host.releaseView(root);
    }

    onVisibleChanged: root._publishView()
    Component.onDestruction: Host.releaseView(root)
    readonly property alias geometry: geom

    signal activated(var item, int index)
    signal contextRequested(var item, real sceneX, real sceneY)
    signal quickExport(var item)
    /// A quick action other than export was pressed on a tile — the shell does
    /// the same things for these ids as the right-click menu does.
    signal quickAction(var item, string id)

    function _pickColumns() {
        if (root.width <= 0)
            return ;

        const ideal = Math.max(1, Math.round(root.width / root.minColumnWidth));
        if (root._autoColumns <= 0) {
            root._autoColumns = ideal;
            return ;
        }
        const each = root.width / root._autoColumns;
        if (each < root.minColumnWidth * 0.72 || each > root.minColumnWidth * 1.5)
            root._autoColumns = ideal;

    }

    /*
     * Push the shared scroll position into every column.
     *
     * This is what makes N virtualised lists behave as one surface: they scroll
     * together, and each one still decides for itself which of its own rows
     * need to exist.
     */
    function syncColumns() {
        for (let i = 0; i < columns.count; i++) {
            const column = columns.itemAt(i);
            if (column)
                column.contentY = flick.contentY - root.gap;

        }
    }

    /// Per-column runtime state, for `perf geometry`. The wall is the one view
    /// whose columns are separate ListViews, so "the data is fine" says nothing
    /// about whether those lists exist and have rows.
    function columnReport() {
        const out = [];
        for (let i = 0; i < columns.count; i++) {
            const c = columns.itemAt(i);
            if (!c) {
                out.push(null);
                continue;
            }
            out.push({
                "w": Math.round(c.width),
                "h": Math.round(c.height),
                "flickH": Math.round(flick.height),
                "viewportH": Math.round(viewport.height),
                "rowH": Math.round(colRow.height),
                "count": c.count,
                "contentY": Math.round(c.contentY),
                "contentH": Math.round(c.contentHeight),
                "slots": c.slots ? c.slots.length : null
            });
        }
        return out;
    }

    function scrollTest(durationMs, distancePx) {
        sweep.stop();
        flick.contentY = 0;
        sweep.from = 0;
        sweep.to = Math.min(distancePx, Math.max(0, geom.totalHeight - root.height));
        sweep.duration = durationMs;
        Perf.beginMeasure();
        sweep.start();
    }

    onWidthChanged: root._pickColumns()
    Component.onCompleted: {
        root._pickColumns();
        root._publishView();
    }

    NumberAnimation {
        id: sweep

        target: flick
        property: "contentY"
        easing.type: Easing.Linear
        onFinished: Perf.endMeasure()
    }

    SlotGeometry {
        id: geom

        ratios: Catalog.ratios
        count: Catalog.count
        columns: root.columnCount
        columnWidth: root.columnWidth
        gap: root.gap
    }

    /*
     * WHERE YOU WERE, KEPT ACROSS RESTARTS.
     *
     * Closing quarry lost your place in a wall of a quarter of a million
     * rows, and scrolling back to it is not a scroll, it is an expedition.
     * Keyed by the query as well as the layout: the position in a search for
     * "sunset" has nothing to do with the position in everything.
     */
    RememberScroll {
        view: flick
        key: `wall:${Catalog.query}`
    }

    Flickable {
        id: flick

        anchors.fill: parent
        clip: true
        contentWidth: width
        // + bottomInset: the dock FLOATS over the wall rather than having a
        // band reserved for it, so the pictures run to the bottom edge. The
        // inset is padding at the END of the scroll instead, which is what lets
        // the last row still be scrolled clear of the dock.
        contentHeight: geom.totalHeight + root.gap * 2 + root.bottomInset
        boundsBehavior: Flickable.StopAtBounds
        flickDeceleration: Appearance.scroll.deceleration
        maximumFlickVelocity: Appearance.scroll.maxVelocity
        pixelAligned: false
        // Columns are created after the Flickable, and a wall that has not
        // scrolled yet still has to start in the right place.
        Component.onCompleted: root.syncColumns()
        //
        //         * Two screens from the bottom, ask for more.
        //         *
        //         * Far enough ahead that a round trip finishes before the rows are
        //         * needed, so the wall never actually reaches its own end while a source
        //         * still has pages.
        //
        // A catalogue whose whole content is shorter than two screens is already
        // at the end, and would otherwise wait for a scroll that never comes.
        onContentHeightChanged: {
            if (contentHeight > 0 && contentHeight <= height * 3)
                Catalog.loadMore();

        }
        onContentYChanged: {
            root.syncColumns();
            if (contentHeight <= 0)
                return ;

            if (contentY + height > contentHeight - height * 3)
                Catalog.loadMore();

        }

        // Rows arriving is also a reason to sync: without this the first
        // screenful only appears once you scroll, which looks like an empty
        // gallery that fixes itself when touched.
        Connections {
            function onRevisionChanged() {
                root.syncColumns();
                // …and again once the columns have taken their new models. A
                // column whose model has just grown clamps its own contentY
                // while it is still empty, and the sync that ran before it
                // would otherwise be the last word — the wall reading as
                // scrolled to the top while the flickable says otherwise.
                Qt.callLater(root.syncColumns);
            }

            target: geom
        }

        // The columns are drawn at the viewport, not inside the scrolled
        // content: each one scrolls itself to match, which is what lets Qt
        // virtualise them.
        Item {
            id: viewport

            y: flick.contentY
            width: flick.width
            height: flick.height

            Row {
                id: colRow

                x: root.gap
                spacing: root.gap

                Repeater {
                    id: columns

                    model: root.columnCount

                    delegate: ListView {
                        id: column

                        required property int index
                        // Depends on `revision` on purpose: the column arrays
                        // are appended in place, so that counter is the only
                        // signal that this column has more rows than it did.
                        readonly property var slots: {
                            geom.revision;
                            return geom.colIndex.length > column.index ? geom.colIndex[column.index] : [];
                        }

                        width: root.columnWidth
                        // `flick.height` here resolved to 0 inside the Repeater
                        // delegate's scope while the same expression read 682
                        // from the root's — and QML warned about none of it. A
                        // zero-height column keeps its model and its 1.9M px of
                        // contentHeight and simply shows nothing, which is why
                        // every counter looked healthy while the wall was blank.
                        // Bound to the viewport Item it actually sits in.
                        height: viewport.height
                        interactive: false
                        //
                        //                         * Driven, not bound.
                        //                         *
                        //                         * A ListView owns its own `contentY`; binding it fights
                        //                         * that ownership, and Qt resolves the fight by leaving
                        //                         * the list where it is — so the columns never scrolled,
                        //                         * never created delegates past the first screenful, and
                        //                         * the wall stayed nearly empty. The outer Flickable
                        //                         * pushes the position instead (see syncColumns).
                        //
                        // A screen of delegates kept alive above and below, so
                        // a tile is created well before it is looked at and
                        // destroyed well after it is left.
                        cacheBuffer: Math.ceil(flick.height * 3)
                        // NOT `column.slots.length`. `slots` returns the SAME
                        // array object every time — colIndex is appended in
                        // place, which is what makes the geometry incremental —
                        // so assigning it back to a `var` property emits no
                        // change signal and this binding never re-ran: the
                        // column kept the count it had when it was built, zero.
                        // Reading `revision` (a real int that does change) and
                        // returning a NUMBER makes the model track the rows.
                        model: {
                            geom.revision;
                            return geom.colIndex.length > column.index ? geom.colIndex[column.index].length : 0;
                        }
                        reuseItems: false // never re-point a live delegate
                        /*
                         * THE COLUMN HAS THE LAST WORD ON ITS OWN POSITION.
                         *
                         * A column whose model has just grown clamps its
                         * contentY while it is still empty, so a sync that ran
                         * before that happened is undone — which is the wall
                         * reading as scrolled to the top while the flickable
                         * says otherwise. Re-taking the shared position
                         * whenever this column's own count or height changes
                         * closes the gap the outer sync cannot see.
                         */
                        onCountChanged: column.contentY = flick.contentY - root.gap
                        onContentHeightChanged: column.contentY = flick.contentY - root.gap

                        delegate: Item {
                            id: cell

                            required property int index
                            readonly property int slot: column.slots[cell.index] ?? 0
                            /*
                             * Assigned, and re-assigned when a page lands.
                             *
                             * `item: Catalog.itemAt(slot)` is a binding over a
                             * map that is mutated rather than reassigned, so it
                             * never re-runs — a delegate created before its
                             * page arrived would show nothing for ever.
                             */
                            property var record: null

                            function refill() {
                                cell.record = Catalog.itemAt(cell.slot);
                            }

                            // Height only: a ListView stacks its own
                            // delegates, and the column heights from
                            // SlotGeometry already add up to the same layout.
                            width: root.columnWidth
                            // `revision`, because a rescale rewrites `hs` in
                            // place and an in-place write notifies nothing.
                            height: {
                                geom.revision;
                                return geom.hs.length > cell.slot ? geom.hs[cell.slot] + root.gap : 0;
                            }
                            onSlotChanged: cell.refill()
                            Component.onCompleted: cell.refill()

                            Connections {
                                function onPageEpochChanged() {
                                    if (!cell.record)
                                        cell.refill();

                                }

                                function onChanged() {
                                    cell.refill();
                                }

                                target: Catalog
                            }

                            AssetTile {
                                anchors.fill: parent
                                anchors.bottomMargin: root.gap
                                options: root.options
                                item: cell.record
                                // Through the alias: inside the column ListViews' delegates `flick` came back undefined (measured).
                                priority: Math.abs(cell.y - (root.flickable.contentY + root.flickable.height / 2))
                                viewOffset: cell.y - (root.flickable.contentY + root.flickable.height / 2)
                                viewHeight: root.flickable.height
                                onActivated: root.activated(cell.record, cell.slot)
                                onContextRequested: (sx, sy) => {
                                    return root.contextRequested(cell.record, sx, sy);
                                }
                                onQuickExport: root.quickExport(cell.record)
                                onQuickAction: (id) => {
                                    return root.quickAction(cell.record, id);
                                }
                            }

                        }

                    }

                }

            }

        }

    }

    // Here from the first frame; the window's injector only adds one on its next scan.
    Momentum {
        flickable: flick
    }

}
