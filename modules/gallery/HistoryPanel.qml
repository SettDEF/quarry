import QtQuick
import QtQuick.Layouts
import qs.modules.common
import qs.modules.widgets
import qs.services

/*
 * WHERE YOU HAVE BEEN, KEPT.
 *
 * The back arrow walks this session; this is the record that survives it —
 * searches you ran, pictures you opened, files you exported. Everything here
 * is a way back to something: a search re-runs, a picture opens, an export
 * says what it was and when.
 */
Sheet {
    id: root

    // Same geometry rules as the filter drawer: part of the gallery card.
    readonly property Item galleryCard: Shell.gallery ? Shell.gallery.parent : null
    readonly property rect cardRect: {
        const rw = root.width, rh = root.height;
        const c = root.galleryCard;
        if (!c || !(c.width > 0) || !(c.height > 0))
            return Qt.rect(2, 74, Math.max(0, rw - 14), Math.max(0, rh - 86));

        const at = c.mapToItem(root, 0, 0);
        return Qt.rect(at.x, at.y, c.width, c.height);
    }
    /*
     * HISTORY DRAWS ITSELF THE FOUR WAYS EVERYTHING ELSE DOES.
     *
     * It was a list of 46-pixel rows with a glyph on each — which is right
     * for a search you typed and wrong for a picture you opened, and most of
     * what lands here is pictures. The gallery has four shapes for exactly
     * this question and every lens now speaks them, so history does too:
     * `layouts` / `layout` / `setLayout`, the same names the layout button
     * looks for (see LayoutMenu).
     *
     * One memory for the whole screen rather than one per filter: history is
     * one place, not a place per kind.
     */
    readonly property var layouts: [{
        "id": "wall",
        "label": "Wall",
        "icon": "view_quilt",
        "hint": "real shapes",
        "cell": 160
    }, {
        "id": "grid",
        "label": "Grid",
        "icon": "grid_view",
        "hint": "even tiles",
        "cell": 130
    }, {
        "id": "sheet",
        "label": "Contact sheet",
        "icon": "apps",
        "hint": "hundreds at a time",
        "cell": 84
    }, {
        "id": "compact",
        "label": "Compact",
        "icon": "view_list",
        "hint": "what you did, as rows",
        "cell": 0
    }]
    readonly property string layout: Prefs.historyLayout
    readonly property bool asRows: root.layout === "compact"
    readonly property bool keepsShape: root.layout === "wall"
    readonly property int layoutCell: {
        for (const l of root.layouts) if (l.id === root.layout) {
            return Number(l.cell || 0);
        }
        return 130;
    }
    property string kind: ""
    property string needle: ""
    property var entries: []
    property bool loading: false
    /// Why the list is empty, when the daemon could not answer at all.
    property string failure: ""

    function setLayout(id) {
        for (const l of root.layouts) if (l.id === id) {
            Prefs.historyLayout = id;
            return ;
        }
    }

    function toggle() {
        root.open = !root.open;
        if (root.open)
            root.reload();

    }

    function reload() {
        if (!Client.connected) {
            root.entries = [];
            return ;
        }
        root.loading = true;
        Client.call("history", {
            "kind": root.kind,
            "q": root.needle,
            "limit": 300
        }, function(err, payload) {
            root.loading = false;
            // "Nothing here yet" was shown to people whose history simply could
            // not be read — the same sentence for an empty list and a failed
            // call, which is the one thing an empty state must never do.
            root.failure = err && !payload ? String(err) : "";
            root.entries = (err || !payload) ? [] : (payload.entries || []);
        });
    }

    /// "just now", "14 min", "3 h", "2 d" — a record is read as "how long ago",
    /// never as a timestamp nobody converts in their head.
    function ago(at) {
        const secs = Math.max(0, Math.floor(Date.now() / 1000) - at);
        if (secs < 60)
            return "just now";

        if (secs < 3600)
            return `${Math.floor(secs / 60)} min`;

        if (secs < 86400)
            return `${Math.floor(secs / 3600)} h`;

        return `${Math.floor(secs / 86400)} d`;
    }

    /*
     * BACK TO WHERE IT WAS, NOT JUST TO WHAT IT WAS.
     *
     * An entry records the place it happened in (see `Catalog.hereNow`), so a
     * picture found three screens into the Reddit lens reopens there rather
     * than as a bare `id:` search in the catalogue — which is the same picture
     * with none of the context that made it worth keeping.
     *
     * The context is best effort by design: entries recorded before this
     * existed have none, a lens may have been uninstalled since, and neither
     * is a reason to refuse to open the row. So every branch falls through to
     * the id search that always worked.
     */
    function act(entry) {
        const where = entry.context || null;

        if (entry.kind === "search") {
            Catalog.query = entry.value;
            root.open = false;
            return ;
        }
        if (!entry.item || entry.item.length === 0)
            return ;

        // A lens that is still installed gets the row back on its own terms.
        if (where && where.lens && where.lens.length > 0 && Lenses.isEnabled(where.lens)) {
            Lenses.open(where.lens, {
                "item": entry.item,
                "screen": where.screen || "",
                "from": "history"
            });
            root.open = false;
            return ;
        }

        /*
         * Otherwise the catalogue — but under the query it was found with,
         * when one was recorded. `id:` alone answers one row and throws away
         * the result it belonged to, so the arrows either side of the viewer
         * had nowhere to go.
         */
        /*
         * An EMPTY recorded query means Everything, not "nothing recorded".
         *
         * Opening a picture while browsing the unfiltered wall records
         * `query: ""` — which this read as no context and replaced with
         * `id:<row>`, a search that answers exactly one row with no neighbours
         * and dead arrows either side. Measured: 151 of 599 opens carry an
         * empty query, and the five most recent were all of them.
         *
         * Only an entry with NO context at all falls back to the id search.
         */
        if (where && where.query !== undefined) {
            if (where.query !== Catalog.query)
                Catalog.query = where.query;

        } else {
            Catalog.query = `id:${entry.item}`;
        }
        root.reopen(entry.item);
        root.open = false;
    }

    /*
     * Open the row itself once the result it lives in has landed.
     *
     * The query above is asynchronous, so the row is not in the result yet
     * when this returns — hence the retry rather than a single look. It gives
     * up rather than spinning: the row may genuinely not be in that result any
     * more, and the query is still the right place to have landed.
     */
    function reopen(id) {
        reopenTries.wanted = id;
        reopenTries.left = 12;
        reopenTries.restart();
    }

    Timer {
        id: reopenTries

        property string wanted: ""
        property int left: 0

        interval: 120
        repeat: true
        onTriggered: {
            const at = Catalog.indexOfId(reopenTries.wanted);
            if (at >= 0) {
                reopenTries.stop();
                if (Shell.detail)
                    Shell.detail.openAt(at, Catalog.recordFor(reopenTries.wanted));

                return ;
            }
            reopenTries.left -= 1;
            if (reopenTries.left > 0)
                return ;

            reopenTries.stop();
            /*
             * The wall only knows the pages it has loaded, so a row further
             * down was never found and the picture simply did not open. The
             * daemon holds the whole order — see `Catalog.locateId`.
             */
            const wanted = reopenTries.wanted;
            Catalog.locateId(wanted, function (found) {
                if (found < 0)
                    return ;

                Catalog.fetchRecord(wanted, function (record) {
                    if (record && Shell.detail)
                        Shell.detail.openAt(found, record);

                });
            });
        }
    }

    placement: "topRight"
    topInset: root.cardRect.y
    inset: Math.max(0, root.width - (root.cardRect.x + root.cardRect.width))
    surfaceWidth: Math.round(Math.min(460, Math.max(300, Math.min(root.cardRect.width - 16, root.cardRect.width * 0.64))))
    surfaceHeight: Math.max(160, root.cardRect.height)
    onKindChanged: {
        if (root.open) {
            root.reload();
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 14
        spacing: 10

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            StyledText {
                Layout.fillWidth: true
                text: "History"
                font.pixelSize: Appearance.font.pixelSize.larger
                font.weight: Font.DemiBold
                color: Appearance.colors.colOnLayer0
            }

            IconButton {
                icon: "delete_sweep"
                size: 34
                tooltip: root.kind.length > 0 ? `Forget every ${root.kind}` : "Forget everything here"
                onClicked: Client.call("history_clear", {
                    "kind": root.kind
                }, function(err, payload) {
                    if (!err)
                        Toast.show(payload && payload.removed > 0 ? `Forgot ${payload.removed} entries` : "Nothing to forget");

                    root.reload();
                })
            }

            IconButton {
                icon: "close"
                size: 34
                tooltip: "Close"
                onClicked: root.open = false
            }

        }

        MaterialTextField {
            Layout.fillWidth: true
            implicitHeight: 42
            leadingIcon: "search"
            placeholder: "Find something you searched for"
            onTextChanged: {
                root.needle = text;
                reloadDebounce.restart();
            }
        }

        Timer {
            id: reloadDebounce

            interval: 160
            onTriggered: root.reload()
        }

        Row {
            Layout.fillWidth: true
            spacing: 3

            Repeater {
                model: [{
                    "id": "",
                    "label": "All",
                    "icon": "history"
                }, {
                    "id": "search",
                    "label": "Searches",
                    "icon": "search"
                }, {
                    "id": "open",
                    "label": "Opened",
                    "icon": "visibility"
                }, {
                    "id": "export",
                    "label": "Exported",
                    "icon": "output"
                }]

                delegate: Rectangle {
                    required property var modelData
                    readonly property bool selected: root.kind === modelData.id

                    implicitHeight: 32
                    implicitWidth: label.implicitWidth + 22
                    radius: height / 2
                    color: selected ? Appearance.colors.colSecondaryContainer : tabTap.containsMouse ? Appearance.colors.colLayer2Hover : Appearance.colors.colLayer2

                    StyledText {
                        id: label

                        anchors.centerIn: parent
                        text: modelData.label
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: parent.selected ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colSubtext
                    }

                    MouseArea {
                        id: tabTap

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.kind = modelData.id
                    }

                    Behavior on color {
                        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                    }

                }

            }

        }

        /*
         * THE PICTURES YOU OPENED, AS PICTURES.
         *
         * Shown for every layout but compact. Only the entries that ARE a
         * picture appear here — a search you typed has nothing to draw, and
         * a grid with holes in it for the searches would be a worse list
         * than the list.
         *
         * Each tile asks the catalogue for its record once (`recordFor`,
         * which caches and asks the daemon at most once per id), so opening
         * history does not fetch two thousand records.
         */
        GridView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            /*
             * A search has no picture, so a tile layout has nothing to draw for
             * one. With the Searches chip picked the model below emptied this
             * view while `entries` stayed full — so the empty-state line kept
             * quiet and the panel was a blank rectangle, two clicks from the
             * default layout.
             */
            visible: !root.asRows && root.kind !== "search"
            clip: true
            cacheBuffer: 600
            model: root.entries.filter((e) => {
                return e.kind !== "search" && String(e.item || "").length > 0;
            })
            cellWidth: Math.floor(width / Math.max(1, Math.floor(width / Math.max(70, root.layoutCell))))
            cellHeight: root.keepsShape ? Math.round(cellWidth * 1.2) : cellWidth

            delegate: Item {
                id: tile

                required property var modelData
                readonly property var record: Catalog.recordFor(tile.modelData.item)

                width: GridView.view.cellWidth
                height: GridView.view.cellHeight

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 2
                    radius: Appearance.rounding.small
                    clip: true
                    color: tileTap.pressed ? Appearance.colors.colLayer2Active : tileHover.hovered ? Appearance.colors.colLayer2Hover : Appearance.colors.colLayer2

                    Image {
                        anchors.fill: parent
                        asynchronous: true
                        cache: true
                        smooth: true
                        fillMode: root.keepsShape ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                        source: {
                            const r = tile.record;
                            if (!r)
                                return "";

                            return r.thumb_local && r.thumb_local.length > 0 ? r.thumb_local : (r.thumb || r.url || "");
                        }
                        sourceSize.width: Math.round(parent.width * 1.5)
                    }

                    // An export is a thing you DID, not just a thing you saw.
                    MaterialSymbol {
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 4
                        visible: tile.modelData.kind === "export"
                        text: "output"
                        iconSize: 13
                        color: "white"
                    }

                    HoverHandler {
                        id: tileHover

                        cursorShape: Qt.PointingHandCursor
                    }

                    TapHandler {
                        id: tileTap

                        gesturePolicy: TapHandler.ReleaseWithinBounds
                        onTapped: root.act(tile.modelData)
                    }

                }

            }

        }

        StyledListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.asRows || root.kind === "search"
            model: root.entries
            clip: true
            spacing: 2

            delegate: Rectangle {
                required property var modelData

                width: ListView.view.width
                implicitHeight: 46
                radius: Appearance.rounding.small
                color: rowTap.containsPress ? Appearance.colors.colLayer2Active : rowTap.containsMouse ? Appearance.colors.colLayer2Hover : ColorUtils.transparentize(Appearance.colors.colLayer2Hover, 1)

                /*
                 * THE PICTURE, WHERE THE GLYPH WAS.
                 *
                 * Every opened row read as `redgifs:discretelighthammerkop`
                 * beside a generic image icon — an id is what the database
                 * calls it, not what you remember about it. The record is
                 * already in hand (`recordFor`), so the row shows the thing
                 * itself and keeps the glyph for the entries that genuinely
                 * have no picture: a search, an export.
                 */
                readonly property var record: modelData.item && modelData.item.length > 0 ? Catalog.recordFor(modelData.item) : null

                Item {
                    id: rowIcon

                    anchors.left: parent.left
                    anchors.leftMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    width: 38
                    height: 38

                    // The same route the tiles above use: whatever local file
                    // the record already names, else the remote thumbnail.
                    Rectangle {
                        anchors.fill: parent
                        visible: !!rowIcon.parent.record
                        radius: Appearance.rounding.small
                        color: Appearance.colors.colLayer2
                        clip: true

                        Image {
                            anchors.fill: parent
                            asynchronous: true
                            cache: true
                            smooth: true
                            fillMode: Image.PreserveAspectCrop
                            sourceSize.width: 76
                            source: {
                                const r = rowIcon.parent.record;
                                if (!r)
                                    return "";

                                return r.thumb_local && r.thumb_local.length > 0 ? r.thumb_local : (r.thumb || r.url || "");
                            }
                        }

                    }

                    MaterialSymbol {
                        anchors.centerIn: parent
                        visible: !rowIcon.parent.record
                        text: modelData.kind === "search" ? "search" : modelData.kind === "export" ? "output" : "image"
                        iconSize: 20
                        color: Appearance.colors.colSubtext
                    }

                }

                ColumnLayout {
                    anchors.left: rowIcon.right
                    anchors.right: when.left
                    anchors.leftMargin: 12
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: -2

                    StyledText {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        /*
                         * Its title, then what was typed, then — only when
                         * neither exists — the id. `value` holds the title a
                         * lens recorded, which is the one thing here written
                         * for a person to read.
                         */
                        text: {
                            if (modelData.kind === "search")
                                return modelData.value;

                            if (modelData.value && modelData.value.length > 0)
                                return modelData.value;

                            const rec = rowIcon.parent.record;
                            return rec && rec.title && rec.title.length > 0 ? rec.title : modelData.item;
                        }
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: Appearance.colors.colOnLayer1
                    }

                    StyledText {
                        Layout.fillWidth: true
                        visible: modelData.kind === "export" && !!modelData.value
                        elide: Text.ElideRight
                        text: `to ${modelData.value}`
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: Appearance.colors.colSubtext
                    }

                }

                StyledText {
                    id: when

                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.ago(modelData.at)
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: Appearance.colors.colSubtext
                }

                MouseArea {
                    id: rowTap

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.act(modelData)
                }

                Behavior on color {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }

            }

        }

        StyledText {
            Layout.fillWidth: true
            Layout.bottomMargin: 6
            horizontalAlignment: Text.AlignHCenter
            visible: root.entries.length === 0
            text: root.loading ? "Looking…" : root.failure.length > 0 ? `History could not be read — ${root.failure}` : Prefs.keepHistory ? "Nothing here yet" : "History is switched off in settings"
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: root.failure.length > 0 ? Appearance.colors.colError : Appearance.colors.colSubtext
        }

    }

}
