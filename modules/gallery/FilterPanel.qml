import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/*
 * FILTERS, AS A DRAWER YOU CAN ACTUALLY USE.
 *
 * It was nine flat sections in one long scroll — reaching the sources meant
 * scrolling past six of them, forty-nine sources sat in one undivided list
 * with the adult ones in plain sight, and there was no way to find a filter
 * except to remember where it lived.
 *
 * Now: collapsible cards that say what they are set to while shut, one search
 * that finds a filter or a source, sources grouped by category with the adult
 * group locked while adult results are off, and a drawer that is exactly the
 * gallery card it slides over.
 *
 * STILL ONE SOURCE OF TRUTH. Every control reads its state out of
 * `Catalog.query` and writes a token back into it — `ratio>1.1`, `w>=3840`,
 * `source:a,b` — exactly what you could type. There is no second filter state.
 */
Sheet {
    id: root

    placement: "topRight"

    /*
     * THE DRAWER IS PART OF THE GALLERY CARD, not a sheet floating over the
     * window: same top, same bottom, same right edge, same corner radius. It
     * was sized off the window instead, so it overhung the card at the top and
     * sat proud of it at the bottom, and read as a separate surface.
     *
     * Every view that registers as `Shell.gallery` is a child of that card, so
     * its parent is the card — there is no other handle to it from out here.
     */
    readonly property Item galleryCard: Shell.gallery ? Shell.gallery.parent : null

    /*
     * The card's rect in this item's coordinates. Reading width/height/x/y is
     * what makes the binding re-run on a resize: `mapToItem` registers no
     * dependency of its own, so without them the drawer would keep whatever
     * size the card happened to have when the panel was built.
     */
    readonly property rect cardRect: {
        const rw = root.width, rh = root.height;
        const c = root.galleryCard;
        // Before the first view registers: the card's own margins, with the
        // header allowed for. Lasts a frame or two at startup.
        if (!c || !(c.width > 0) || !(c.height > 0))
            return Qt.rect(2, 74, Math.max(0, rw - 14), Math.max(0, rh - 86));
        const w = c.width, h = c.height, cx = c.x, cy = c.y;
        const at = c.mapToItem(root, 0, 0);
        return Qt.rect(at.x, at.y, w, h);
    }

    topInset: root.cardRect.y
    inset: Math.max(0, root.width - (root.cardRect.x + root.cardRect.width))

    // A drawer that eats a 620px window is not a drawer; one that grows past
    // 440 is a column of chips with a hole down the middle.
    surfaceWidth: Math.round(Math.min(440, Math.max(280, Math.min(root.cardRect.width - 16, root.cardRect.width * 0.62))))
    surfaceHeight: Math.max(160, root.cardRect.height)

    function toggle() {
        root.open = !root.open;
        if (root.open) {
            Catalog.refreshFacets();
            Catalog.refreshCollections();
            root.loadSections();
            root.query = "";
            root.sourceNeedle = "";
            sourceField.text = "";
            searchField.text = "";
        }
    }

    // ── the query, as tokens ────────────────────────────────────────────────
    readonly property var tokens: (Catalog.query || "").split(/\s+/).filter(t => t.length > 0)

    /// Every token for `key`, whatever its operator: `ratio>1.1`, `ratio<=2`…
    function tokensFor(key) {
        const re = new RegExp("^-?" + key + "(:|>=|<=|>|<)");
        return root.tokens.filter(t => re.test(t));
    }

    /// Replace every `key` token with `replacement` (a string of tokens, or "").
    function setTokens(key, replacement) {
        const re = new RegExp("^-?" + key + "(:|>=|<=|>|<)");
        const kept = root.tokens.filter(t => !re.test(t));
        if (replacement && replacement.length > 0)
            kept.push(replacement);
        Catalog.query = kept.join(" ");
    }

    function hasWord(word) {
        return root.tokens.indexOf(word) >= 0;
    }

    function setWord(word, on) {
        const kept = root.tokens.filter(t => t !== word);
        if (on)
            kept.push(word);
        Catalog.query = kept.join(" ");
    }

    function removeToken(token) {
        let kept = root.tokens.filter(t => t !== token);
        // A colour means nothing without its tolerance, and the reverse.
        if (token.startsWith("color:") || token.startsWith("dist"))
            kept = kept.filter(t => !t.startsWith("color:") && !/^dist(<|<=|:)/.test(t));
        Catalog.query = kept.join(" ");
    }

    readonly property var selectedSources: {
        const t = root.tokensFor("source");
        return t.length > 0 ? t[0].replace(/^-?source:/, "").split(",").filter(s => s.length > 0) : [];
    }

    function toggleSource(id) {
        const now = root.selectedSources.slice();
        const at = now.indexOf(id);
        if (at >= 0)
            now.splice(at, 1);
        else
            now.push(id);
        root.setTokens("source", now.length > 0 ? `source:${now.join(",")}` : "");
    }

    /// Whole categories at once — the reason to group them in the first place.
    function setSources(ids, on) {
        const now = root.selectedSources.slice();
        for (let i = 0; i < ids.length; i++) {
            const at = now.indexOf(ids[i]);
            if (on && at < 0)
                now.push(ids[i]);
            else if (!on && at >= 0)
                now.splice(at, 1);
        }
        root.setTokens("source", now.length > 0 ? `source:${now.join(",")}` : "");
    }

    /// What a token means, in words, for the chips at the top.
    function describe(token) {
        const labels = {
            "sort:new": "Newest first",
            "sort:random": "Shuffled",
            "sort:large": "Largest first",
            "sort:wide": "Widest first",
            "sort:title": "A to Z",
            "animated": "Animated",
            "-nsfw": "No adult",
            "nsfw": "Adult only",
            "video": "Videos"
        };
        if (labels[token])
            return labels[token];
        let m;
        if ((m = token.match(/^kind:(.+)$/)))
            return m[1].charAt(0).toUpperCase() + m[1].slice(1);
        if ((m = token.match(/^family:(.+)$/)))
            return root.familyLabel(m[1]);
        if ((m = token.match(/^source:(.+)$/))) {
            const list = m[1].split(",");
            return list.length === 1 ? list[0] : `${list.length} sources`;
        }
        if ((m = token.match(/^w>=(\d+)$/)))
            return `${m[1]}px wide or more`;
        if (token === "ratio>1.1")
            return "Landscape";
        if (token === "ratio<0.9")
            return "Portrait";
        if (token.startsWith("ratio"))
            return "Near square";
        if ((m = token.match(/^color:(#[0-9a-fA-F]{6})$/)))
            return m[1].toUpperCase();
        if ((m = token.match(/^tag:(.+)$/)))
            return `#${m[1]}`;
        if ((m = token.match(/^collection:(.+)$/)))
            return m[1];
        return `“${token}”`;
    }

    function familyLabel(id) {
        return ({
                "raster": "Pictures",
                "video": "Videos",
                "vector": "Vectors",
                "model": "3D models",
                "audio": "Audio"
            })[id] || id.charAt(0).toUpperCase() + id.slice(1);
    }

    function compact(n) {
        if (!(n > 0))
            return "";
        if (n >= 10000)
            return Math.round(n / 1000) + "k";
        if (n >= 1000)
            return (n / 1000).toFixed(1).replace(/\.0$/, "") + "k";
        return String(n);
    }

    // `dist<25` is the tolerance half of a colour, not a filter of its own.
    readonly property var activeChips: root.tokens.filter(t => !/^dist(<|<=|:)/.test(t))
    readonly property int activeCount: root.activeChips.length

    // Kept for the probe and the tests: what the panel is built from.
    readonly property var rows: ["active", "sort", "media", "made-for", "shape", "resolution", "colour", "motion", "sources", "topics"]

    /*
     * WHAT EACH SITE OFFERS, FROM THE DAEMON.
     *
     * Read here rather than through Catalog because this is the only screen
     * that shows them; one `sources` call when the drawer opens is cheaper than
     * holding 477 rows for the life of the process.
     */
    property var sections: []

    function loadSections() {
        if (!Client.connected)
            return;
        Client.call("sources", {}, function (err, payload) {
            if (err || !payload)
                return;
            root.sections = payload.sections || [];
        });
    }

    /// The sources that publish sections at all, for the picker.
    readonly property var sectionSources: {
        const seen = {};
        const out = [];
        for (const row of root.sections)
            if (!seen[row.source]) {
                seen[row.source] = true;
                out.push(row.source);
            }
        return out;
    }

    /*
     * A site's sections only mean anything while you are looking at that site,
     * so the card follows `source:` in the query. With none picked it offers
     * the sites that have any, which is the step you were going to take.
     */
    readonly property string sectionSource: Catalog.source

    readonly property var sectionGroups: {
        if (root.sectionSource.length === 0)
            return [];
        const groups = [];
        const index = {};
        for (const row of root.sections) {
            if (row.source !== root.sectionSource)
                continue;
            const name = row.group || "Sections";
            if (index[name] === undefined) {
                index[name] = groups.length;
                groups.push({
                    "group": name,
                    "rows": []
                });
            }
            groups[index[name]].rows.push(row);
        }
        return groups;
    }

    /// Whether a section's query is already in the bar, token for token.
    function sectionOn(row) {
        const wanted = String(row.q || row.label).split(/\s+/).filter(t => t.length > 0);
        return wanted.length > 0 && wanted.every(t => root.tokens.indexOf(t) >= 0);
    }

    /*
     * Picking one REPLACES the last one.
     *
     * Two categories at once is an AND the sites cannot answer — it returns
     * nothing and reads as a broken filter — so choosing "anal" after "amateur"
     * moves you rather than narrowing to the intersection of both.
     */
    function chooseSection(row, on) {
        const mine = {};
        for (const other of root.sections)
            if (other.source === root.sectionSource && (other.group || "Sections") === (row.group || "Sections"))
                for (const t of String(other.q || other.label).split(/\s+/))
                    mine[t] = true;
        let kept = root.tokens.filter(t => !mine[t]);
        if (on)
            kept = kept.concat(String(row.q || row.label).split(/\s+/).filter(t => t.length > 0));
        Catalog.query = kept.join(" ");
    }

    // ── searching the filters themselves ────────────────────────────────────

    property string query: ""
    readonly property string filter: root.query.trim().toLowerCase()
    readonly property bool searching: root.filter.length > 0

    function matches(text) {
        return root.filter.length === 0 || String(text).toLowerCase().indexOf(root.filter) >= 0;
    }

    // ── which cards are open ────────────────────────────────────────────────

    /*
     * Open by default: the three you change most. The rest state what they are
     * set to on their header, so a shut card never hides a live filter.
     * In memory only — a drawer is a thing you open, not a thing you configure.
     */
    property var openGroups: ({
            "sources": true,
            "src:wallpapers": true,
            "src:icons": true
        })

    function isOpen(id) {
        return root.openGroups[id] === true;
    }
    function toggleGroup(id) {
        const m = {};
        for (const k in root.openGroups)
            m[k] = root.openGroups[k];
        m[id] = !(m[id] === true);
        root.openGroups = m;
    }

    // ── sources, grouped by what they are ───────────────────────────────────

    readonly property var categoryOrder: ["wallpapers", "photography", "art", "icons", "video", "adult", "local"]
    readonly property var categoryMeta: ({
            "wallpapers": {
                "label": "Wallpapers",
                "icon": "wallpaper"
            },
            "photography": {
                "label": "Photography",
                "icon": "photo_camera"
            },
            "art": {
                "label": "Art and illustration",
                "icon": "brush"
            },
            "icons": {
                "label": "Icons and vectors",
                "icon": "shapes"
            },
            "video": {
                "label": "Video",
                "icon": "movie"
            },
            "adult": {
                "label": "Adult",
                "icon": "no_adult_content"
            },
            "local": {
                "label": "On this machine",
                "icon": "folder"
            },
            "other": {
                "label": "Everything else",
                "icon": "cloud"
            }
        })

    /// Typed into the Sources card. Separate from the panel-wide search so
    /// narrowing the source list does not also empty the rest of the drawer.
    property string sourceNeedle: ""

    /// category -> its facet entries, biggest first. No adult entry at all while
    /// adult results are off, so no name can reach the rows, the search or the
    /// "all" button — only the locked header's count, which names nothing.
    readonly property var sourcesByCategory: {
        const out = {};
        const list = Catalog.facetSources.slice().sort((a, b) => (b.items || 0) - (a.items || 0));
        for (let i = 0; i < list.length; i++) {
            const s = list[i];
            const raw = s.category || "";
            const cat = root.categoryOrder.indexOf(raw) >= 0 ? raw : "other";
            if (cat === "adult" && !Prefs.showNsfw)
                continue;
            if (!out[cat])
                out[cat] = [];
            out[cat].push(s);
        }
        return out;
    }
    /// Adult keeps its place in the list while locked. A category that simply
    /// vanishes reads as sources gone missing, not as a category held shut.
    readonly property var sourceGroupOrder: root.categoryOrder.concat(["other"]).filter(c => (root.sourcesByCategory[c] || []).length > 0 || (c === "adult" && root.adultHidden))
    readonly property bool adultHidden: !Prefs.showNsfw && root.adultCount > 0
    readonly property int adultCount: Catalog.facetSources.filter(s => s.category === "adult").length
    /// What the Sources card says it holds — never the hidden ones.
    readonly property int listedSources: Catalog.facetSources.length - (Prefs.showNsfw ? 0 : root.adultCount)

    /// Every source id the panel would list, for the Sources card's own search.
    readonly property string sourceBlob: Catalog.facetSources.filter(s => s.category !== "adult" || Prefs.showNsfw).map(s => String(s.id).toLowerCase()).join(" ")

    /// What the source rows narrow by: the card's own field, or the panel-wide
    /// search when that names a source rather than the card itself — typing
    /// "wallhaven" up top has to reach the row, not stop at the card header.
    readonly property string sourceFilter: {
        if (root.sourceNeedle.length > 0)
            return root.sourceNeedle;
        if (root.searching && root.sourceBlob.indexOf(root.filter) >= 0)
            return root.filter;
        return "";
    }
    /// Sources the needle still leaves standing, so the card can say when it
    /// has emptied itself rather than showing a field over nothing.
    readonly property int matchingSources: {
        if (root.sourceFilter.length === 0)
            return -1;
        return root.sourceBlob.split(" ").filter(id => id.indexOf(root.sourceFilter) >= 0).length;
    }

    /// Every term the Topics card offers, flat. What the card counts as "on",
    /// and what a search has to match to find a tag.
    readonly property var suggestedTerms: {
        const out = [];
        const groups = Catalog.suggestions || [];
        for (let i = 0; i < groups.length; i++) {
            const g = groups[i];
            const terms = (g && g.terms) || [];
            for (let j = 0; j < terms.length; j++)
                out.push(terms[j]);
        }
        return out;
    }

    // ── pieces ──────────────────────────────────────────────────────────────

    /// A choice: a pill that is outlined when off and filled when on.
    component Choice: Rectangle {
        id: choice
        property string label: ""
        property string icon: ""
        property string count: ""
        property bool selected: false
        signal clicked

        implicitHeight: 34
        implicitWidth: row.implicitWidth + 26
        radius: height / 2
        color: choice.selected ? (choiceMouse.containsMouse ? Appearance.colors.colSecondaryContainerHover : Appearance.colors.colSecondaryContainer) : (choiceMouse.containsMouse ? Appearance.colors.colLayer2Hover : ColorUtils.transparentize(Appearance.colors.colLayer2Hover, 1))
        border.width: choice.selected ? 0 : 1
        border.color: Appearance.colors.colOutlineVariant

        Behavior on color {
            animation: Appearance.animation.stateChange.colorAnimation.createObject(choice)
        }

        Row {
            id: row
            anchors.centerIn: parent
            spacing: 6

            MaterialSymbol {
                anchors.verticalCenter: parent.verticalCenter
                visible: choice.selected || choice.icon.length > 0
                text: choice.selected ? "check" : choice.icon
                iconSize: 17
                color: choice.selected ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: choice.label
                font.pixelSize: Appearance.font.pixelSize.smallie
                font.weight: choice.selected ? Font.Medium : Font.Normal
                color: choice.selected ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: choice.count.length > 0
                text: choice.count
                font.pixelSize: Appearance.font.pixelSize.smallest
                color: choice.selected ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colSubtext
                opacity: 0.85
            }
        }

        MouseArea {
            id: choiceMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: choice.clicked()
        }
    }

    /// One source category inside the Sources card: a 32px sub-header with its
    /// own count and an all/none, and rows that exist only once it is open.
    component SourceCategory: ColumnLayout {
        id: cat

        required property string category
        readonly property var meta: root.categoryMeta[cat.category] || ({})
        readonly property var items: root.sourcesByCategory[cat.category] || []
        readonly property var shownItems: cat.items.filter(s => root.sourceFilter.length === 0 || String(s.id).toLowerCase().indexOf(root.sourceFilter) >= 0)
        readonly property var ids: cat.items.map(s => s.id)
        readonly property int onCount: cat.ids.filter(id => root.selectedSources.indexOf(id) >= 0).length
        /// Named, counted, and not openable. The ids alone are enough to be
        /// unwelcome on a screen someone else can see.
        readonly property bool locked: cat.category === "adult" && root.adultHidden
        readonly property int total: cat.locked ? root.adultCount : cat.items.length
        // A needle opens what it found, so a match is never behind a chevron.
        readonly property bool open_: !cat.locked && (root.isOpen("src:" + cat.category) || root.sourceFilter.length > 0)

        Layout.fillWidth: true
        spacing: 2
        // A locked group has nothing to match, so a search drops it rather than
        // leaving one dead header standing among the hits.
        visible: cat.locked ? root.sourceFilter.length === 0 : cat.shownItems.length > 0

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 32
            radius: Appearance.rounding.small
            color: subTap.pressed ? Appearance.colors.colLayer2Active : subHover.hovered ? Appearance.colors.colLayer2Hover : ColorUtils.transparentize(Appearance.colors.colLayer2Hover, 1)
            Behavior on color {
                animation: Appearance.animation.stateChange.colorAnimation.createObject(this)
            }

            HoverHandler {
                id: subHover
                enabled: !cat.locked
                cursorShape: Qt.PointingHandCursor
            }
            TapHandler {
                id: subTap
                enabled: !cat.locked
                gesturePolicy: TapHandler.ReleaseWithinBounds
                onTapped: root.toggleGroup("src:" + cat.category)
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 6
                anchors.rightMargin: 4
                spacing: 8

                MaterialSymbol {
                    Layout.alignment: Qt.AlignVCenter
                    text: cat.locked ? "lock" : (cat.meta.icon || "cloud")
                    iconSize: Appearance.font.pixelSize.smallie
                    color: cat.onCount > 0 ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                }
                StyledText {
                    Layout.fillWidth: true
                    text: cat.meta.label || cat.category
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    font.weight: Font.Medium
                    color: Appearance.colors.colOnLayer1
                    elide: Text.ElideRight
                }
                StyledText {
                    text: cat.onCount > 0 ? `${cat.onCount}/${cat.total}` : `${cat.total}`
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: cat.onCount > 0 ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                }
                // All or none for the whole category — the thing you open a
                // category to do, without nine separate presses.
                Rectangle {
                    Layout.alignment: Qt.AlignVCenter
                    visible: !cat.locked
                    implicitWidth: allLabel.implicitWidth + 14
                    implicitHeight: 22
                    radius: height / 2
                    color: allTap.pressed ? Appearance.colors.colLayer3Active : allHover.hovered ? Appearance.colors.colLayer3Hover : Appearance.colors.colLayer3

                    HoverHandler {
                        id: allHover
                        cursorShape: Qt.PointingHandCursor
                    }
                    TapHandler {
                        id: allTap
                        gesturePolicy: TapHandler.ReleaseWithinBounds
                        onTapped: root.setSources(cat.ids, cat.onCount < cat.items.length)
                    }
                    StyledText {
                        id: allLabel
                        anchors.centerIn: parent
                        text: cat.onCount < cat.items.length ? "All" : "None"
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: Appearance.colors.colOnLayer1
                    }
                }
                MaterialSymbol {
                    Layout.alignment: Qt.AlignVCenter
                    visible: !cat.locked
                    text: "expand_more"
                    iconSize: Appearance.font.pixelSize.smallie
                    color: Appearance.colors.colSubtext
                    rotation: cat.open_ ? 180 : 0
                    Behavior on rotation {
                        animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
                    }
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 8
            Layout.rightMargin: 8
            Layout.bottomMargin: 4
            visible: cat.locked
            text: "Turn on Show adult results, under Content in Settings."
            font.pixelSize: Appearance.font.pixelSize.smallest
            color: Appearance.colors.colSubtext
            wrapMode: Text.WordWrap
        }

        Repeater {
            // Empty while shut: this is what stops 49 rows being built the
            // moment the drawer opens.
            model: cat.open_ ? cat.shownItems : []

            delegate: Rectangle {
                id: srcRow
                required property var modelData
                readonly property bool selected: root.selectedSources.indexOf(srcRow.modelData.id) >= 0

                Layout.fillWidth: true
                Layout.leftMargin: 8
                implicitHeight: 34
                radius: Appearance.rounding.small
                color: srcTap.pressed ? Appearance.colors.colLayer2Active : srcHover.hovered ? Appearance.colors.colLayer2Hover : ColorUtils.transparentize(Appearance.colors.colLayer2Hover, 1)
                Behavior on color {
                    animation: Appearance.animation.stateChange.colorAnimation.createObject(this)
                }

                HoverHandler {
                    id: srcHover
                    cursorShape: Qt.PointingHandCursor
                }
                TapHandler {
                    id: srcTap
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: root.toggleSource(srcRow.modelData.id)
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 10
                    spacing: 10

                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: 18
                        implicitHeight: 18
                        radius: 5
                        color: srcRow.selected ? Appearance.colors.colPrimary : ColorUtils.transparentize(Appearance.colors.colPrimary, 1)
                        border.width: srcRow.selected ? 0 : 2
                        border.color: Appearance.colors.colOutline
                        Behavior on color {
                            animation: Appearance.animation.stateChange.colorAnimation.createObject(this)
                        }
                        MaterialSymbol {
                            anchors.centerIn: parent
                            visible: srcRow.selected
                            text: "check"
                            iconSize: 14
                            color: Appearance.colors.colOnPrimary
                        }
                    }
                    StyledText {
                        Layout.fillWidth: true
                        text: srcRow.modelData.label || srcRow.modelData.id
                        font.pixelSize: Appearance.font.pixelSize.smallie
                        color: Appearance.colors.colOnLayer1
                        elide: Text.ElideRight
                    }
                    StyledText {
                        text: root.compact(srcRow.modelData.items)
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        font.family: Appearance.font.family.monospace
                        color: Appearance.colors.colSubtext
                    }
                }
            }
        }
    }

    // ── the drawer ──────────────────────────────────────────────────────────

    FocusScope {
        anchors.fill: parent
        anchors.margins: 1
        focus: true

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) {
                // Escape backs out one step: the search first, then the drawer.
                if (root.query.length > 0) {
                    root.query = "";
                    searchField.text = "";
                } else {
                    root.close();
                }
                event.accepted = true;
            } else if (event.key === Qt.Key_Slash || (event.key === Qt.Key_F && (event.modifiers & Qt.ControlModifier))) {
                searchField.focusAndSelect();
                event.accepted = true;
            }
        }

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            // Title bar: what this is, how much is on, and the ways out.
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 18
                Layout.rightMargin: 8
                Layout.topMargin: 12
                Layout.bottomMargin: 8
                spacing: 8

                StyledText {
                    text: "Filters"
                    font.pixelSize: Appearance.font.pixelSize.huge
                    font.weight: Font.DemiBold
                    color: Appearance.colors.colOnLayer1
                }

                Rectangle {
                    Layout.alignment: Qt.AlignVCenter
                    visible: root.activeCount > 0
                    implicitWidth: Math.max(22, badge.implicitWidth + 12)
                    implicitHeight: 22
                    radius: 11
                    color: Appearance.colors.colPrimary
                    StyledText {
                        id: badge
                        anchors.centerIn: parent
                        text: root.activeCount
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        font.weight: Font.DemiBold
                        color: Appearance.colors.colOnPrimary
                    }
                }

                Item {
                    Layout.fillWidth: true
                }

                TextButton {
                    text: "Reset"
                    icon: "restart_alt"
                    visible: root.activeCount > 0
                    onClicked: Catalog.query = ""
                }

                IconButton {
                    icon: "close"
                    tooltip: "Close  (Esc)"
                    onClicked: root.close()
                }
            }

            MaterialTextField {
                Layout.fillWidth: true
                Layout.leftMargin: 14
                Layout.rightMargin: 14
                Layout.bottomMargin: 10
                id: searchField
                implicitHeight: 40
                leadingIcon: "search"
                placeholder: "Find a filter or a source"
                onEdited: t => root.query = t
                onCleared: root.query = ""
            }

            // The window's ground under raised cards — same shape as settings.
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: Appearance.colors.colLayer0Base
                bottomLeftRadius: Appearance.rounding.large - 1
                bottomRightRadius: Appearance.rounding.large - 1

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 0

                    // What is on right now, each removable where you read it.
                    Flow {
                        Layout.fillWidth: true
                        Layout.leftMargin: 14
                        Layout.rightMargin: 14
                        Layout.topMargin: 12
                        Layout.bottomMargin: 4
                        spacing: 6
                        visible: root.activeCount > 0 && !root.searching

                        Repeater {
                            model: root.activeChips

                            delegate: Rectangle {
                                id: chip
                                required property string modelData
                                implicitHeight: 28
                                implicitWidth: chipRow.implicitWidth + 20
                                radius: 14
                                color: Appearance.colors.colPrimaryContainer

                                Row {
                                    id: chipRow
                                    anchors.centerIn: parent
                                    spacing: 6

                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: chip.modelData.startsWith("color:")
                                        width: 13
                                        height: 13
                                        radius: 7
                                        color: visible ? chip.modelData.replace("color:", "") : "transparent"
                                        border.width: 1
                                        border.color: Appearance.colors.colOnPrimaryContainer
                                    }
                                    StyledText {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: root.describe(chip.modelData)
                                        font.pixelSize: Appearance.font.pixelSize.smaller
                                        color: Appearance.colors.colOnPrimaryContainer
                                    }
                                    MaterialSymbol {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "close"
                                        iconSize: 15
                                        color: Appearance.colors.colOnPrimaryContainer
                                        MouseArea {
                                            anchors.fill: parent
                                            anchors.margins: -6
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.removeToken(chip.modelData)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Flickable {
                        id: scroller
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        contentWidth: width
                        contentHeight: cards.implicitHeight + 24
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        flickDeceleration: Appearance.scroll.deceleration
                        maximumFlickVelocity: Appearance.scroll.maxVelocity

                        // A card that folds shut otherwise leaves you parked
                        // below the end of the list, looking at nothing.
                        onContentHeightChanged: {
                            if (contentY > contentHeight - height)
                                contentY = Math.max(0, contentHeight - height);
                        }

                        ScrollBar.vertical: StyledScrollBar {}

                        ColumnLayout {
                            id: cards
                            x: 12
                            y: 12
                            width: scroller.width - 24
                            spacing: 8

                            onChildrenChanged: root._bumpGroups()

                            // ── sort ────────────────────────────────────────

                            Group {
                                id: sortGroup
                                gid: "sort"
                                icon: "sort"
                                title: "Sort"
                                terms: "sort order best match newest largest widest a to z shuffle random"
                                readonly property var current: root.tokensFor("sort")
                                active: current.length > 0
                                note: active ? root.describe(current[0]) : "Best match"
                                onCleared: root.setTokens("sort", "")

                                Flow {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    Repeater {
                                        model: [
                                            {
                                                "label": "Best match",
                                                "icon": "auto_awesome",
                                                "token": ""
                                            },
                                            {
                                                "label": "Newest",
                                                "icon": "schedule",
                                                "token": "sort:new"
                                            },
                                            {
                                                "label": "Largest",
                                                "icon": "photo_size_select_large",
                                                "token": "sort:large"
                                            },
                                            {
                                                "label": "Widest",
                                                "icon": "width",
                                                "token": "sort:wide"
                                            },
                                            {
                                                "label": "A to Z",
                                                "icon": "sort_by_alpha",
                                                "token": "sort:title"
                                            },
                                            {
                                                "label": "Shuffle",
                                                "icon": "shuffle",
                                                "token": "sort:random"
                                            }
                                        ]
                                        delegate: Choice {
                                            required property var modelData
                                            label: modelData.label
                                            icon: modelData.icon
                                            selected: modelData.token.length === 0 ? root.tokensFor("sort").length === 0 : root.tokens.indexOf(modelData.token) >= 0
                                            onClicked: root.setTokens("sort", modelData.token)
                                        }
                                    }
                                }
                            }

                            // ── media ───────────────────────────────────────

                            Group {
                                gid: "media"
                                icon: "category"
                                title: "Media"
                                terms: "media family pictures videos vectors 3d models audio"
                                active: Catalog.family.length > 0
                                note: active ? root.familyLabel(Catalog.family) : "Everything"
                                onCleared: Catalog.setFilter("family", "")

                                Flow {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    Repeater {
                                        model: Catalog.facetFamilies
                                        delegate: Choice {
                                            required property var modelData
                                            label: root.familyLabel(modelData.id)
                                            count: root.compact(modelData.items)
                                            selected: Catalog.family === modelData.id
                                            onClicked: Catalog.setFilter("family", selected ? "" : modelData.id)
                                        }
                                    }
                                }
                            }

                            // ── made for ────────────────────────────────────

                            Group {
                                gid: "kinds"
                                icon: "crop_original"
                                title: "Made for"
                                terms: "made for kind slot wallpaper avatar cover emote icon banner"
                                active: Catalog.kind.length > 0
                                note: active ? Catalog.kind.charAt(0).toUpperCase() + Catalog.kind.slice(1) : "Anything"
                                onCleared: Catalog.setFilter("kind", "")

                                StyledText {
                                    Layout.fillWidth: true
                                    text: "The slot each picture was cut for."
                                    font.pixelSize: Appearance.font.pixelSize.smallest
                                    color: Appearance.colors.colSubtext
                                }
                                Flow {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    Repeater {
                                        model: Catalog.facetKinds
                                        delegate: Choice {
                                            required property var modelData
                                            label: modelData.id.charAt(0).toUpperCase() + modelData.id.slice(1)
                                            count: root.compact(modelData.items)
                                            selected: Catalog.kind === modelData.id
                                            onClicked: Catalog.setFilter("kind", selected ? "" : modelData.id)
                                        }
                                    }
                                }
                            }

                            // ── shape ───────────────────────────────────────

                            Group {
                                gid: "shape"
                                icon: "aspect_ratio"
                                title: "Shape"
                                terms: "shape ratio aspect landscape portrait square wide tall"
                                readonly property string ratios: root.tokensFor("ratio").join(" ")
                                active: ratios.length > 0
                                note: active ? root.describe(root.tokensFor("ratio")[0]) : "Any"
                                onCleared: root.setTokens("ratio", "")

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    Repeater {
                                        model: [
                                            {
                                                "label": "Any",
                                                "w": 26,
                                                "h": 20,
                                                "token": ""
                                            },
                                            {
                                                "label": "Landscape",
                                                "w": 30,
                                                "h": 18,
                                                "token": "ratio>1.1"
                                            },
                                            {
                                                "label": "Portrait",
                                                "w": 16,
                                                "h": 26,
                                                "token": "ratio<0.9"
                                            },
                                            {
                                                "label": "Square",
                                                "w": 22,
                                                "h": 22,
                                                "token": "ratio>=0.9 ratio<=1.1"
                                            }
                                        ]
                                        delegate: Rectangle {
                                            id: shape
                                            required property var modelData
                                            readonly property bool selected: root.tokensFor("ratio").join(" ") === modelData.token
                                            Layout.fillWidth: true
                                            implicitHeight: 66
                                            radius: Appearance.rounding.small
                                            color: shape.selected ? Appearance.colors.colSecondaryContainer : shapeMouse.containsMouse ? Appearance.colors.colLayer2Hover : ColorUtils.transparentize(Appearance.colors.colLayer2Hover, 1)
                                            border.width: shape.selected ? 0 : 1
                                            border.color: Appearance.colors.colOutlineVariant
                                            Behavior on color {
                                                animation: Appearance.animation.stateChange.colorAnimation.createObject(shape)
                                            }

                                            Column {
                                                anchors.centerIn: parent
                                                spacing: 7
                                                Item {
                                                    anchors.horizontalCenter: parent.horizontalCenter
                                                    width: 30
                                                    height: 26
                                                    Rectangle {
                                                        anchors.centerIn: parent
                                                        width: shape.modelData.w
                                                        height: shape.modelData.h
                                                        radius: 3
                                                        color: "transparent"
                                                        border.width: 2
                                                        border.color: shape.selected ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                                                        opacity: shape.modelData.token.length === 0 ? 0.5 : 1
                                                    }
                                                }
                                                StyledText {
                                                    anchors.horizontalCenter: parent.horizontalCenter
                                                    text: shape.modelData.label
                                                    font.pixelSize: Appearance.font.pixelSize.smallest
                                                    color: shape.selected ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                                                }
                                            }

                                            MouseArea {
                                                id: shapeMouse
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.setTokens("ratio", shape.modelData.token)
                                            }
                                        }
                                    }
                                }
                            }

                            // ── resolution ──────────────────────────────────

                            Group {
                                gid: "resolution"
                                icon: "hd"
                                title: "Resolution"
                                terms: "resolution size width hd full 1440p 4k 5k pixels"
                                readonly property var ws: root.tokensFor("w")
                                active: ws.length > 0
                                note: active ? root.describe(ws[0]) : "Any"
                                onCleared: root.setTokens("w", "")

                                StyledText {
                                    Layout.fillWidth: true
                                    text: "Width, at least."
                                    font.pixelSize: Appearance.font.pixelSize.smallest
                                    color: Appearance.colors.colSubtext
                                }
                                Flow {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    Repeater {
                                        model: [
                                            {
                                                "label": "Any",
                                                "token": ""
                                            },
                                            {
                                                "label": "HD",
                                                "token": "w>=1280"
                                            },
                                            {
                                                "label": "Full HD",
                                                "token": "w>=1920"
                                            },
                                            {
                                                "label": "1440p",
                                                "token": "w>=2560"
                                            },
                                            {
                                                "label": "4K",
                                                "token": "w>=3840"
                                            },
                                            {
                                                "label": "5K+",
                                                "token": "w>=5120"
                                            }
                                        ]
                                        delegate: Choice {
                                            required property var modelData
                                            label: modelData.label
                                            selected: root.tokensFor("w").join(" ") === modelData.token
                                            onClicked: root.setTokens("w", modelData.token)
                                        }
                                    }
                                }
                            }

                            // ── colour ──────────────────────────────────────

                            Group {
                                id: colourGroup
                                gid: "colour"
                                icon: "palette"
                                title: "Colour"
                                terms: "colour color palette hue tone accent tolerance"
                                readonly property string current: root.tokensFor("color").length > 0 ? root.tokensFor("color")[0].replace("color:", "").toLowerCase() : ""
                                /// The tolerance half of the pair. Defaulted, not
                                /// assumed: a colour with no `dist` matches almost
                                /// nothing, so one is always written with it.
                                readonly property int tolerance: {
                                    const t = root.tokensFor("dist");
                                    if (t.length === 0)
                                        return 25;
                                    const n = parseInt(String(t[0]).replace(/^dist(<=|<|:)/, ""), 10);
                                    return isNaN(n) ? 25 : n;
                                }
                                active: current.length > 0
                                note: active ? current.toUpperCase() : "Any"
                                onCleared: root.removeToken("color:" + current)

                                function pick(hex) {
                                    const kept = root.tokens.filter(t => !t.startsWith("color:") && !/^dist(<|<=|:)/.test(t));
                                    if (colourGroup.current !== hex)
                                        kept.push(`color:${hex}`, `dist<${colourGroup.tolerance}`);
                                    Catalog.query = kept.join(" ");
                                }

                                Grid {
                                    id: swatches
                                    Layout.fillWidth: true
                                    columns: 8
                                    spacing: 7
                                    readonly property real cell: Math.floor((width - spacing * (columns - 1)) / columns)

                                    Repeater {
                                        model: [Appearance.m3colors.primary, "#e53935", "#fb8c00", "#fdd835", "#7cb342", "#00897b", "#039be5", "#3949ab", "#8e24aa", "#d81b60", "#6d4c41", "#f5f5f5", "#9e9e9e", "#212121", "#f8bbd0", "#b2dfdb"]
                                        delegate: Rectangle {
                                            id: swatch
                                            required property var modelData
                                            required property int index
                                            readonly property string hex: String(modelData).toLowerCase().slice(0, 7)
                                            readonly property bool selected: colourGroup.current === swatch.hex
                                            width: swatches.cell
                                            height: 28
                                            radius: 14
                                            color: modelData
                                            border.width: swatch.selected ? 3 : 1
                                            border.color: swatch.selected ? Appearance.colors.colOnLayer1 : Appearance.colors.colOutlineVariant

                                            MaterialSymbol {
                                                anchors.centerIn: parent
                                                visible: swatch.index === 0
                                                text: "palette"
                                                iconSize: 14
                                                color: Appearance.m3colors.onPrimary
                                            }

                                            MouseArea {
                                                id: swatchMouse
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: colourGroup.pick(swatch.hex)
                                            }

                                            StyledToolTip {
                                                visible: swatchMouse.containsMouse
                                                text: swatch.index === 0 ? "Your accent colour" : swatch.hex.toUpperCase()
                                            }
                                        }
                                    }
                                }

                                // The tolerance was a hidden `dist<25` nobody
                                // could reach, which is the difference between
                                // "this blue" and "blue-ish".
                                RowLayout {
                                    Layout.fillWidth: true
                                    visible: colourGroup.active
                                    spacing: 10

                                    StyledText {
                                        text: "How close"
                                        font.pixelSize: Appearance.font.pixelSize.smaller
                                        color: Appearance.colors.colOnLayer1
                                    }
                                    StyledSlider {
                                        Layout.fillWidth: true
                                        from: 5
                                        to: 60
                                        stepSize: 5
                                        value: colourGroup.tolerance
                                        onMoved: root.setTokens("dist", `dist<${Math.round(value)}`)
                                    }
                                    StyledText {
                                        text: colourGroup.tolerance < 15 ? "exact" : colourGroup.tolerance < 35 ? "close" : "loose"
                                        font.pixelSize: Appearance.font.pixelSize.smallest
                                        color: Appearance.colors.colSubtext
                                    }
                                }
                            }

                            // ── motion & content ────────────────────────────

                            Group {
                                gid: "motion"
                                icon: "animation"
                                title: "Motion & content"
                                terms: "motion animated gif loop adult nsfw hide content"
                                readonly property int on_: (root.hasWord("animated") ? 1 : 0) + (root.hasWord("-nsfw") ? 1 : 0)
                                active: on_ > 0
                                note: active ? `${on_} on` : "Off"
                                onCleared: {
                                    root.setWord("animated", false);
                                    root.setWord("-nsfw", false);
                                }

                                Repeater {
                                    model: [
                                        {
                                            "label": "Only animated",
                                            "note": "GIFs and loops, nothing still",
                                            "word": "animated"
                                        },
                                        {
                                            "label": "Hide adult",
                                            "note": "drops mature results from boards that carry both",
                                            "word": "-nsfw"
                                        }
                                    ]
                                    delegate: RowLayout {
                                        required property var modelData
                                        Layout.fillWidth: true
                                        spacing: 12
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 0
                                            StyledText {
                                                Layout.fillWidth: true
                                                text: modelData.label
                                                font.pixelSize: Appearance.font.pixelSize.smallie
                                                color: Appearance.colors.colOnLayer1
                                            }
                                            StyledText {
                                                Layout.fillWidth: true
                                                text: modelData.note
                                                font.pixelSize: Appearance.font.pixelSize.smallest
                                                color: Appearance.colors.colSubtext
                                                wrapMode: Text.WordWrap
                                            }
                                        }
                                        StyledSwitch {
                                            Layout.alignment: Qt.AlignVCenter
                                            checked: root.hasWord(modelData.word)
                                            onToggled: on => root.setWord(modelData.word, on)
                                        }
                                    }
                                }
                            }

                            // ── sources ─────────────────────────────────────

                            Group {
                                gid: "sources"
                                icon: "cloud"
                                title: "Sources"
                                terms: "sources sites boards where from " + root.sourceBlob
                                active: root.selectedSources.length > 0
                                note: root.listedSources === 0 ? "" : (active ? `${root.selectedSources.length} of ${root.listedSources}` : `All ${root.listedSources}`)
                                onCleared: root.setTokens("source", "")

                                MaterialTextField {
                                    id: sourceField
                                    Layout.fillWidth: true
                                    implicitHeight: 36
                                    leadingIcon: "search"
                                    placeholder: "Find a source"
                                    onEdited: t => root.sourceNeedle = t.trim().toLowerCase()
                                    onCleared: root.sourceNeedle = ""
                                }

                                StyledText {
                                    Layout.fillWidth: true
                                    visible: Catalog.facetSources.length === 0
                                    /*
                                     * "Wait for it" was said to people whose
                                     * source list was FAILING, not filling: the
                                     * facet call already records why it came
                                     * back empty, and this was the one place
                                     * with room to say it and did not.
                                     */
                                    text: Catalog.facetError.length > 0 ? `The sources could not be listed — ${Catalog.facetError}` : "No sources have reported yet. They list themselves as the catalogue fills."
                                    font.pixelSize: Appearance.font.pixelSize.smallest
                                    color: Catalog.facetError.length > 0 ? Appearance.colors.colError : Appearance.colors.colSubtext
                                    wrapMode: Text.WordWrap
                                }

                                Repeater {
                                    model: root.isOpen("sources") || root.searching ? root.sourceGroupOrder : []
                                    delegate: SourceCategory {
                                        required property string modelData
                                        category: modelData
                                    }
                                }

                                // Nothing matched the needle inside the card.
                                StyledText {
                                    Layout.fillWidth: true
                                    Layout.topMargin: 4
                                    visible: root.sourceFilter.length > 0 && root.matchingSources === 0
                                    text: `No source called “${root.sourceFilter}”.`
                                    font.pixelSize: Appearance.font.pixelSize.smallest
                                    color: Appearance.colors.colSubtext
                                    wrapMode: Text.WordWrap
                                }
                            }

                            // ── what this site offers ───────────────────────

                            Group {
                                gid: "sections"
                                icon: "category"
                                title: "Sections"
                                terms: {
                                    const words = ["sections", "categories", "channels", "ordering", "sort"];
                                    for (const row of root.sections)
                                        words.push(row.label);
                                    return words.join(" ");
                                }
                                shown: root.sectionSources.length > 0
                                readonly property int on_: root.sectionGroups.reduce((n, g) => n + g.rows.filter(r => root.sectionOn(r)).length, 0)
                                active: on_ > 0
                                note: root.sectionSource.length === 0
                                    ? "Pick a site to see its own"
                                    : (active ? `${on_} on` : root.sectionSource)
                                onCleared: {
                                    let kept = root.tokens;
                                    for (const g of root.sectionGroups)
                                        for (const r of g.rows)
                                            if (root.sectionOn(r)) {
                                                const drop = String(r.q || r.label).split(/\s+/);
                                                kept = kept.filter(t => drop.indexOf(t) < 0);
                                            }
                                    Catalog.query = kept.join(" ");
                                }

                                /*
                                 * No site chosen yet: the sites that HAVE a
                                 * table of contents, so one click gets you
                                 * somewhere rather than an empty card
                                 * explaining itself.
                                 */
                                Flow {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    visible: root.sectionSource.length === 0 && (root.isOpen("sections") || root.searching)

                                    Repeater {
                                        model: root.sectionSources
                                        delegate: Choice {
                                            required property string modelData
                                            label: modelData
                                            icon: "public"
                                            onClicked: Catalog.setFilter("source", modelData)
                                        }
                                    }
                                }

                                Repeater {
                                    model: root.isOpen("sections") || root.searching ? root.sectionGroups : []

                                    delegate: ColumnLayout {
                                        id: sectionGroup

                                        required property var modelData
                                        /*
                                         * A SITE'S WHOLE LIST IS HUNDREDS LONG.
                                         *
                                         * Now that a source can publish its full
                                         * lists (redtube: 909 tags), a group shows
                                         * sixty and a "show all" — and the panel's
                                         * own search narrows the whole list, so any
                                         * one of them is a few letters away.
                                         */
                                        property bool showAll: false
                                        readonly property int cap: 60
                                        readonly property var matching: root.filter.length > 0
                                            ? modelData.rows.filter(r => String(r.label).toLowerCase().indexOf(root.filter) >= 0)
                                            : modelData.rows
                                        readonly property var shown: sectionGroup.showAll || root.filter.length > 0
                                            ? sectionGroup.matching
                                            : sectionGroup.matching.slice(0, sectionGroup.cap)
                                        Layout.fillWidth: true
                                        visible: sectionGroup.matching.length > 0
                                        spacing: 6

                                        StyledText {
                                            text: modelData.group
                                            font.pixelSize: Appearance.font.pixelSize.smallest
                                            font.capitalization: Font.AllUppercase
                                            font.letterSpacing: 0.8
                                            color: Appearance.colors.colSubtext
                                        }
                                        Flow {
                                            Layout.fillWidth: true
                                            spacing: 6
                                            Repeater {
                                                model: sectionGroup.shown
                                                delegate: Choice {
                                                    required property var modelData
                                                    label: modelData.label
                                                    selected: root.sectionOn(modelData)
                                                    onClicked: root.chooseSection(modelData, !selected)
                                                }
                                            }
                                            Choice {
                                                visible: sectionGroup.matching.length > sectionGroup.cap && root.filter.length === 0
                                                label: sectionGroup.showAll ? "Fewer" : `Show all ${sectionGroup.matching.length}`
                                                onClicked: sectionGroup.showAll = !sectionGroup.showAll
                                            }
                                        }
                                    }
                                }
                            }

                            // ── topics ──────────────────────────────────────

                            Group {
                                gid: "topics"
                                icon: "tag"
                                title: "Topics"
                                terms: "topics tags popular suggestions " + (root.suggestedTerms || []).join(" ")
                                shown: Catalog.suggestions.length > 0
                                /// Only the terms this card actually offers. Every
                                /// bare word counted as a topic, so clearing the
                                /// group deleted what you had typed to search for.
                                readonly property int on_: root.tokens.filter(t => (root.suggestedTerms || []).indexOf(t) >= 0).length
                                active: on_ > 0
                                note: active ? `${on_} on` : "What sources suggest"
                                onCleared: Catalog.query = root.tokens.filter(t => (root.suggestedTerms || []).indexOf(t) < 0).join(" ")

                                Repeater {
                                    model: root.isOpen("topics") || root.searching ? Catalog.suggestions.filter(g => g.terms && g.terms.length > 0).slice(0, 8) : []

                                    delegate: ColumnLayout {
                                        required property var modelData
                                        Layout.fillWidth: true
                                        spacing: 6

                                        StyledText {
                                            text: modelData.group || "Popular"
                                            font.pixelSize: Appearance.font.pixelSize.smallest
                                            font.capitalization: Font.AllUppercase
                                            font.letterSpacing: 0.8
                                            color: Appearance.colors.colSubtext
                                        }
                                        Flow {
                                            Layout.fillWidth: true
                                            spacing: 6
                                            Repeater {
                                                model: modelData.terms.slice(0, 14)
                                                delegate: Choice {
                                                    required property string modelData
                                                    label: modelData
                                                    selected: root.hasWord(modelData)
                                                    onClicked: root.setWord(modelData, !selected)
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            // ── nothing matched ─────────────────────────────

                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.topMargin: 30
                                spacing: 6
                                visible: root.searching && root.visibleGroups === 0

                                MaterialSymbol {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: "search_off"
                                    iconSize: 38
                                    color: Appearance.colors.colSubtext
                                }
                                StyledText {
                                    Layout.fillWidth: true
                                    horizontalAlignment: Text.AlignHCenter
                                    text: "No filter or source matches that."
                                    wrapMode: Text.WordWrap
                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                    color: Appearance.colors.colSubtext
                                }
                            }
                        }
                    }

                    Divider {
                        Layout.fillWidth: true
                    }

                    // The consequence of everything above, and the way back.
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.margins: 12
                        spacing: 10

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            StyledText {
                                Layout.fillWidth: true
                                text: Catalog.loading ? "Counting…" : `${Number(Catalog.count).toLocaleString(Qt.locale("en_US"), "f", 0)} results`
                                font.pixelSize: Appearance.font.pixelSize.small
                                font.weight: Font.DemiBold
                                color: Appearance.colors.colOnLayer1
                                elide: Text.ElideRight
                            }
                            StyledText {
                                Layout.fillWidth: true
                                text: root.activeCount === 0 ? "No filters on" : `${root.activeCount} filter${root.activeCount === 1 ? "" : "s"} on`
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                color: Appearance.colors.colSubtext
                            }
                        }

                        TextButton {
                            text: "Show results"
                            icon: "arrow_forward"
                            variant: "filled"
                            onClicked: root.close()
                        }
                    }
                }
            }
        }
    }

    // ── how many cards survived the search ──────────────────────────────────

    property int visibleGroups: 0
    function _countGroups() {
        let n = 0;
        for (let i = 0; i < cards.children.length; i++)
            if (cards.children[i].wanted === true)
                n++;
        root.visibleGroups = n;
    }
    function _bumpGroups() {
        Qt.callLater(root._countGroups);
    }

    /// A card, wired to the panel: it opens from the shared map, matches the
    /// search on its own words, and reports in so the empty state can be right.
    component Group: FilterGroup {
        property string gid: ""
        property string terms: ""
        /// The caller's own reason to hide it, kept apart from the search's.
        property bool shown: true
        matched: shown && (root.matches(title) || root.matches(terms))
        open_: root.isOpen(gid) || root.searching
        onToggled: root.toggleGroup(gid)
        onWantedChanged: root._bumpGroups()
        Component.onCompleted: root._bumpGroups()
    }
}
