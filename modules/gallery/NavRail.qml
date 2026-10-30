import QtQuick
import QtQuick.Layouts
import qs.modules.common
import qs.modules.widgets
import qs.services

/*
 * THE NAVIGATION RAIL.
 *
 * A catalogue of 130,000 pictures had exactly one way in: typing. Every
 * application people trust with a big library — a photo manager, a file
 * manager, a music player — puts its structure on the left, so you can see what
 * is in there before you know what to ask for.
 *
 * Nothing here is a second filter system. Every row writes the same query
 * token you could type (`family:video`, `kind:avatar`, `collection:x`), and
 * every row lights up by READING the query — so typing `kind:avatar` by hand
 * selects Avatars, and there is one source of truth, which is the bar.
 *
 * Counts come from the daemon's facets, over the whole catalogue.
 */
Item {
    id: root

    property bool expanded: true
    readonly property int expandedWidth: 236
    readonly property int collapsedWidth: 72
    property real visualWidth: root.implicitWidth
    // their labels by it, so text arrives with the width rather than on a timer.
    readonly property real openness: Math.max(0, Math.min(1, (root.visualWidth - root.collapsedWidth) / (root.expandedWidth - root.collapsedWidth)))
    // ── what is on offer ────────────────────────────────────────────────────
    readonly property var familyMeta: ({
        "raster": {
            "label": "Pictures",
            "icon": "image"
        },
        "video": {
            "label": "Videos",
            "icon": "movie"
        },
        "vector": {
            "label": "Vectors",
            "icon": "shapes"
        },
        "model": {
            "label": "3D models",
            "icon": "view_in_ar"
        },
        "audio": {
            "label": "Audio",
            "icon": "music_note"
        }
    })
    readonly property var kindMeta: ({
        "wallpaper": {
            "label": "Wallpapers",
            "icon": "wallpaper"
        },
        // A material's maps and an environment map are pictures you use in 3D
        // work, not meshes — filing them under "3D models" made that count
        // five times the number of models actually there.
        "texture": {
            "label": "Textures",
            "icon": "texture"
        },
        "hdri": {
            "label": "HDRIs",
            "icon": "panorama_photosphere"
        },
        "model": {
            "label": "3D models",
            "icon": "view_in_ar"
        },
        "avatar": {
            "label": "Avatars",
            "icon": "account_circle"
        },
        "cover": {
            "label": "Covers",
            "icon": "panorama"
        },
        "banner": {
            "label": "Banners",
            "icon": "view_day"
        },
        "icon": {
            "label": "Icons",
            "icon": "interests"
        },
        "emote": {
            "label": "Emotes",
            "icon": "mood"
        },
        "sticker": {
            "label": "Stickers",
            "icon": "sticky_note_2"
        }
    })
    readonly property int total: {
        let n = 0;
        for (const f of Catalog.facetFamilies) n += f.items || 0
        return n;
    }
    /// A lens with rows of its own is showing: the rail is its navigation.
    readonly property bool inLens: Lenses.activeId.length > 0 && Lenses.activeNav.length > 0
    readonly property bool nothingPicked: Catalog.family.length === 0 && Catalog.kind.length === 0 && Catalog.filterValue("collection").length === 0

    // Asked, not set: `expanded` is bound by the window (preference and width),
    // and assigning it from in here would cut that binding for good.
    signal toggleRequested()
    signal settingsRequested()
    signal sourcesRequested()
    /// The kept record, not this session's back/forward (that is
    /// `historyRequested`, which the mark's right-click opens).
    signal historyPanelRequested()
    /// Right-click on the mark: the history menu, at this point in the rail.
    signal historyRequested(Item from, real x, real y)
    /// A lens row was right-clicked. The shell draws the menu, because a popup
    /// inside the rail would be clipped by it.
    signal rowMenuRequested(Item from, string id, real x, real y)

    function label(meta, id) {
        return meta[id] ? meta[id].label : id.charAt(0).toUpperCase() + id.slice(1);
    }

    function glyph(meta, id, fallback) {
        return meta[id] ? meta[id].icon : fallback;
    }

    /// 118936 → "118.9k+" while fetching is endless: the number is what has
    /// been fetched so far, and without the "+" it read as all there is.
    function compact(n) {
        const base = root._compact(n);
        return base.length > 0 && Prefs.fetchMode !== "catalog" ? base + "+" : base;
    }

    /// 118936 → "118.9k"; small numbers stay exact, because "7" is not "0k".
    function _compact(n) {
        if (!(n > 0))
            return "";

        if (n >= 1e+06)
            return (n / 1e+06).toFixed(1).replace(/\.0$/, "") + "M";

        if (n >= 10000)
            return Math.round(n / 1000) + "k";

        if (n >= 1000)
            return (n / 1000).toFixed(1).replace(/\.0$/, "") + "k";

        return String(n);
    }

    /*
     * GROUPS, FOLDED UNTIL WANTED.
     *
     * Every family, every kind and every collection listed at once was a wall
     * of rows before you had asked for any of them. Each group folds; a folded
     * group still shows the row that is SELECTED, so the rail never hides the
     * filter you are looking at through it. Remembered between runs.
     */
    function groupOpen(key) {
        const groups = Prefs.railGroups || {
        };
        return groups[key] === true;
    }

    function toggleGroup(key) {
        const groups = Object.assign({
        }, Prefs.railGroups || {
        });
        groups[key] = !(groups[key] === true);
        Prefs.railGroups = groups;
    }

    /*
     * TWO WIDTHS: WHERE THE LAYOUT IS, AND WHAT YOU SEE.
     *
     * Animating the width the layout reads made the whole picture wall re-run
     * its masonry on every frame of the tween, and that stuttered. Not
     * animating it at all made the rail snap, which is not smooth either.
     *
     * So the layout width (`implicitWidth`) changes ONCE, and the wall lays out
     * once. What animates is `visualWidth` — the rail's own surface, which is
     * a dozen rows and costs nothing to reflow — while the window moves the
     * content column by the difference with a transform (see shell.qml), which
     * the GPU does without laying anything out. The content glides; the wall
     * underneath it has already settled.
     */
    implicitWidth: root.expanded ? root.expandedWidth : root.collapsedWidth

    // ── layout ──────────────────────────────────────────────────────────────
    // The surface: the width you see, painted in the window's own colour so the
    // content sliding under its edge disappears behind it cleanly.
    Rectangle {
        id: surface

        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        width: root.visualWidth
        color: Appearance.colors.colLayer0Base
        clip: true

        ColumnLayout {
            anchors.fill: parent
            anchors.topMargin: 12
            anchors.bottomMargin: 12
            // The same margins in both states, so icons never shift sideways while
            // the rail changes width — only the labels come and go.
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            spacing: 2

            // The mark and the name: the one place the app says what it is.
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 44
                Layout.bottomMargin: 10
                spacing: 10

                /*
             * THE MARK IS ALSO THE WAY BACK.
             *
             * While you are exploring — a "like this", a tag, another search —
             * the mountain turns into a back arrow, where a browser keeps it:
             * top left. Click goes one step back, right-click lists where you
             * have been. At home, with nowhere to go back to, it is the mark
             * again and toggles the rail as it always did.
             */
                Rectangle {
                    id: mark

                    readonly property bool back: Catalog.canGoBack

                    Layout.preferredWidth: 40
                    Layout.preferredHeight: 40
                    Layout.leftMargin: 6
                    radius: markMouse.containsPress ? 10 : markMouse.containsMouse && mark.back ? 20 : 12
                    color: markMouse.containsPress ? Appearance.colors.colPrimaryContainerActive : markMouse.containsMouse ? Appearance.colors.colPrimaryContainerHover : Appearance.colors.colPrimaryContainer

                    MaterialSymbol {
                        anchors.centerIn: parent
                        text: "landscape"
                        iconSize: 24
                        fill: 1
                        color: Appearance.colors.colOnPrimaryContainer
                        opacity: mark.back ? 0 : 1
                        scale: mark.back ? 0.6 : 1
                        rotation: mark.back ? 90 : 0

                        Behavior on opacity {
                            NumberAnimation {
                                duration: 180
                                easing.type: Easing.OutCubic
                            }

                        }

                        Behavior on scale {
                            NumberAnimation {
                                duration: 260
                                easing.type: Easing.OutBack
                            }

                        }

                        Behavior on rotation {
                            NumberAnimation {
                                duration: 260
                                easing.type: Easing.OutCubic
                            }

                        }

                    }

                    MaterialSymbol {
                        anchors.centerIn: parent
                        text: "arrow_back"
                        iconSize: 24
                        fill: 1
                        color: Appearance.colors.colOnPrimaryContainer
                        opacity: mark.back ? 1 : 0
                        scale: mark.back ? 1 : 0.6
                        rotation: mark.back ? 0 : -90

                        Behavior on opacity {
                            NumberAnimation {
                                duration: 180
                                easing.type: Easing.OutCubic
                            }

                        }

                        Behavior on scale {
                            NumberAnimation {
                                duration: 260
                                easing.type: Easing.OutBack
                            }

                        }

                        Behavior on rotation {
                            NumberAnimation {
                                duration: 260
                                easing.type: Easing.OutCubic
                            }

                        }

                    }

                    MouseArea {
                        // In the narrow rail the mark is the way back out.

                        id: markMouse

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                        onClicked: (mouse) => {
                            if (mouse.button === Qt.RightButton)
                                root.historyRequested(mark, mark.width / 2, mark.height + 6);
                            else if (mouse.button === Qt.MiddleButton)
                                Catalog.forward();
                            else if (mark.back)
                                Catalog.back();
                            else
                                root.toggleRequested();
                        }
                    }

                    StyledToolTip {
                        visible: markMouse.containsMouse
                        text: mark.back ? `Back to ${Catalog.describeStep(Catalog.history[Catalog.history.length - 1])}  ·  right-click for history` : root.expanded ? "quarry" : "Expand"
                    }

                    Behavior on radius {
                        NumberAnimation {
                            duration: Appearance.animation.elementMoveFast.duration
                            easing.type: Easing.OutCubic
                        }

                    }

                    Behavior on color {
                        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(mark)
                    }

                }

                ColumnLayout {
                    visible: opacity > 0
                    opacity: Math.max(0, Math.min(1, (root.openness - 0.35) / 0.65))
                    Layout.fillWidth: true
                    spacing: -2

                    StyledText {
                        text: "quarry"
                        font.pixelSize: Appearance.font.pixelSize.larger
                        font.weight: Font.DemiBold
                        color: Appearance.colors.colOnLayer0
                    }

                    StyledText {
                        text: Client.connected ? `${root.compact(root.total)} items` : "daemon offline"
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: Client.connected ? Appearance.colors.colSubtext : Appearance.colors.colError
                    }

                }

                IconButton {
                    visible: opacity > 0
                    opacity: Math.max(0, Math.min(1, (root.openness - 0.5) / 0.5))
                    icon: "left_panel_close"
                    size: 32
                    iconSize: 20
                    tooltip: "Collapse"
                    onClicked: root.toggleRequested()
                }

            }

            Flickable {
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentHeight: list.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height

                ColumnLayout {
                    id: list

                    width: parent.width
                    spacing: 2

                    /*
                 * THE RAIL BECOMES THE LENS'S OWN.
                 *
                 * A lens is a different place with different things to move
                 * between — boards, not media families — so while one is open
                 * the rail shows its rows and one way back. Quarry's own rows
                 * are still there underneath the moment the lens closes.
                 */
                    NavRailItem {
                        visible: root.inLens
                        Layout.fillWidth: true
                        expanded: root.expanded
                        openness: root.openness
                        icon: "arrow_back"
                        label: "Back to quarry"
                        onTriggered: Lenses.close()
                    }

                    NavRailCaption {
                        // A lens with no rows of its own gets no heading over them.
                        visible: root.inLens && Lenses.activeNav.length > 0
                        rows: Lenses.activeNav.length
                        text: Lenses.activeEntry ? Lenses.activeEntry.name : "Lens"
                        expanded: root.expanded
                        openness: root.openness
                        open: true
                        // A lens's rail sections do not fold, so this heading
                        // does not offer to fold them.
                        foldable: false
                    }

                    /*
                     * A LENS CAN PUT HEADINGS IN ITS RAIL, NOT ONLY ROWS.
                     *
                     * Reddit's rail is four sorts, then the subreddits you
                     * chose, then the ones you happened to open, then the
                     * site's whole directory — twenty identical pills with no
                     * sign of where one group ends. quarry's own rail has had
                     * captions for exactly this since the beginning; a lens
                     * could not ask for one.
                     *
                     * `{ caption: true, label: "…" }` in `navItems` draws the
                     * same heading the gallery uses, so a lens's rail and the
                     * app's look like one thing rather than two.
                     */
                    Repeater {
                        model: root.inLens ? Lenses.activeNav : []

                        delegate: Item {
                            required property var modelData

                            Layout.fillWidth: true
                            implicitHeight: Math.max(caption.visible ? caption.implicitHeight : 0, pill.visible ? pill.implicitHeight : 0)

                            NavRailCaption {
                                id: caption

                                anchors.left: parent.left
                                anchors.right: parent.right
                                visible: parent.modelData.caption === true
                                text: parent.modelData.label || ""
                                summary: parent.modelData.sublabel || ""
                                rows: -1
                                expanded: root.expanded
                                openness: root.openness
                                open: true
                                foldable: false
                            }

                            NavRailItem {
                                id: pill

                                anchors.left: parent.left
                                anchors.right: parent.right
                                visible: parent.modelData.caption !== true
                                expanded: root.expanded
                                openness: root.openness
                                icon: parent.modelData.icon || "chevron_right"
                                // A lens may hand a row its own picture — Morse
                                // sends the chat's photo, Reddit the community's
                                // icon — and the glyph stays the fallback.
                                picture: parent.modelData.picture || ""
                                label: parent.modelData.label || ""
                                sublabel: parent.modelData.sublabel || ""
                                count: parent.modelData.count || ""
                                active: parent.modelData.active === true
                                onTriggered: Lenses.navPick(parent.modelData.id)
                                /*
                                 * A row the lens owns gets the menu the lens
                                 * writes for it. Nothing here knows what a
                                 * subreddit or a chat is, and a rail that
                                 * hard-coded "unpin" would be a rail that only
                                 * ever worked for the lens it was written
                                 * against.
                                 */
                                onContextRequested: (x, y) => {
                                    return root.rowMenuRequested(pill, parent.modelData.id, x, y);
                                }
                            }

                        }

                    }

                    // A lens's faces (navTiles): two to a row, one in the narrow rail.
                    GridLayout {
                        Layout.fillWidth: true
                        Layout.topMargin: 4
                        visible: root.inLens && Lenses.activeTiles.length > 0
                        columns: root.expanded ? 2 : 1
                        columnSpacing: 4
                        rowSpacing: 4

                        Repeater {
                            model: root.inLens ? Lenses.activeTiles : []

                            delegate: NavRailTile {
                                id: tile

                                required property var modelData

                                Layout.fillWidth: true
                                showLabel: root.expanded
                                label: modelData.label || ""
                                picture: modelData.picture || ""
                                icon: modelData.icon || "chat"
                                initials: modelData.initials || ""
                                hue: modelData.hue !== undefined ? modelData.hue : -1
                                count: modelData.count || ""
                                active: modelData.active === true
                                onTriggered: Lenses.navPick(modelData.id)
                                onContextRequested: (x, y) => {
                                    return root.rowMenuRequested(tile, modelData.id, x, y);
                                }
                            }
                        }
                    }

                    NavRailItem {
                        visible: !root.inLens
                        Layout.fillWidth: true
                        expanded: root.expanded
                        openness: root.openness
                        icon: "auto_awesome_mosaic"
                        label: "Everything"
                        count: root.compact(root.total)
                        onContextRequested: (x, y) => {
                            return root.rowMenuRequested(this, "app:everything", x, y);
                        }
                        active: root.nothingPicked && !Catalog.similarTo
                        onTriggered: Catalog.step(() => {
                            Catalog.clearSimilar();
                            Catalog.setFilter("family", "");
                            Catalog.setFilter("kind", "");
                            Catalog.setFilter("collection", "");
                        })
                    }

                    NavRailCaption {
                        // An empty group is not a group: with no families in the
                        // catalogue this was a caption over nothing, and collapsed
                        // it was a hairline floating in the rail.
                        visible: !root.inLens && Catalog.facetFamilies.length > 0
                        rows: Catalog.facetFamilies.length
                        text: "Media"
                        expanded: root.expanded
                        openness: root.openness
                        open: root.groupOpen("media")
                        summary: Catalog.family.length > 0 ? root.label(root.familyMeta, Catalog.family) : ""
                        onToggled: root.toggleGroup("media")
                    }

                    Repeater {
                        model: Catalog.facetFamilies

                        delegate: NavRailItem {
                            required property var modelData

                            Layout.fillWidth: true
                            expanded: root.expanded
                            openness: root.openness
                            icon: root.glyph(root.familyMeta, modelData.id, "category")
                            label: root.label(root.familyMeta, modelData.id)
                            count: root.compact(modelData.items)
                            active: Catalog.family === modelData.id
                            shown: !root.inLens && root.groupOpen("media") || active
                            onContextRequested: (x, y) => {
                                return root.rowMenuRequested(this, `app:family:${modelData.id}`, x, y);
                            }
                            onTriggered: Catalog.setFilter("family", active ? "" : modelData.id)
                        }

                    }

                    NavRailCaption {
                        visible: !root.inLens && Catalog.facetKinds.length > 0
                        rows: Catalog.facetKinds.length
                        text: "Made for"
                        expanded: root.expanded
                        openness: root.openness
                        open: root.groupOpen("kinds")
                        summary: Catalog.kind.length > 0 ? root.label(root.kindMeta, Catalog.kind) : ""
                        onToggled: root.toggleGroup("kinds")
                    }

                    Repeater {
                        model: Catalog.facetKinds

                        delegate: NavRailItem {
                            required property var modelData

                            Layout.fillWidth: true
                            expanded: root.expanded
                            openness: root.openness
                            icon: root.glyph(root.kindMeta, modelData.id, "label")
                            label: root.label(root.kindMeta, modelData.id)
                            count: root.compact(modelData.items)
                            active: Catalog.kind === modelData.id
                            shown: !root.inLens && root.groupOpen("kinds") || active
                            onTriggered: Catalog.setFilter("kind", active ? "" : modelData.id)
                            onContextRequested: (x, y) => {
                                return root.rowMenuRequested(this, `app:kind:${modelData.id}`, x, y);
                            }
                        }

                    }

                    NavRailCaption {
                        visible: !root.inLens
                        // History and Boards are always under it.
                        rows: Catalog.collections.length + 2
                        text: "Library"
                        expanded: root.expanded
                        openness: root.openness
                        open: root.groupOpen("library")
                        summary: Catalog.filterValue("collection")
                        onToggled: root.toggleGroup("library")
                    }

                    Repeater {
                        model: Catalog.collections

                        delegate: NavRailItem {
                            required property var modelData

                            Layout.fillWidth: true
                            expanded: root.expanded
                            openness: root.openness
                            icon: "bookmarks"
                            label: modelData.name
                            // A collection holds exactly what you kept: no "+".
                            count: root._compact(modelData.items)
                            active: Catalog.filterValue("collection") === modelData.name
                            shown: !root.inLens && root.groupOpen("library") || active
                            onTriggered: Catalog.setFilter("collection", active ? "" : modelData.name)
                            onContextRequested: (x, y) => {
                                return root.rowMenuRequested(this, `app:collection:${modelData.name}`, x, y);
                            }
                        }

                    }

                    NavRailItem {
                        Layout.fillWidth: true
                        expanded: root.expanded
                        openness: root.openness
                        icon: "history"
                        shown: !root.inLens && root.groupOpen("library")
                        label: "History"
                        onTriggered: root.historyPanelRequested()
                        onContextRequested: (x, y) => {
                            return root.rowMenuRequested(this, "app:history", x, y);
                        }
                    }

                    NavRailItem {
                        Layout.fillWidth: true
                        expanded: root.expanded
                        openness: root.openness
                        icon: "dashboard"
                        shown: !root.inLens && root.groupOpen("library")
                        label: "Boards"
                        count: Catalog.boards.length > 0 ? String(Catalog.boards.length) : ""
                        trailingIcon: "open_in_new"
                        onTriggered: Sys.openBoard("")
                    }

                    /*
                 * LENSES — a site with its own screens, opened like a view.
                 *
                 * Only lenses that asked for a rail row and are switched on;
                 * with none installed the caption is not drawn either, so the
                 * rail is exactly what it was.
                 */
                    NavRailCaption {
                        text: "Lenses"
                        rows: Lenses.railEntries.length
                        visible: Lenses.railEntries.length > 0
                        expanded: root.expanded
                        openness: root.openness
                        open: root.groupOpen("lenses")
                        summary: Lenses.activeId.length > 0 ? Lenses.activeId : ""
                        onToggled: root.toggleGroup("lenses")
                    }

                    Repeater {
                        model: Lenses.railEntries

                        delegate: NavRailItem {
                            required property var modelData

                            Layout.fillWidth: true
                            expanded: root.expanded
                            openness: root.openness
                            icon: modelData.icon
                            iconImage: modelData.iconImage || ""
                            label: modelData.name
                            active: Lenses.activeId === modelData.id
                            shown: !root.inLens && root.groupOpen("lenses") || active
                            onTriggered: Lenses.activeId === modelData.id ? Lenses.close() : Lenses.open(modelData.id)
                        }

                    }

                }

            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                Layout.topMargin: 6
                Layout.bottomMargin: 6
                color: Appearance.colors.colOutlineVariant
                opacity: 0.6
            }

            NavRailItem {
                Layout.fillWidth: true
                expanded: root.expanded
                openness: root.openness
                icon: "tune"
                label: "Sources & filters"
                // Every other row here counts what you will see if you press
                // it; this one printed 165 in that slot — the number of sources
                // that exist — and said nothing about the drawer being open or
                // any filter being on, which the funnel in the query bar
                // already knows.
                count: Catalog.facetSources.length > 0 ? String(Catalog.facetSources.length) : ""
                active: !!Shell.filterPanel && Shell.filterPanel.open
                trailingIcon: Shell.filterPanel && Shell.filterPanel.activeCount > 0 ? "filter_alt" : ""
                onTriggered: root.sourcesRequested()
            }

            NavRailItem {
                Layout.fillWidth: true
                expanded: root.expanded
                openness: root.openness
                icon: "settings"
                label: "Settings"
                onTriggered: root.settingsRequested()
            }

        }

    }

    Behavior on visualWidth {
        NumberAnimation {
            duration: Appearance.animDur(320)
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Appearance.animationCurves.emphasizedDecel
        }

    }
    // 0 when collapsed, 1 when expanded, continuous in between: the rows fade

}
