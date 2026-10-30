import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.modules.common
import qs.modules.widgets
import qs.services

/*
 * SETTINGS AS A SCREEN: a rail that stays put, a pane that scrolls, and one
 * search field that finds a setting wherever it lives.
 *
 * What it replaces: seven pages of bare rows where a number was a row you
 * clicked to cycle, a choice of three was three switches that could all read
 * "off", the same preference appeared under two names on two pages, and the
 * sources page was thirty-six identical rows in one list with nothing saying
 * which of them had ever given you a picture.
 */
Sheet {
    // ── pages ───────────────────────────────────────────────────────────────
    // ── sources, grouped by what they are ───────────────────────────────────
    // ── how many cards survived the search ──────────────────────────────────
    // ── pieces ──────────────────────────────────────────────────────────────
    // ── the screen ──────────────────────────────────────────────────────────
    //     * WHAT THE DAEMON SAID IS ON THE DISK.
    //     *
    //     * Asked for, never polled: measuring means walking every file in the cache
    //     * folders — 58,778 of them on the machine this was written on — and a
    //     * settings panel that did that on every repaint would be a disk crawler
    //     * with a switch on it. So the panel asks when it opens on this page, and
    //     * again after something is cleared.
    //     * WHICH SOURCES ARE ANSWERING — the validator's report.
    //     *
    //     * A source that starts refusing looks exactly like a source with nothing
    //     * new: an empty wall. The daemon has recorded every fetch since it
    //     * started (see `record_health`) and writes the changes to a log; this is
    //     * where a person can read it without a terminal.

    id: root

    /*
     * Grows with the window instead of stopping at 880. The cap is a reading
     * measure, not the screen's: the cards stop at 760 and sit in the middle,
     * so a sentence never runs the full width of an 1800px window.
     */
    readonly property real _pw: root.parent ? root.parent.width : 900
    readonly property real _ph: root.parent ? root.parent.height : 700
    /// Below this the rail has no room for words and keeps only its icons.
    readonly property bool compact: root.surfaceWidth < 780
    /// How much of a row a slider may take. Narrow, a 190px control pushes the
    /// description into four lines and the row stops being scannable.
    readonly property real sliderWidth: root.compact ? 130 : 190
    /// Which page the rail is showing.
    property string page: "appearance"
    /// What is typed in the field. `filter` is what rows match against, so the
    /// lower-casing happens once rather than forty times per keystroke.
    property string query: ""

    /*
     * OPEN ON ONE SCRIPT, rather than on the list it is somewhere in.
     *
     * The dock's tune button opened the add-ons page and left you to find the
     * script yourself, among a dozen others, each with its own settings now
     * indented underneath. You pressed it ON the thing you wanted to change,
     * so the question "which one?" has already been answered.
     *
     * It fills the search box rather than scrolling to a row: the panel is
     * already a searchable list, searching already hides everything else, and
     * a filled search box SAYS why you are only seeing one script — a scroll
     * position says nothing and is lost the moment you touch the list.
     */
    function showScript(id) {
        const meta = (Scripts.scripts || []).find(s => s.id === id);
        root.page = "addons";
        root.query = meta && meta.name.length > 0 ? meta.name : String(id || "");
        root.open = true;
    }
    readonly property string filter: root.query.trim().toLowerCase()
    readonly property bool searching: root.filter.length > 0
    property var health: []
    property int healthFailing: 0
    property int healthUnknown: 0
    property string healthLog: ""
    property var storageDirs: []
    property var budgets: ({
    })
    property string storageTotal: ""
    property string catalogueSize: "—"
    property string storageWhen: ""
    readonly property var budgetOptions: [{
        "id": "500",
        "label": "500 MB"
    }, {
        "id": "1000",
        "label": "1 GB"
    }, {
        "id": "3000",
        "label": "3 GB"
    }, {
        "id": "10000",
        "label": "10 GB"
    }, {
        "id": "0",
        "label": "No limit"
    }]
    /*
     * ONE PAGE, ONE QUESTION.
     *
     * The order is how often you reach for it, and each page answers exactly
     * one thing: how does it look, how does video behave, what am I willing to
     * see, where do pictures come from, what extends quarry, what do I have,
     * what is on my disk, is it working.
     *
     * Three faults this replaces, all of them structural rather than cosmetic:
     *
     *   - `scripts` had three groups and NO nav entry. Eleven scripts with
     *     toggles were reachable only by typing in the search box, which is
     *     the search box doing the structure's job.
     *   - Extensions and scripts are one idea to anybody using them — things
     *     that add behaviour — and were two places, one of them invisible.
     *     They are "Add-ons" now, and the page is full rather than thin.
     *   - Storage held the catalogue, hidden pictures and history. Those are
     *     your library, not your disk: one is what you HAVE, the other is what
     *     it COSTS, and they are answered on different days.
     */
    readonly property var pages: [{
        "id": "appearance",
        "icon": "palette",
        "label": "Appearance",
        "about": "How the gallery and the window look, and how much they move."
    }, {
        "id": "content",
        "icon": "visibility",
        "label": "Content",
        "about": "What you are willing to see."
    }, {
        "id": "video",
        "icon": "movie",
        "label": "Video",
        "about": "Playback in the viewer, in the wall and on your wallpaper."
    }, {
        "id": "sources",
        "icon": "cloud",
        "label": "Sources",
        "about": "Where pictures come from, and how they are mixed together."
    }, {
        "id": "addons",
        "icon": "extension",
        "label": "Add-ons",
        "about": "Scripts and extensions — everything that adds behaviour."
    }, {
        "id": "library",
        "icon": "photo_library",
        "label": "Library",
        "about": "The catalogue you have built, and what you have hidden."
    }, {
        "id": "storage",
        "icon": "database",
        "label": "Storage",
        "about": "What it costs on disk, and the limits you keep it inside."
    }, {
        "id": "about",
        "icon": "info",
        "label": "About",
        "about": "The daemon, the connection and the performance readout."
    }]
    /*
     * Names that used to be pages. A page id is an address — the overflow
     * menu, the script dock and `app settings <page>` all name one — so a
     * retired id redirects instead of showing a blank panel.
     */
    readonly property var pageAliases: ({
        "scripts": "addons",
        "extensions": "addons"
    })
    readonly property var currentPage: root.pages.find((p) => {
        return p.id === root.page;
    }) || root.pages[0]
    /*
     * EVERY CATEGORY A MANIFEST CAN DECLARE, IN READING ORDER.
     *
     * A category missing from this list does not get a heading — it falls into
     * "Everything else" (see `idsByCategory`), which is how six 3D sources and
     * an audio one ended up in an unlabelled bucket at the bottom of the page
     * while declaring a perfectly good category in their own manifests. The
     * list and the manifests have to agree, so the test below asserts they do.
     */
    readonly property var categoryOrder: ["wallpapers", "photography", "art", "3d", "games", "icons", "video", "audio", "adult", "local"]
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
        "3d": {
            "label": "3D and materials",
            "icon": "view_in_ar"
        },
        "games": {
            "label": "Game assets",
            "icon": "sports_esports"
        },
        "icons": {
            "label": "Icons and vectors",
            "icon": "shapes"
        },
        "video": {
            "label": "Video",
            "icon": "movie"
        },
        "audio": {
            "label": "Sound",
            "icon": "graphic_eq"
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
    /*
     * The flat order, assigned rather than bound. A Repeater fed a new JS array
     * rebuilds every delegate, so bound to `Catalog.sourcePrefs` each toggle
     * destroyed the switch you had just pressed. Kept because the IPC probe
     * reports it.
     */
    property var sourceOrder: []
    /// Category -> its ids. Unknown categories collapse into one "other" group
    /// rather than each becoming a card holding a single row.
    readonly property var idsByCategory: {
        const out = {
        };
        for (let i = 0; i < root.sourceOrder.length; i++) {
            const id = root.sourceOrder[i];
            const raw = (Catalog.sourcePrefMap[id] || {
            }).category || "";
            const cat = root.categoryOrder.indexOf(raw) >= 0 ? raw : "other";
            if (!out[cat])
                out[cat] = [];

            out[cat].push(id);
        }
        return out;
    }
    readonly property var groupOrder: root.categoryOrder.concat(["other"]).filter((c) => {
        return (root.idsByCategory[c] || []).length > 0;
    })
    /// id -> rows held, built once: a find() inside every delegate binding is
    /// 1300 comparisons on each refresh.
    readonly property var rowsById: {
        const out = {
        };
        for (let i = 0; i < Catalog.facetSources.length; i++) {
            const f = Catalog.facetSources[i];
            out[f.id] = f.items || 0;
        }
        return out;
    }
    readonly property int maxSourceRows: {
        let m = 0;
        for (const k in root.rowsById) m = Math.max(m, root.rowsById[k])
        return m;
    }
    readonly property int enabledSources: Catalog.sourcePrefs.filter((s) => {
        return s.enabled === true;
    }).length
    property Connections _prefsWatch
    property int visibleGroups: 0

    /// The shell owns these: opening a folder and crawling live sources are its
    /// jobs, not a settings panel's.
    signal cacheRequested()
    signal searchRequested()

    function checkSources() {
        if (!Client.connected)
            return ;

        Client.call("health", {
        }, function(err, payload) {
            if (err || !payload) {
                Toast.error(`Could not read the source report — ${err || "no answer"}`);
                return ;
            }
            /*
             * FAILING ONLY.
             *
             * Listing everything not yet asked meant seventy-one rows saying
             * "never asked" on a daemon that had just started — a fault light
             * that is always on is not a fault light. How many are untested
             * is a number, and it goes on the button.
             */
            const rows = payload.sources || [];
            root.health = rows.filter((row) => {
                return row.state === "failing";
            });
            root.healthUnknown = rows.filter((row) => {
                return row.state === "unknown";
            }).length;
            root.healthFailing = payload.failing || 0;
            root.healthLog = payload.log || "";
        });
    }

    /// The button: ask every source, now. Minutes, not seconds — sixty sites
    /// at one request each — so it says so before it starts.
    function probeSources() {
        Toast.show("Asking every source… this takes a minute");
        Client.call("doctor", {
        }, function(err) {
            if (err) {
                Toast.error(`The probe failed — ${err}`);
                return ;
            }
            root.checkSources();
            Toast.show(root.healthFailing > 0 ? `${root.healthFailing} sources are not answering` : "Every source answered");
        }, 300000);
    }

    /// Bytes as something a person reads, not a number with nine digits.
    function bytesLabel(bytes) {
        const n = Number(bytes || 0);
        if (n >= 1.07374e+09)
            return `${(n / 1073741824).toFixed(n >= 10737418240 ? 0 : 1)} GB`;

        if (n >= 1.04858e+06)
            return `${Math.round(n / 1048576)} MB`;

        if (n >= 1024)
            return `${Math.round(n / 1024)} kB`;

        return `${n} B`;
    }

    function measureStorage() {
        if (!Client.connected)
            return ;

        Client.call("storage", {
        }, function(err, payload) {
            if (err || !payload) {
                Toast.error(`Could not read the storage — ${err || "no answer"}`);
                return ;
            }
            root.storageDirs = payload.dirs || [];
            root.budgets = payload.budgets || ({
            });
            root.storageTotal = root.bytesLabel((payload.cacheBytes || 0) + (payload.catalogueBytes || 0));
            root.catalogueSize = root.bytesLabel(payload.catalogueBytes || 0);
            root.storageWhen = Qt.formatTime(new Date(), "HH:mm");
        });
    }

    /*
     * THE ONE THING THAT IS NOT A COPY.
     *
     * Every other row on this page deletes something browsing rebuilds. This
     * deletes 317,000 rows that took days of crawling to gather, so it asks
     * twice: the first press arms it, the second does it, and `armed` falls
     * back on its own after a few seconds. No modal — a dialog for this would
     * be one more thing to click through, and a row that visibly changes into
     * "Press again to empty it" says the same thing where the eye already is.
     */
    property bool catalogueArmed: false
    property bool adultPurgeArmed: false
    /// What the delete picker is aimed at: "" is adult, otherwise a source id.
    property string purgeTarget: ""
    /// [{ source, count, adult }] from the daemon, adult rows COUNTED not hidden.
    property var storedSources: []
    property int storedAdult: 0
    property int purgeRows: 0
    property real purgeBytes: 0

    /// The query the picker's choice means. One place, so the count shown and
    /// the rows deleted can never be computed from two different strings.
    function purgeQuery() {
        return root.purgeTarget.length === 0 ? "nsfw:true" : `source:${root.purgeTarget}`;
    }

    /// What is on the disk, per source. Asked for when the panel opens and
    /// again after a delete, so the numbers beside the button are not stale.
    function measureStored() {
        Client.call("stored", {}, function(err, payload) {
            if (err || !payload)
                return ;

            root.storedSources = payload.sources || [];
            root.storedAdult = payload.adult || 0;
            root.measurePurge();
        });
    }

    /// How much the current choice would remove. A dry run through the SAME
    /// match the delete uses, so the two cannot drift apart.
    function measurePurge() {
        Client.call("purge", {
            "q": root.purgeQuery(),
            "dryRun": true
        }, function(err, payload) {
            if (err || !payload) {
                root.purgeRows = 0;
                root.purgeBytes = 0;
                return ;
            }
            root.purgeRows = payload.rows || 0;
            root.purgeBytes = payload.bytes || 0;
        });
    }


    /*
     * DELETE THE ADULT ROWS, RATHER THAN HIDING THEM.
     *
     * "Show adult results" is a filter: the rows stay on the disk and come back
     * whole when it goes back on, which is the right behaviour for a switch and
     * the wrong answer to "I do not want this on my machine". This is the other
     * request, and it is a BUTTON rather than a consequence of the switch —
     * flipping a toggle should never quietly delete four fifths of a catalogue.
     *
     * Armed then confirmed, like `emptyCatalogue`, and disarmed by walking away.
     *
     * The daemon takes a QUERY, not a flag (PROTOCOL.md `purge`), so this row
     * sends `nsfw:true` and the same verb serves "delete everything from this
     * source" if that is ever wanted.
     */
    function purgeAdult() {
        if (!root.adultPurgeArmed) {
            root.adultPurgeArmed = true;
            disarmAdult.restart();
            return ;
        }
        root.adultPurgeArmed = false;
        disarmAdult.stop();
        Client.call("purge", {
            "q": root.purgeQuery()
        }, function(err, payload) {
            if (err) {
                Toast.error(`Could not delete them — ${err}`);
                return ;
            }
            const rows = (payload && payload.rows) || 0;
            const freed = (payload && payload.bytes) || 0;
            if (rows === 0) {
                Toast.show("Nothing stored to delete");
                return ;
            }
            const what = root.purgeTarget.length === 0 ? "adult items" : root.purgeTarget;
            Toast.show(`Deleted ${rows.toLocaleString(Qt.locale(), "f", 0)} — ${what}, ${root.bytesLabel(freed)} free`);
            root.measureStorage();
            root.measureStored();
            // The result on screen names rows that no longer exist; the daemon
            // has already retired its queryId, so this is the re-ask.
            Catalog.load();
            Catalog.filterNow();
        });
    }


    function emptyCatalogue() {
        if (!root.catalogueArmed) {
            root.catalogueArmed = true;
            disarm.restart();
            return ;
        }
        root.catalogueArmed = false;
        disarm.stop();
        Client.call("catalogue_clear", {
            "confirm": true
        }, function(err, payload) {
            if (err) {
                Toast.error(`Could not empty the catalogue — ${err}`);
                return ;
            }
            const rows = (payload && payload.removed) || 0;
            Toast.show(`Catalogue emptied — ${rows.toLocaleString(Qt.locale(), "f", 0)} rows, ${root.bytesLabel((payload && payload.bytesFreed) || 0)} free`);
            root.measureStorage();
            // The same pair the overflow's "Reload the catalogue" runs: the
            // result on screen names rows that no longer exist.
            Catalog.load();
            Catalog.filterNow();
        });
    }

    function clearCache(what, label) {
        Client.call("cache_clear", {
            "what": what
        }, function(err, payload) {
            if (err) {
                Toast.error(`Could not clear ${label} — ${err}`);
                return ;
            }
            const freed = root.bytesLabel((payload && payload.bytesFreed) || 0);
            Toast.show(`${label}: ${(payload && payload.removed) || 0} files gone, ${freed} free`);
            root.measureStorage();
        });
    }

    /// A limit the daemon keeps AND acts on now — see `set_budget`, which
    /// trims immediately rather than waiting for the next hourly sweep.
    // Armed is a moment, not a mode: walk away and it is off again.
    Timer {
        id: disarm

        interval: 6000
        onTriggered: root.catalogueArmed = false
    }

    Timer {
        id: disarmAdult

        interval: 4000
        onTriggered: root.adultPurgeArmed = false
    }

    function setBudget(key, mb) {
        const params = {
        };
        params[key] = mb;
        Client.call("set_budget", params, function(err, payload) {
            if (err) {
                Toast.error(`Could not set the limit — ${err}`);
                return ;
            }
            const freed = (payload && payload.bytesFreed) || 0;
            if (freed > 0)
                Toast.show(`Trimmed ${root.bytesLabel(freed)}`);

            root.measureStorage();
        });
    }

    function pageLabel(id) {
        const p = root.pages.find((x) => {
            return x.id === id;
        });
        return p ? p.label : id;
    }

    function show() {
        root.open = true;
    }

    function _rebuildOrder() {
        const list = Catalog.sourcePrefs.slice();
        list.sort(function(a, b) {
            const ai = root.categoryOrder.indexOf(a.category);
            const bi = root.categoryOrder.indexOf(b.category);
            // Unknown sorts last: a new adapter whose category I forgot to set
            // should not open the list.
            const av = ai < 0 ? 99 : ai;
            const bv = bi < 0 ? 99 : bi;
            if (av !== bv)
                return av - bv;

            return a.id.localeCompare(b.id);
        });
        const ids = list.map((s) => {
            return s.id;
        });
        // Compared as JSON so no separator has to be a character no id uses.
        if (JSON.stringify(ids) === JSON.stringify(root.sourceOrder))
            return ;

        root.sourceOrder = ids;
    }

    function _countGroups() {
        let n = 0;
        for (let i = 0; i < pageColumn.children.length; i++) if (pageColumn.children[i].wanted === true) {
            n++;
        }
        root.visibleGroups = n;
    }

    function _bumpGroups() {
        Qt.callLater(root._countGroups);
    }

    /*
     * A DRAWER ON THE RIGHT, like the filter panel.
     *
     * Settings opened as a slab in the middle of the window, which hides the
     * thing every one of these switches changes. The filter panel solved this
     * already: it rides the gallery card's own right edge, same top, same
     * bottom, same corner radius, so it reads as part of the window rather
     * than as something dropped on top of it. Settings is the same kind of
     * thing — a surface you change something on while watching the wall — so
     * it is placed the same way, and the geometry below is FilterPanel's.
     *
     * Wider than the filter drawer, because this one has a nav rail beside its
     * content and `compact` below 780 already handles the narrow case.
     */
    readonly property Item galleryCard: Shell.gallery ? Shell.gallery.parent : null

    /// The card's rect in this item's coordinates. Width/height/x/y are read so
    /// the binding re-runs on a resize — `mapToItem` registers no dependency.
    readonly property rect cardRect: {
        const rw = root.width, rh = root.height;
        const c = root.galleryCard;
        if (!c || !(c.width > 0) || !(c.height > 0))
            return Qt.rect(2, 74, Math.max(0, rw - 14), Math.max(0, rh - 86));
        const w = c.width, h = c.height, cx = c.x, cy = c.y;
        const at = c.mapToItem(root, 0, 0);
        return Qt.rect(at.x, at.y, w, h);
    }

    placement: "topRight"
    topInset: root.cardRect.y
    inset: Math.max(0, root.width - (root.cardRect.x + root.cardRect.width))

    surfaceWidth: Math.round(Math.min(680, Math.max(320, Math.min(root.cardRect.width - 16, root.cardRect.width * 0.78))))
    surfaceHeight: Math.max(320, root.cardRect.height)
    // An unknown page is an empty panel with nothing saying why; land on the
    // first real one instead.
    onPageChanged: {
        // A retired name is an address somebody still holds — redirect it
        // before the unknown-page fallback below throws it away.
        const alias = root.pageAliases[root.page];
        if (alias !== undefined) {
            root.page = alias;
            return ;
        }
        if (!root.pages.some((p) => {
            return p.id === root.page;
        }))
            root.page = root.pages[0].id;

        // Measured when you arrive on the page that shows it, and never
        // otherwise — see `measureStorage`.
        if (root.page === "storage")
            root.measureStorage();

        if (root.page === "sources")
            root.checkSources();

    }
    Component.onCompleted: {
        root._rebuildOrder();
        // Connecting is what normally triggers the fetch, so a panel built
        // after that moment would list nothing until it was opened twice.
        if (Client.connected && Catalog.sourcePrefs.length === 0)
            Catalog.refreshSourcePrefs();

    }
    /*
     * Ask for the preferences on every open. Catalog fetches them at startup,
     * but a settings page that lists nothing looks broken in a way an
     * out-of-date list never does, and it is one cheap call.
     */
    onOpenChanged: {
        if (!root.open)
            return ;

        Catalog.refreshSourcePrefs();
        // The delete picker's counts, for the same reason: a stale "606,452"
        // beside a delete button is worse than no number at all.
        root.measureStored();
        // A search left over from last time would hide most of the screen with
        // nothing on it saying why.
        root.query = "";
        searchField.text = "";
    }

    FocusScope {
        anchors.fill: parent
        // Inside the surface's 1px border, so the pane's rounding lines up with
        // it rather than sitting on top of it.
        anchors.margins: 1
        focus: true
        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Escape) {
                // Escape backs out one step at a time. Closing on the first
                // press throws away what you typed to find the row.
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
            } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
                const at = root.pages.findIndex((p) => {
                    return p.id === root.page;
                });
                const next = event.key === Qt.Key_Down ? at + 1 : at - 1;
                if (next >= 0 && next < root.pages.length)
                    root.page = root.pages[next].id;

                event.accepted = true;
            }
        }

        RowLayout {
            // ── the rail ────────────────────────────────────────────────────
            // ── the pane ────────────────────────────────────────────────────

            anchors.fill: parent
            spacing: 0

            ColumnLayout {
                // A layout inside a layout fills by default, so the width has to
                // be pinned or the rail takes half the panel.
                Layout.fillWidth: false
                Layout.preferredWidth: root.compact ? 68 : 208
                Layout.maximumWidth: root.compact ? 68 : 208
                Layout.fillHeight: true
                Layout.leftMargin: 8
                Layout.rightMargin: 8
                Layout.topMargin: 12
                Layout.bottomMargin: 10
                spacing: 2

                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: root.compact ? 0 : 10
                    Layout.bottomMargin: 10
                    spacing: 10

                    MaterialSymbol {
                        Layout.alignment: Qt.AlignVCenter
                        Layout.leftMargin: root.compact ? 15 : 0
                        text: "tune"
                        iconSize: 22
                        color: Appearance.colors.colOnLayer1
                    }

                    StyledText {
                        Layout.fillWidth: true
                        visible: !root.compact
                        text: "Settings"
                        font.pixelSize: Appearance.font.pixelSize.larger
                        font.weight: Font.DemiBold
                        color: Appearance.colors.colOnLayer1
                    }

                }

                // Scrolls on its own: at 420px of window there is no room for
                // seven destinations, and a rail you cannot reach the end of
                // hides whole pages.
                Flickable {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    contentWidth: width
                    contentHeight: railColumn.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    flickDeceleration: Appearance.scroll.deceleration
                    maximumFlickVelocity: Appearance.scroll.maxVelocity

                    ColumnLayout {
                        id: railColumn

                        width: parent.width
                        spacing: 2

                        Repeater {
                            model: root.pages

                            delegate: NavRailItem {
                                required property var modelData

                                Layout.fillWidth: true
                                expanded: !root.compact
                                icon: modelData.icon
                                label: modelData.label
                                active: root.page === modelData.id && !root.searching
                                // A search shows every page at once, so picking
                                // one has to end the search or nothing appears
                                // to happen.
                                onTriggered: {
                                    root.query = "";
                                    searchField.text = "";
                                    root.page = modelData.id;
                                }
                            }

                        }

                    }

                }

                // The one fact worth a permanent corner: nothing else on this
                // screen means anything while the daemon is down.
                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: root.compact ? 0 : 12
                    Layout.topMargin: 8
                    spacing: 8

                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
                        Layout.leftMargin: root.compact ? 24 : 0
                        implicitWidth: 8
                        implicitHeight: 8
                        radius: 4
                        color: Client.connected ? Appearance.colors.colSuccess : Appearance.colors.colError

                        HoverHandler {
                            id: dotHover
                        }

                        StyledToolTip {
                            visible: root.compact && dotHover.hovered
                            text: Client.connected ? "quarryd connected" : "quarryd not running"
                        }

                    }

                    StyledText {
                        Layout.fillWidth: true
                        visible: !root.compact
                        text: Client.connected ? "quarryd connected" : "quarryd not running"
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: Appearance.colors.colSubtext
                        elide: Text.ElideRight
                    }

                }

                Behavior on Layout.preferredWidth {
                    animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(root)
                }

            }

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                // The window's own ground under raised cards. A pane the same
                // tone as its cards has no cards in it.
                color: Appearance.colors.colLayer0Base
                topRightRadius: Appearance.rounding.large - 1
                bottomRightRadius: Appearance.rounding.large - 1

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 0

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: 22
                        Layout.rightMargin: 10
                        Layout.topMargin: 14
                        Layout.bottomMargin: 12
                        spacing: 10

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1

                            StyledText {
                                Layout.fillWidth: true
                                text: root.searching ? "Search" : root.currentPage.label
                                font.pixelSize: Appearance.font.pixelSize.huge
                                font.weight: Font.DemiBold
                                color: Appearance.colors.colOnLayer1
                                elide: Text.ElideRight
                            }

                            StyledText {
                                Layout.fillWidth: true
                                text: root.searching ? (root.visibleGroups > 0 ? "Matches from every page." : "") : root.currentPage.about
                                visible: text.length > 0
                                wrapMode: Text.WordWrap
                                font.pixelSize: Appearance.font.pixelSize.smallie
                                color: Appearance.colors.colSubtext
                            }

                        }

                        MaterialTextField {
                            id: searchField

                            Layout.alignment: Qt.AlignVCenter
                            Layout.preferredWidth: root.compact ? 156 : 236
                            implicitHeight: 40
                            leadingIcon: "search"
                            placeholder: root.compact ? "Search" : "Search settings"
                            onEdited: (t) => {
                                return root.query = t;
                            }
                            onCleared: root.query = ""

                            Behavior on Layout.preferredWidth {
                                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(root)
                            }

                        }

                        // Escape and a click on the scrim already close it; this
                        // is for the pointer that is already up here.
                        IconButton {
                            Layout.alignment: Qt.AlignVCenter
                            icon: "close"
                            tooltip: "Close  (Esc)"
                            onClicked: root.close()
                        }

                    }

                    Divider {
                        Layout.fillWidth: true
                    }

                    Flickable {
                        id: scroll

                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        contentWidth: width
                        contentHeight: pageColumn.implicitHeight + 28
                        boundsBehavior: Flickable.StopAtBounds
                        flickDeceleration: Appearance.scroll.deceleration
                        maximumFlickVelocity: Appearance.scroll.maxVelocity
                        // Switching from a long page to a short one otherwise
                        // leaves you halfway down it, looking at a page with no
                        // heading on screen.
                        onContentHeightChanged: {
                            if (contentY > contentHeight - height)
                                contentY = Math.max(0, contentHeight - height);

                        }

                        ColumnLayout {
                            // ── appearance ──────────────────────────────────
                            // ── content ─────────────────────────────────────
                            // ── video ───────────────────────────────────────
                            // ── sources ─────────────────────────────────────
                            // ── extensions ──────────────────────────────────
                            // ── storage ─────────────────────────────────────
                            // ── about ───────────────────────────────────────
                            // ── nothing matched ─────────────────────────────

                            id: pageColumn

                            // Capped and centred: a footer running the full
                            // width of an 1800px window is unreadable, and the
                            // cards would be 900px of mostly empty row.
                            width: Math.min(760, scroll.width - 36)
                            x: Math.max(18, (scroll.width - width) / 2)
                            y: 14
                            spacing: 14
                            onChildrenChanged: root._bumpGroups()

                            Group {
                                page: "appearance"
                                title: "Gallery"
                                footer: "Tile size applies to the grid layouts; the wall fits its columns to the window."

                                Setting {
                                    icon: "grid_view"
                                    label: "Tile size"
                                    description: "How large pictures are before you open one. Smaller means more on screen and less to decode."
                                    terms: "thumbnail size zoom bigger smaller grid"
                                    value: Prefs.gridTileSize + "px"
                                    controlWidth: root.sliderWidth

                                    StyledSlider {
                                        Layout.fillWidth: true
                                        from: 100
                                        to: 420
                                        stepSize: 20
                                        value: Prefs.gridTileSize
                                        onMoved: Prefs.gridTileSize = Math.round(value)
                                    }

                                }

                                Setting {
                                    icon: "rounded_corner"
                                    label: "Rounded corners"
                                    description: "How round every picture's corners are. Zero is square."
                                    terms: "radius corner rounding square"
                                    value: Math.round(Prefs.tileRadius) + "px"
                                    controlWidth: root.sliderWidth

                                    StyledSlider {
                                        Layout.fillWidth: true
                                        from: 0
                                        to: 24
                                        stepSize: 2
                                        value: Prefs.tileRadius
                                        onMoved: Prefs.tileRadius = Math.round(value)
                                    }

                                }

                                Setting {
                                    icon: "crop_free"
                                    label: "Keep overlays inside pictures"
                                    description: "Badges and previews stop at each picture's edge. Off is slightly faster and lets them spill."
                                    terms: "clip overlap badges"
                                    hasSwitch: true
                                    checked: Prefs.tileClip
                                    onToggled: (on) => {
                                        return Prefs.tileClip = on;
                                    }
                                }

                                Setting {
                                    icon: "blur_on"
                                    label: "Smooth scaling"
                                    description: "Softer edges when a small thumbnail is shown large, at a little cost in speed."
                                    terms: "smoothing antialias quality sharp"
                                    hasSwitch: true
                                    checked: Prefs.tileSmoothing
                                    onToggled: (on) => {
                                        return Prefs.tileSmoothing = on;
                                    }
                                }

                            }

                            Group {
                                page: "appearance"
                                title: "Window"
                                footer: "Transparency and animation speed apply immediately, everywhere in the app."

                                Setting {
                                    icon: "opacity"
                                    label: "Background transparency"
                                    description: "Lets the desktop through behind the gallery. The pictures themselves stay solid."
                                    terms: "opacity translucent see through blur"
                                    value: Math.round(Prefs.transparency * 100) + "%"
                                    controlWidth: root.sliderWidth

                                    StyledSlider {
                                        Layout.fillWidth: true
                                        from: 0
                                        to: 0.8
                                        stepSize: 0.05
                                        value: Prefs.transparency
                                        onMoved: Prefs.transparency = value
                                    }

                                }

                                Choice {
                                    icon: "animation"
                                    label: "Animation speed"
                                    description: "Off removes every transition, which is the fastest the app gets and the least forgiving to watch."
                                    terms: "motion animations speed instant reduce"
                                    options: [{
                                        "id": "0",
                                        "label": "Off"
                                    }, {
                                        "id": "0.6",
                                        "label": "Snappy"
                                    }, {
                                        "id": "1",
                                        "label": "Normal"
                                    }, {
                                        "id": "1.5",
                                        "label": "Relaxed"
                                    }]
                                    // Matched by range: the stored value is a
                                    // real, and 0.6 is never exactly 0.6.
                                    current: {
                                        const v = Prefs.animationSpeed;
                                        if (v < 0.05)
                                            return "0";

                                        if (v < 0.8)
                                            return "0.6";

                                        if (v < 1.25)
                                            return "1";

                                        return "1.5";
                                    }
                                    onPicked: (id) => {
                                        return Prefs.animationSpeed = parseFloat(id);
                                    }
                                }

                                Setting {
                                    icon: "left_panel_open"
                                    label: "Names in the navigation rail"
                                    description: "Off narrows the rail to icons and moves each name into a tooltip."
                                    terms: "sidebar rail expanded icons labels"
                                    hasSwitch: true
                                    checked: Prefs.railExpanded
                                    onToggled: (on) => {
                                        return Prefs.railExpanded = on;
                                    }
                                }

                            }

                            Group {
                                page: "content"
                                title: "Mature content"
                                footer: "Adult results are a query token like any other: turning this on removes -nsfw from the search bar, so a single search can still exclude them."

                                Setting {
                                    icon: "no_adult_content"
                                    label: "Show adult results"
                                    description: "Includes pictures sources mark as mature, and unlocks the adult sources on the Sources page."
                                    terms: "nsfw adult explicit mature"
                                    hasSwitch: true
                                    checked: Prefs.showNsfw
                                    // Switching them on is asking to see them. The
                                    // daemon is what enforces it — see Catalog.setAdult.
                                    onToggled: (on) => {
                                        return Catalog.setAdult(on);
                                    }
                                }

                                Setting {
                                    icon: "blur_circular"
                                    label: "Blur them until hovered"
                                    description: "Mature pictures stay blurred until the pointer is over them, so a wall is safe to leave open."
                                    terms: "nsfw blur censor hide"
                                    available: Prefs.showNsfw
                                    unavailableNote: "adult results are off"
                                    hasSwitch: true
                                    checked: Prefs.blurNsfw
                                    onToggled: (on) => {
                                        return Prefs.blurNsfw = on;
                                    }
                                }

                                /*
                                 * Hiding is not deleting, and the switch above
                                 * only hides. This row is the other promise: the
                                 * rows leave the catalogue and their pictures
                                 * leave the disk.
                                 */
                                /*
                                 * WHAT TO DELETE, CHOSEN RATHER THAN TYPED.
                                 *
                                 * The daemon's `purge` takes a query, which is
                                 * right for the wire and wrong for a settings
                                 * panel — nobody should have to know the DSL to
                                 * clear their disk. So: adult, or any one
                                 * source, with what it would remove beside it.
                                 */
                                Choice {
                                    icon: "filter_alt"
                                    label: "What to delete"
                                    description: "Adult content, or everything from one source."
                                    terms: "nsfw adult delete remove purge source filter stored disk"
                                    current: root.purgeTarget
                                    options: {
                                        const out = [{
                                            "id": "",
                                            "label": `Adult content · ${root.storedAdult.toLocaleString(Qt.locale(), "f", 0)}`,
                                            "icon": "no_adult_content"
                                        }];
                                        const rows = root.storedSources || [];
                                        for (let i = 0; i < rows.length; i++) {
                                            out.push({
                                                "id": String(rows[i].source),
                                                "label": `${rows[i].source} · ${Number(rows[i].count).toLocaleString(Qt.locale(), "f", 0)}`,
                                                "icon": "folder"
                                            });
                                        }
                                        return out;
                                    }
                                    onPicked: (id) => {
                                        root.purgeTarget = id;
                                        // Disarm: the confirmation was for the
                                        // PREVIOUS choice, and carrying it over
                                        // means one more press deletes something
                                        // the user never confirmed.
                                        root.adultPurgeArmed = false;
                                        disarmAdult.stop();
                                        root.measurePurge();
                                    }
                                }

                                /*
                                 * Hiding is not deleting, and the switch above
                                 * only hides. This row is the other promise: the
                                 * rows leave the catalogue and their pictures
                                 * leave the disk.
                                 */
                                Setting {
                                    icon: root.adultPurgeArmed ? "warning" : "delete_forever"
                                    label: root.adultPurgeArmed ? "Press again to delete them" : "Delete it from this machine"
                                    description: root.adultPurgeArmed ? "The rows and every picture cached for them are removed. Only a fresh crawl brings them back." : "Removes the rows and their cached pictures, rather than only hiding them."
                                    terms: "nsfw adult delete remove purge erase wipe disk local stored"
                                    value: root.adultPurgeArmed ? "sure?" : (root.purgeRows > 0 ? `${root.purgeRows.toLocaleString(Qt.locale(), "f", 0)} · ${root.bytesLabel(root.purgeBytes)}` : "nothing")
                                    destructive: true
                                    available: Client.connected && root.purgeRows > 0
                                    unavailableNote: Client.connected ? "nothing stored to delete" : "needs the daemon"
                                    onClicked: root.purgeAdult()
                                }

                            }

                            Group {
                                page: "appearance"
                                title: "Motion"
                                footer: "One setting for all of it: the wall, the grid and the compare view."

                                /*
                                 * ONE ROW, not two. This was "Play animations on
                                 * hover" under Content and "Play on hover in the
                                 * wall" under Video — the same preference with
                                 * two names, so turning one off turned the other
                                 * off and looked like a bug.
                                 */
                                Setting {
                                    icon: "gif_box"
                                    label: "Animate on hover"
                                    description: "GIFs and videos preview silently under the pointer. Off, they stay on their first frame until opened."
                                    terms: "gif video preview hover play wall animation"
                                    hasSwitch: true
                                    checked: Prefs.animateOnHover
                                    onToggled: (on) => {
                                        return Prefs.animateOnHover = on;
                                    }
                                }

                                /*
                                 * The other way to play: by looking rather than
                                 * by pointing. Separate from hover because they
                                 * answer different questions — one is "what is
                                 * under my cursor", the other "what is on my
                                 * screen" — and because this one has a cost that
                                 * hover does not. See PlayGate.
                                 */
                                Setting {
                                    icon: "smart_display"
                                    label: "Play videos as they come into view"
                                    description: "Videos start as you scroll past them, without hovering, and stop as they leave. Below: every one in view, or only the few nearest the middle."
                                    terms: "autoplay play video view scroll automatic wall"
                                    hasSwitch: true
                                    checked: Prefs.autoplayInView
                                    onToggled: (on) => {
                                        return Prefs.autoplayInView = on;
                                    }
                                }

                                /*
                                 * The budget, in the open. Every slot is a live
                                 * decoder, which is the one thing on this screen
                                 * that can cost frames rather than pixels — so it
                                 * is a number you can see and change, not one
                                 * compiled in. Hidden while autoplay is off,
                                 * because it would do nothing.
                                 */
                                Choice {
                                    icon: "stacked_bar_chart"
                                    label: "How many play at once"
                                    description: "All in view plays every video that is on screen, like a feed in the browser. Each one is a live decoder, so a capped number is lighter on the machine."
                                    terms: "autoplay how many slots concurrent videos budget all in view"
                                    visible: Prefs.autoplayInView && wanted
                                    options: [
                                        { "id": "0", "label": "All in view" },
                                        { "id": "1", "label": "One" },
                                        { "id": "3", "label": "Three" },
                                        { "id": "5", "label": "Five" }
                                    ]
                                    current: String(Prefs.autoplaySlots)
                                    onPicked: (id) => {
                                        return Prefs.autoplaySlots = Number(id);
                                    }
                                }

                                Choice {
                                    icon: "visibility"
                                    label: "How much must show"
                                    description: "A video starts once this much of it is on screen, and stops when it drops below."
                                    terms: "autoplay threshold visible percent in view"
                                    visible: Prefs.autoplayInView && Prefs.autoplaySlots === 0 && wanted
                                    options: [
                                        { "id": "25", "label": "A quarter" },
                                        { "id": "60", "label": "Most" },
                                        { "id": "100", "label": "All of it" }
                                    ]
                                    current: String(Prefs.autoplayThreshold)
                                    onPicked: (id) => {
                                        return Prefs.autoplayThreshold = Number(id);
                                    }
                                }

                                /*
                                 * What makes the two features one feature.
                                 * Without it the wall slides past at a steady
                                 * rate and a clip gets whatever fraction of a
                                 * second it happened to be on screen for.
                                 */
                                Setting {
                                    icon: "motion_photos_pause"
                                    label: "Wait on each new video while autoscrolling"
                                    description: "Autoscroll holds when something new starts playing, then carries on by itself."
                                    terms: "autoscroll pause dwell wait video autoplay"
                                    shown: Prefs.autoplayInView
                                    hasSwitch: true
                                    checked: Prefs.dwellOnVideo
                                    onToggled: (on) => {
                                        return Prefs.dwellOnVideo = on;
                                    }
                                }

                                Setting {
                                    icon: "center_focus_strong"
                                    label: "Centre it first"
                                    description: "When a playing video reaches the middle, the wall lines it up in the centre before waiting on it. Each video once."
                                    terms: "autoscroll snap centre center lock video"
                                    shown: Prefs.autoplayInView && Prefs.dwellOnVideo
                                    hasSwitch: true
                                    checked: Prefs.snapToVideo
                                    onToggled: (on) => {
                                        return Prefs.snapToVideo = on;
                                    }
                                }

                                /*
                                 * The rest of what a self-scrolling wall needs
                                 * to be bearable, from the userscript this was
                                 * measured against: hold while you are looking
                                 * at one, and give way to your own hand.
                                 */
                                Setting {
                                    icon: "pan_tool"
                                    label: "Hold while the pointer is on a picture"
                                    description: "Autoscroll stops moving while you are looking at one, and carries on when you move away."
                                    terms: "autoscroll pause hover hold pointer picture"
                                    hasSwitch: true
                                    checked: Prefs.pauseOnHover
                                    onToggled: (on) => {
                                        return Prefs.pauseOnHover = on;
                                    }
                                }

                                Setting {
                                    icon: "resume"
                                    label: "Come back after you scroll it yourself"
                                    description: "Dragging or flicking takes over; autoscroll waits rather than fighting your hand, then resumes. Off, your hand stops it for good."
                                    terms: "autoscroll resume idle drag flick take over"
                                    hasSwitch: true
                                    checked: Prefs.resumeAfterTouch
                                    onToggled: (on) => {
                                        return Prefs.resumeAfterTouch = on;
                                    }
                                }

                                Choice {
                                    icon: "hourglass_bottom"
                                    label: "How long before it comes back"
                                    terms: "idle delay resume autoscroll seconds"
                                    visible: Prefs.resumeAfterTouch && wanted
                                    options: [
                                        { "id": "1", "label": "1s" },
                                        { "id": "3", "label": "3s" },
                                        { "id": "6", "label": "6s" },
                                        { "id": "12", "label": "12s" }
                                    ]
                                    current: String(Prefs.idleSeconds)
                                    onPicked: (id) => {
                                        return Prefs.idleSeconds = Number(id);
                                    }
                                }

                                /*
                                 * How the wait is worked out, rather than just
                                 * how long: eight seconds is most of a short
                                 * clip and nothing at all of a long one, so a
                                 * single number was always wrong somewhere.
                                 */
                                Choice {
                                    icon: "schedule"
                                    label: "How long to wait on a video"
                                    description: "Its whole length, part of it, or a fixed count. Anything whose length nobody measured falls back to the fixed one."
                                    terms: "dwell watch mode full percent seconds video wait"
                                    visible: Prefs.autoplayInView && Prefs.dwellOnVideo && wanted
                                    options: [
                                        { "id": "full", "label": "All of it" },
                                        { "id": "percent", "label": "Part of it" },
                                        { "id": "fixed", "label": "Fixed" }
                                    ]
                                    current: Prefs.dwellMode
                                    onPicked: (id) => {
                                        return Prefs.dwellMode = id;
                                    }
                                }

                                Setting {
                                    icon: "percent"
                                    label: "How much of it"
                                    description: "Where to move on once a video is this far through."
                                    terms: "watch percent part video dwell"
                                    shown: Prefs.autoplayInView && Prefs.dwellOnVideo && Prefs.dwellMode === "percent"
                                    value: Prefs.dwellPercent + "%"
                                    controlWidth: root.sliderWidth

                                    StyledSlider {
                                        Layout.fillWidth: true
                                        from: 10
                                        to: 100
                                        stepSize: 5
                                        value: Prefs.dwellPercent
                                        onMoved: Prefs.dwellPercent = Math.round(value)
                                    }
                                }

                                Setting {
                                    icon: "waves"
                                    label: "Glide rather than step"
                                    description: "Carries a little of each frame's motion into the next, so a long read feels like gliding instead of ratcheting."
                                    terms: "smooth scroll easing glide autoscroll motion"
                                    hasSwitch: true
                                    checked: Prefs.smoothScroll
                                    onToggled: (on) => {
                                        return Prefs.smoothScroll = on;
                                    }
                                }

                                Setting {
                                    icon: "animation"
                                    label: "How much glide"
                                    description: "How much of the last moment's motion carries over. Far right drifts on after it should have stopped."
                                    terms: "smoothness glide easing strength scroll"
                                    shown: Prefs.smoothScroll
                                    value: Math.round(Prefs.scrollSmoothness * 100) + "%"
                                    controlWidth: root.sliderWidth

                                    StyledSlider {
                                        Layout.fillWidth: true
                                        from: 0
                                        to: 0.95
                                        stepSize: 0.05
                                        value: Prefs.scrollSmoothness
                                        onMoved: Prefs.scrollSmoothness = value
                                    }
                                }

                                Setting {
                                    icon: "swipe_vertical"
                                    label: "The pointer sets the pace"
                                    description: "Keep the pointer low on the wall and it hurries; raise it and it slows down to let you read. Move it away and the speed is whatever you set."
                                    terms: "mouse pointer influence speed autoscroll pace"
                                    hasSwitch: true
                                    checked: Prefs.pointerSteersSpeed
                                    onToggled: (on) => {
                                        return Prefs.pointerSteersSpeed = on;
                                    }
                                }

                                Setting {
                                    icon: "speed"
                                    label: "Slow down after you scroll"
                                    description: "A moment at a gentler pace right after your own scroll, so it does not snatch the wall straight back."
                                    terms: "dampen slow velocity after scroll touch"
                                    hasSwitch: true
                                    checked: Prefs.dampenAfterTouch
                                    onToggled: (on) => {
                                        return Prefs.dampenAfterTouch = on;
                                    }
                                }

                                Choice {
                                    icon: "timer"
                                    label: "How long to wait"
                                    terms: "dwell seconds wait autoscroll video"
                                    visible: Prefs.autoplayInView && Prefs.dwellOnVideo && wanted
                                    options: [
                                        { "id": "3", "label": "3s" },
                                        { "id": "5", "label": "5s" },
                                        { "id": "10", "label": "10s" },
                                        { "id": "20", "label": "20s" }
                                    ]
                                    current: String(Prefs.dwellSeconds)
                                    onPicked: (id) => {
                                        return Prefs.dwellSeconds = Number(id);
                                    }
                                }

                            }

                            Group {
                                page: "video"
                                title: "Playback"
                                footer: "Hover previews are governed by Animate on hover, under Content; this page is about the viewer."

                                Setting {
                                    icon: "smart_display"
                                    label: "Play when opened"
                                    description: "A video starts as soon as you open it instead of waiting for the play button."
                                    terms: "autoplay start"
                                    hasSwitch: true
                                    checked: Prefs.videoAutoplay
                                    onToggled: (on) => {
                                        return Prefs.videoAutoplay = on;
                                    }
                                }

                                Setting {
                                    icon: Prefs.videoSound ? "volume_up" : "volume_off"
                                    label: "Sound in the viewer"
                                    description: "Off, everything you open is muted until you unmute it by hand."
                                    terms: "audio mute volume"
                                    hasSwitch: true
                                    checked: Prefs.videoSound
                                    onToggled: (on) => {
                                        return Prefs.videoSound = on;
                                    }
                                }

                                Setting {
                                    icon: "tune"
                                    label: "Volume"
                                    description: "Shared by the viewer and the hover previews, and remembered between sessions."
                                    terms: "audio sound loud level volume"
                                    value: Math.round(Prefs.videoVolume * 100) + "%"
                                    available: Prefs.videoSound || Prefs.hoverSound
                                    unavailableNote: "sound is off"
                                    controlWidth: root.sliderWidth

                                    StyledSlider {
                                        Layout.fillWidth: true
                                        from: 0
                                        to: 1
                                        stepSize: 0.05
                                        value: Prefs.videoVolume
                                        onMoved: Prefs.videoVolume = value
                                    }

                                }

                                Setting {
                                    icon: "hearing"
                                    label: "Sound on hover"
                                    description: "Only the preview under the pointer is ever audible, never the whole wall."
                                    terms: "audio hover preview mute"
                                    hasSwitch: true
                                    checked: Prefs.hoverSound
                                    onToggled: (on) => {
                                        return Prefs.hoverSound = on;
                                    }
                                }

                                Setting {
                                    icon: "surround_sound"
                                    label: "Sound from a video wallpaper"
                                    description: "Keeps a video wallpaper's audio. It pauses on its own while a window is fullscreen."
                                    terms: "wallpaper audio desktop background"
                                    hasSwitch: true
                                    checked: Prefs.wallpaperSound
                                    onToggled: (on) => {
                                        return Prefs.wallpaperSound = on;
                                    }
                                }

                            }

                            Group {
                                page: "sources"
                                title: "Fetching"
                                footer: "Page limits are per source and apply to searches only. Scrolling in Endless keeps going for as long as any source has more."

                                Choice {
                                    icon: "cloud_download"
                                    label: "When to fetch"
                                    description: "Catalogue only never touches the network, which is also the only setting that works offline."
                                    terms: "endless search catalog crawl network offline fetch mode"
                                    options: [{
                                        "id": "endless",
                                        "label": "Endless",
                                        "icon": "all_inclusive"
                                    }, {
                                        "id": "search",
                                        "label": "Only when searching",
                                        "icon": "manage_search"
                                    }, {
                                        "id": "catalog",
                                        "label": "Catalogue only",
                                        "icon": "inventory_2"
                                    }]
                                    current: Prefs.fetchMode
                                    onPicked: (id) => {
                                        return Prefs.fetchMode = id;
                                    }
                                }

                                Setting {
                                    icon: "travel_explore"
                                    label: "Search every source now"
                                    description: "Asks every enabled source for whatever is in the search bar, as deep as each one will go."
                                    terms: "crawl all sources deep search"
                                    onClicked: {
                                        root.close();
                                        root.searchRequested();
                                    }
                                }

                            }

                            Group {
                                page: "sources"
                                title: "Mixing"
                                footer: "The same seed always gives the same arrangement, so a wall you liked can come back."

                                Choice {
                                    icon: "shuffle"
                                    label: "How sources are mixed"
                                    description: "Each in turn stops one busy site filling the wall. The weights are the First/Normal/Last setting on each source below."
                                    terms: "blend round robin weighted shuffle order mix"
                                    options: [{
                                        "id": "round-robin",
                                        "label": "Each in turn",
                                        "icon": "repeat"
                                    }, {
                                        "id": "weighted",
                                        "label": "Follow the weights",
                                        "icon": "trending_up"
                                    }, {
                                        "id": "shuffle",
                                        "label": "Shuffle from a seed",
                                        "icon": "casino"
                                    }]
                                    current: Catalog.blend
                                    onPicked: (id) => {
                                        return Catalog.setSourcePref({
                                            "blend": id
                                        });
                                    }
                                }

                                Setting {
                                    icon: "casino"
                                    label: "New seed"
                                    description: "Rearranges the same pictures into a different wall."
                                    terms: "shuffle random seed reshuffle"
                                    value: String(Catalog.mixSeed)
                                    available: Catalog.blend === "shuffle"
                                    unavailableNote: "only when shuffling"
                                    onClicked: Catalog.setSourcePref({
                                        "seed": Math.floor(Math.random() * 1e+06)
                                    })
                                }

                            }

                            /*
                             * WHAT IS NOT ANSWERING.
                             *
                             * The first run of this on a real install found
                             * EIGHT of seventy-one sources broken — a 403, a
                             * 401 wanting a token, two 500s, a 404, and two
                             * sites answering 200 with nothing usable in it.
                             * Every one of them had been showing as an empty
                             * wall with no explanation anywhere.
                             *
                             * Only the unhappy ones are listed. A working
                             * source needs no row: this is a fault light, not
                             * an inventory.
                             */
                            Group {
                                page: "sources"
                                title: "Sources that are not answering"
                                footer: root.healthLog.length > 0 ? `Recorded as it happens, in ${root.healthLog}.` : "The daemon records every fetch a source makes."

                                Setting {
                                    icon: "stethoscope"
                                    label: "Ask every source now"
                                    description: {
                                        if (root.healthFailing > 0)
                                            return `${root.healthFailing} not answering${root.healthUnknown > 0 ? `, ${root.healthUnknown} not asked yet` : ""}.`;

                                        if (root.healthUnknown > 0)
                                            return `${root.healthUnknown} have not been asked since the daemon started. One request each, about a minute for all of them.`;

                                        return "Everything answered the last time it was asked.";
                                    }
                                    terms: "doctor probe check sources broken validate health"
                                    available: Client.connected
                                    unavailableNote: "needs the daemon"
                                    onClicked: root.probeSources()
                                }

                                Repeater {
                                    model: root.health

                                    delegate: Setting {
                                        required property var modelData

                                        interactive: false
                                        icon: "error"
                                        label: modelData.id
                                        description: {
                                            const times = modelData.fails > 1 ? `${modelData.fails} times in a row · ` : "";
                                            return `${times}${modelData.detail || "no answer"}`;
                                        }
                                        terms: `source broken failing ${modelData.id} ${modelData.detail}`
                                        value: modelData.status > 0 ? String(modelData.status) : "no reply"
                                    }

                                }

                            }

                            Group {
                                page: "sources"
                                title: "All sources"
                                footer: "Turning a source off stops new pictures coming from it. The ones you already have stay, and it still appears in the filters."

                                // An empty list is a bug, so it says so rather
                                // than drawing nothing.
                                Setting {
                                    shown: Catalog.sourcePrefs.length === 0
                                    interactive: false
                                    icon: Client.connected ? "hourglass_empty" : "cloud_off"
                                    label: Client.connected ? "Asking the daemon" : "Not connected"
                                    description: Client.connected ? "The list arrives as soon as quarryd answers." : "Start quarryd and the sources will list themselves."
                                }

                                Setting {
                                    shown: Catalog.sourcePrefs.length > 0
                                    interactive: false
                                    icon: "cloud_done"
                                    label: "Enabled"
                                    description: "Only enabled sources are crawled. Each category below switches as a whole."
                                    terms: "how many sources on enabled count"
                                    value: root.enabledSources + "/" + Catalog.sourcePrefs.length
                                }

                            }

                            // A card per category is what turns 36 rows into 7
                            // headings you can read in a glance.
                            Repeater {
                                model: root.page === "sources" || root.searching ? root.groupOrder : []

                                delegate: SourceGroup {
                                    required property string modelData

                                    category: modelData
                                    label: (root.categoryMeta[modelData] || {
                                    }).label || modelData
                                    icon: (root.categoryMeta[modelData] || {
                                    }).icon || "cloud"
                                    ids: root.idsByCategory[modelData] || []
                                    rowsById: root.rowsById
                                    maxRows: root.maxSourceRows
                                    filter: root.filter
                                    // Listed but not opened while adult results
                                    // are off: the names alone are enough to be
                                    // unwelcome on a screen someone else sees.
                                    locked: modelData === "adult" && !Prefs.showNsfw
                                    lockedNote: "Hidden while Show adult results is off, under Content."
                                    onWantedChanged: root._bumpGroups()
                                    Component.onCompleted: root._bumpGroups()
                                }

                            }



                            //
                            //                             * SCRIPTS — the userscript idea, applied to a
                            //                             * gallery. services/Scripts.qml says what a script
                            //                             * can reach and why that list is short.
                            //
                            //
                            //                             * THE BROWSER'S OWN SETTINGS, FINALLY REACHABLE.
                            //                             *
                            //                             * BrowserSettings.qml has existed with these rows
                            //                             * for a long time and NOTHING referenced it — the
                            //                             * switch that decides whether a link opens in
                            //                             * quarry or in your own browser was written,
                            //                             * wired to the preference, and impossible to
                            //                             * reach. That is why "open it in quarry" looked
                            //                             * broken: there was no way to ask for it.
                            //
                            BrowserSettings {
                                // It is a SettingSection of its own, not one of
                                // the panel's Groups, so the page it belongs to
                                // is expressed as plain visibility.
                                visible: root.searching || root.page === "content"
                                filter: root.filter
                            }

                            Group {
                                page: "addons"
                                title: "Your scripts"
                                footer: `One .js file each in ${Scripts.dir}, reloaded within two seconds of being saved. SCRIPTS.md has the API.`

                                Setting {
                                    icon: "code"
                                    label: "Run scripts"
                                    description: "Off means none of them load, and nothing is watched."
                                    terms: "script userscript javascript extension automation"
                                    hasSwitch: true
                                    checked: Prefs.scriptsEnabled
                                    onToggled: (on) => {
                                        Prefs.scriptsEnabled = on;
                                        if (on)
                                            Scripts.reload();
                                        else
                                            Scripts.clearAll();
                                    }
                                }

                                Setting {
                                    icon: "folder_open"
                                    label: "Open the scripts folder"
                                    description: Scripts.scripts.length > 0 ? `${Scripts.scripts.length} loaded${Scripts.failing > 0 ? `, ${Scripts.failing} with an error` : ""}.` : "Empty — the examples are a place to start."
                                    terms: "script folder open edit"
                                    value: String(Scripts.scripts.length)
                                    onClicked: Scripts.open()
                                }

                                Setting {
                                    icon: "download"
                                    label: "Add the example scripts"
                                    description: "Copies the ones quarry ships — a 4chan filter, a thread watcher, keybinds — into your folder, where you can edit them."
                                    terms: "script examples install samples 4chan"
                                    onClicked: Scripts.installExamples()
                                }

                                Setting {
                                    icon: "refresh"
                                    label: "Reload now"
                                    description: "Without waiting for the watcher."
                                    terms: "script reload refresh"
                                    available: Prefs.scriptsEnabled
                                    unavailableNote: "scripts are off"
                                    onClicked: Scripts.reload()
                                }

                            }

                            /*
                             * SPLIT BY WHERE THEY RUN, NOT BY WHAT ORDER THE
                             * FOLDER LISTED THEM.
                             *
                             * Eleven scripts in one list, five of them 4chan's,
                             * reads as eleven things that are all happening —
                             * and the one place it said otherwise was a raw
                             * `lens:fourchan` in the middle of a sentence.
                             * Two groups answer the question anybody actually
                             * has: what is running everywhere, and what is
                             * waiting for somewhere in particular.
                             */

                            Group {
                                page: "addons"
                                title: "Everywhere"
                                footer: "A script that throws says so here, with the line it threw on — one broken file must not cost you the rest."
                                visible: Scripts.revision >= 0 && Scripts.scripts.filter(s => s.match === "*").length > 0

                                Repeater {
                                    model: Scripts.revision >= 0 ? Scripts.scripts.filter(s => s.match === "*") : []

                                    delegate: ColumnLayout {
                                        id: scriptEntry

                                        required property var modelData
                                        // Named, because the settings Repeater below
                                        // shadows `modelData` with its own.
                                        readonly property string scriptId: scriptEntry.modelData.id

                                        Layout.fillWidth: true
                                        spacing: 0

                                        Setting {
                                            icon: modelData.error.length > 0 ? "error" : "code"
                                            label: modelData.name + (modelData.version.length > 0 ? ` ${modelData.version}` : "")
                                            description: {
                                                if (modelData.error.length > 0)
                                                    return modelData.error;

                                                const grants = modelData.grants.length > 0 ? modelData.grants.join(", ") : "nothing";
                                                return `${modelData.description || "No description."} · may use ${grants}`;
                                            }
                                            terms: `script ${modelData.id} ${modelData.description}`
                                            hasSwitch: true
                                            checked: modelData.enabled
                                            onToggled: (on) => {
                                                return Scripts.setEnabled(modelData.id, on);
                                            }
                                        }

                                        // Only while it is on: an option for something
                                        // switched off is a control that does nothing.
                                        Repeater {
                                            model: modelData.enabled && Scripts.revision >= 0 ? Scripts.settingsFor(modelData.id) : []

                                            delegate: ScriptSetting {
                                                required property var modelData

                                                scriptId: scriptEntry.scriptId
                                                spec: modelData
                                            }
                                        }
                                    }

                                }

                            }

                            Group {
                                page: "addons"
                                title: "Only in one place"
                                footer: "These do nothing at all until you are where they say — so they cost you nothing while you are not."
                                visible: Scripts.revision >= 0 && Scripts.scripts.filter(s => s.match !== "*").length > 0

                                Repeater {
                                    model: Scripts.revision >= 0 ? Scripts.scripts.filter(s => s.match !== "*") : []

                                    delegate: ColumnLayout {
                                        id: scopedEntry

                                        required property var modelData
                                        readonly property string scriptId: scopedEntry.modelData.id

                                        Layout.fillWidth: true
                                        spacing: 0

                                        Setting {
                                            icon: modelData.error.length > 0 ? "error" : "code"
                                            label: modelData.name + (modelData.version.length > 0 ? ` ${modelData.version}` : "")
                                            // The place, in words, in the slot every
                                            // other row uses for its number — the
                                            // one fact that separates these from the
                                            // group above.
                                            value: Scripts.scopeLabel(modelData.match)
                                            description: {
                                                if (modelData.error.length > 0)
                                                    return modelData.error;

                                                const grants = modelData.grants.length > 0 ? modelData.grants.join(", ") : "nothing";
                                                const here = Scripts.appliesHere(modelData.match) ? "running here" : "not here right now";
                                                return `${modelData.description || "No description."} · ${here} · may use ${grants}`;
                                            }
                                            terms: `script ${modelData.id} ${modelData.description} ${modelData.match}`
                                            hasSwitch: true
                                            checked: modelData.enabled
                                            onToggled: (on) => {
                                                return Scripts.setEnabled(modelData.id, on);
                                            }
                                        }

                                        Repeater {
                                            model: modelData.enabled && Scripts.revision >= 0 ? Scripts.settingsFor(scopedEntry.scriptId) : []

                                            delegate: ScriptSetting {
                                                required property var modelData

                                                scriptId: scopedEntry.scriptId
                                                spec: modelData
                                            }
                                        }
                                    }

                                }

                            }
                                                        Group {
                                page: "addons"
                                title: "Installed"
                                footer: "A turned-off extension is never loaded, so a broken one costs nothing while it is off."

                                Setting {
                                    shown: Extensions.count === 0
                                    interactive: false
                                    icon: "extension_off"
                                    label: "None found"
                                    description: "Drop a folder with a manifest.json into ~/.local/share/quarry/extensions."
                                    terms: "extensions addons plugins"
                                }

                                Repeater {
                                    model: root.page === "extensions" || root.searching ? Extensions.catalog : []

                                    delegate: ExtensionRow {
                                        required property var modelData
                                        // Extensions carry their own names, so
                                        // the search matches those rather than a
                                        // label written here.
                                        readonly property bool wanted: root.filter.length === 0 || (modelData.name + " " + (modelData.description || "")).toLowerCase().indexOf(root.filter) >= 0

                                        entry: modelData
                                        visible: wanted
                                    }

                                }

                            }
                            Group {
                                page: "addons"
                                title: "Extensions folder"
                                footer: "An extension that fails to load says why on its own row, with the file and the line."

                                Setting {
                                    icon: "folder_open"
                                    label: "Open your extensions folder"
                                    description: "~/.local/share/quarry/extensions"
                                    terms: "extensions folder directory install"
                                    onClicked: Sys.open(Sys.home + "/.local/share/quarry/extensions")
                                }

                                Setting {
                                    icon: "refresh"
                                    label: "Rescan"
                                    description: "Re-reads the folder without restarting the app."
                                    terms: "extensions reload rescan refresh"
                                    value: Extensions.count + " found · " + Extensions.enabledCount + " on"
                                    onClicked: Extensions.rescan()
                                }

                            }
/*
                             * WHAT IS ACTUALLY ON THE DISK.
                             *
                             * Quarry keeps four kinds of file and until now
                             * said so nowhere: the only way to learn that the
                             * thumbnails had reached three gigabytes was `du`,
                             * and the only way to change the limit was an
                             * environment variable on the daemon. Measured on
                             * a real install while writing this: 3.0 GB of
                             * thumbnails, 1.0 GB of cached pages, 243 MB of
                             * video — and the page cache had no limit at all.
                             *
                             * Every row here is a copy of something that can
                             * be fetched again, which is what makes a delete
                             * button safe to put on it. The catalogue is
                             * listed with them and has no button, because it
                             * is the one thing that is not a copy.
                             */

                            Group {
                                page: "storage"
                                title: "On this disk"
                                /*
                                 * The old line — "every bit of it is rebuilt by
                                 * browsing" — stopped being true the moment the
                                 * catalogue joined this group: three quarters
                                 * of that total is the one thing on the page
                                 * that does NOT come back. It also carries the
                                 * affordance the six cache rows used to repeat
                                 * between them.
                                 */
                                footer: root.storageTotal.length > 0 ? `${root.storageTotal} in all. Press a cache to empty it — each one is rebuilt by browsing. The catalogue is not.` : "Ask the daemon what it is keeping."

                                Setting {
                                    icon: "sync"
                                    label: "Measure what is stored"
                                    description: root.storageWhen.length > 0 ? `Last looked: ${root.storageWhen}. Walking sixty thousand files is not free, so it is not automatic.` : "Walks the cache folders and reports what is in them."
                                    terms: "storage disk space size cache measure du"
                                    available: Client.connected
                                    unavailableNote: "needs the daemon"
                                    onClicked: root.measureStorage()
                                }

                                Repeater {
                                    model: root.storageDirs

                                    delegate: Setting {
                                        required property var modelData

                                        icon: ({
                                            "thumbs": "image",
                                            "media": "movie",
                                            "http": "public",
                                            "frames": "burst_mode",
                                            "models": "view_in_ar",
                                            "lens": "lens_blur"
                                        })[modelData.id] || "folder"
                                        label: modelData.label
                                        // "press to empty it" was on all six of
                                        // these, which is a sentence you read
                                        // once and then six times more. The
                                        // group's footer says it for all of
                                        // them; the row says what it holds.
                                        description: `${modelData.files.toLocaleString(Qt.locale(), "f", 0)} ${modelData.files === 1 ? "file" : "files"}`
                                        terms: `storage cache clear ${modelData.id} ${modelData.label}`
                                        value: root.bytesLabel(modelData.bytes)
                                        available: Client.connected && modelData.bytes > 0
                                        unavailableNote: "empty"
                                        onClicked: root.clearCache(modelData.id, modelData.label)
                                    }

                                }

                                Setting {
                                    interactive: false
                                    icon: "database"
                                    label: "The catalogue"
                                    description: "Everything quarry has found. Not a cache: crawling it again takes days."
                                    terms: "catalogue database size disk"
                                    value: root.catalogueSize
                                }

                                /*
                                 * ITS OWN ROW, NOT A SECOND MEANING FOR THE ONE
                                 * ABOVE.
                                 *
                                 * This started as "the catalogue row is now
                                 * pressable", which read as exactly what it had
                                 * always been: a line stating a size. A verb
                                 * needs a row of its own, worded as a verb, or
                                 * it is not a control — it is a line somebody
                                 * has to be told about.
                                 *
                                 * It still asks twice. The first press arms it
                                 * and says what will go; the second does it;
                                 * walking away disarms it.
                                 */
                                Setting {
                                    icon: root.catalogueArmed ? "warning" : "delete_forever"
                                    label: root.catalogueArmed ? "Press again to empty it" : "Empty the catalogue"
                                    description: root.catalogueArmed ? "Every row quarry has found goes, and the disk comes back. Your boards, collections and history stay." : "Delete every row and start over. Boards, collections and history are kept."
                                    terms: "catalogue database delete empty clear reset start over wipe remove"
                                    // No size: the row above states it, and the
                                    // same 340 MB twice in adjacent rows reads
                                    // as two things rather than one thing and
                                    // the verb for it.
                                    value: root.catalogueArmed ? "sure?" : ""
                                    destructive: true
                                    available: Client.connected
                                    unavailableNote: "needs the daemon"
                                    onClicked: root.emptyCatalogue()
                                }

                            }

                            Group {
                                page: "storage"
                                title: "Limits"
                                footer: "Checked when the daemon starts and once an hour. Over the limit, the oldest files go first."

                                Choice {
                                    icon: "image"
                                    label: "Thumbnails"
                                    description: "The pictures the wall is made of."
                                    terms: "thumbnail cache limit budget disk quota"
                                    options: root.budgetOptions
                                    current: String(root.budgets.thumbsMb !== undefined ? root.budgets.thumbsMb : 3000)
                                    onPicked: (id) => {
                                        return root.setBudget("thumbsMb", Number(id));
                                    }
                                }

                                Choice {
                                    icon: "public"
                                    label: "Pages and API answers"
                                    description: "What the crawler read, kept so the same page is not fetched twice."
                                    terms: "http cache limit budget pages api"
                                    options: root.budgetOptions
                                    current: String(root.budgets.httpMb !== undefined ? root.budgets.httpMb : 256)
                                    onPicked: (id) => {
                                        return root.setBudget("httpMb", Number(id));
                                    }
                                }

                                Choice {
                                    icon: "movie"
                                    label: "Video and audio"
                                    description: "Clips downloaded to play them."
                                    terms: "media cache limit budget video"
                                    options: root.budgetOptions
                                    current: String(root.budgets.mediaMb !== undefined ? root.budgets.mediaMb : 512)
                                    onPicked: (id) => {
                                        return root.setBudget("mediaMb", Number(id));
                                    }
                                }

                            }

                            Group {
                                page: "library"
                                title: "Library"
                                footer: "The catalogue is kept apart from the cache, so clearing thumbnails never loses a picture you found."

                                Setting {
                                    interactive: false
                                    icon: "database"
                                    label: "Pictures in the catalogue"
                                    description: Client.connected ? "Saved on disk and kept between restarts." : "Not connected — this is the fixture, not your library."
                                    terms: "count items catalogue library size"
                                    value: Client.connected ? String(Catalog.count) : "—"
                                }

                                Setting {
                                    icon: "restore_from_trash"
                                    label: "Restore hidden pictures"
                                    description: "Brings back pictures the daemon hid because a thumbnail would not load. Pictures you hid yourself are never touched."
                                    terms: "hidden restore unhide missing"
                                    value: Catalog.autoHiddenCount > 0 ? String(Catalog.autoHiddenCount) : ""
                                    available: Catalog.autoHiddenCount > 0
                                    unavailableNote: "nothing hidden"
                                    onClicked: Catalog.restoreHidden()
                                }

                                Setting {
                                    icon: "refresh"
                                    label: "Reload the catalogue"
                                    description: "Re-reads every source from the daemon and keeps everything already cached."
                                    terms: "reload refresh catalogue"
                                    onClicked: {
                                        Catalog.load();
                                        root.close();
                                    }
                                }

                            }

                            Group {
                                page: "library"
                                title: "History"
                                footer: "The record of what you searched for, opened and exported — kept so you can get back to it. The last 2,000 entries, and nothing leaves this machine."

                                Setting {
                                    icon: "history"
                                    label: "Keep a history"
                                    description: "Searches, pictures you opened and files you exported."
                                    terms: "history record searches opened exported privacy"
                                    hasSwitch: true
                                    checked: Prefs.keepHistory
                                    onToggled: (on) => {
                                        return Prefs.keepHistory = on;
                                    }
                                }

                                Setting {
                                    icon: "delete_sweep"
                                    label: "Forget everything"
                                    description: "Clears the record. The pictures themselves are untouched."
                                    terms: "history clear forget delete privacy"
                                    onClicked: Client.call("history_clear", {
                                    }, function(err, payload) {
                                        Toast.show(err ? `Could not clear: ${err}` : `Forgot ${payload && payload.removed || 0} entries`);
                                    })
                                }

                            }

                            Group {
                                page: "storage"
                                title: "Thumbnail cache"
                                footer: "Everything here is rebuilt as you browse. Nothing exists only in the cache."

                                Setting {
                                    icon: "folder_open"
                                    label: "Open the cache folder"
                                    description: "Thumbnails only. Safe to delete at any time."
                                    terms: "cache thumbs folder disk space"
                                    value: "thumbs"
                                    onClicked: {
                                        root.close();
                                        root.cacheRequested();
                                    }
                                }

                                Setting {
                                    icon: "delete_sweep"
                                    label: "Rebuild old thumbnails"
                                    // A button and not automatic: clearing means
                                    // every picture you look at again is
                                    // refetched, and doing that to thousands at
                                    // once is how a booru rate limits you.
                                    description: "Old thumbnails were stored lossless at roughly four times the size. This drops them so they re-encode as you browse."
                                    terms: "cache clear webp shrink disk space"
                                    value: "webp"
                                    onClicked: Client.call("thumbs_clear", {
                                        "ext": "webp"
                                    }, function(err, payload) {
                                        if (err) {
                                            Toast.error("Could not clear them — " + err);
                                            return ;
                                        }
                                        const mb = Math.round(((payload && payload.bytesFreed) || 0) / 1.04858e+06);
                                        Toast.show("Cleared " + ((payload && payload.removed) || 0) + " thumbnails · " + mb + " MB");
                                    })
                                }

                            }

                            Group {
                                page: "about"
                                title: "Diagnostics"
                                footer: "The readout draws over the gallery, which is exactly where a picture is, so it is off by default."

                                Setting {
                                    icon: "speed"
                                    label: "Show performance"
                                    description: "Frame rate, memory and decode times in the corner of the gallery."
                                    terms: "fps memory stats performance debug"
                                    hasSwitch: true
                                    checked: Prefs.showStats
                                    onToggled: (on) => {
                                        return Prefs.showStats = on;
                                    }
                                }

                            }

                            Group {
                                page: "about"
                                title: "Connection"
                                footer: "Without the daemon the app falls back to a fixture: it can show pictures, but it cannot fetch, export or remember anything."

                                Setting {
                                    interactive: false
                                    icon: Client.connected ? "dns" : "cloud_off"
                                    label: "Daemon"
                                    description: Client.connected ? "Holds the catalogue, the cache and the image pipeline." : "Not running. Start quarryd and it reconnects on its own."
                                    terms: "quarryd daemon backend connection"
                                    value: Client.connected ? Client.backend : "offline"
                                }

                                Setting {
                                    interactive: false
                                    icon: "handshake"
                                    label: "Protocol"
                                    description: "The version the daemon and the app agreed on when they said hello."
                                    terms: "protocol version"
                                    available: Client.connected
                                    unavailableNote: "not connected"
                                    value: "v" + Client.protocol
                                }

                                Setting {
                                    interactive: false
                                    icon: "cable"
                                    label: "Socket"
                                    description: Client.socketPath.length > 0 ? Client.socketPath : "Set QUARRY_SOCK to point the app at a different daemon."
                                    terms: "socket path quarry_sock"
                                }

                                Setting {
                                    interactive: false
                                    icon: "swap_vert"
                                    label: "Traffic"
                                    description: Client.error.length > 0 ? Client.error : "Calls made and answered since the app started."
                                    destructive: Client.error.length > 0
                                    terms: "requests calls timeouts errors traffic"
                                    value: Client.sent + "/" + Client.received + (Client.timeouts > 0 ? " · " + Client.timeouts + " late" : "")
                                }

                            }

                            // Not a Group: it has to appear exactly when every
                            // group is hidden, and a card that counted itself
                            // would keep that from ever being true.
                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.topMargin: 40
                                spacing: 6
                                visible: root.searching && root.visibleGroups === 0

                                MaterialSymbol {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: "search_off"
                                    iconSize: 44
                                    color: Appearance.colors.colSubtext
                                }

                                StyledText {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: "Nothing matches that"
                                    font.pixelSize: Appearance.font.pixelSize.normal
                                    color: Appearance.colors.colOnLayer1
                                }

                                StyledText {
                                    Layout.fillWidth: true
                                    horizontalAlignment: Text.AlignHCenter
                                    text: "Settings are searched by name, by what they do, and by the words you would look them up under. Source names count too."
                                    wrapMode: Text.WordWrap
                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                    color: Appearance.colors.colSubtext
                                }

                            }

                        }

                        ScrollBar.vertical: StyledScrollBar {
                        }

                    }

                }

            }

        }

    }

    _prefsWatch: Connections {
        function onSourcePrefsChanged() {
            root._rebuildOrder();
        }

        target: Catalog
    }

    /// A card belonging to one page. While a search runs, every page's cards
    /// are on screen at once, so each one says where it came from.
    component Group: SettingSection {
        property string page: ""
        readonly property bool wanted: (root.searching || root.page === page) && visibleRows > 0

        note: root.searching ? root.pageLabel(page) : ""
        visible: wanted
        onWantedChanged: root._bumpGroups()
        Component.onCompleted: root._bumpGroups()
    }

    /// Every row goes through this, so there is no second list of setting names
    /// for the search to fall out of step with.
    component Setting: SettingRow {
        filter: root.filter
    }

    /*
     * A SETTING A SCRIPT DECLARED, drawn like any other.
     *
     * The point is that it is NOT a special case: a script's option gets the
     * same row, the same search, the same control as something built into the
     * app, because to the person changing it there is no difference. The only
     * thing the script supplies is what the option is called and what shape it
     * has — see `@setting` in Scripts.qml.
     *
     * Indented under its script, because a list of loose options whose owner
     * you cannot see is how a settings screen becomes a junk drawer.
     */
    component ScriptSetting: ColumnLayout {
        id: ss

        required property string scriptId
        required property var spec

        Layout.fillWidth: true
        Layout.leftMargin: 18
        spacing: 0

        Setting {
            visible: ss.spec.type !== "choice"
            icon: "tune"
            label: ss.spec.label
            description: ss.spec.description
            terms: `script ${ss.scriptId} ${ss.spec.key} ${ss.spec.label}`
            value: ss.spec.type === "number" ? String(ss.spec.value) : ""
            controlWidth: ss.spec.type === "number" ? root.sliderWidth : 0
            hasSwitch: ss.spec.type === "switch"
            checked: ss.spec.type === "switch" && ss.spec.value === true
            onToggled: (on) => {
                return Scripts.setSetting(ss.scriptId, ss.spec.key, on);
            }

            StyledSlider {
                visible: ss.spec.type === "number"
                Layout.fillWidth: true
                from: ss.spec.min
                to: ss.spec.max
                stepSize: ss.spec.step
                value: Number(ss.spec.value)
                /*
                 * On RELEASE, not on every move.
                 *
                 * `setSetting` reloads the script so it picks the value up, and
                 * reloading on each step of a drag would tear a running script
                 * down and build it again sixty times a second.
                 */
                onPressedChanged: {
                    if (!pressed)
                        Scripts.setSetting(ss.scriptId, ss.spec.key, Math.round(value));

                }
            }
        }

        Choice {
            visible: ss.spec.type === "choice" && wanted
            icon: "tune"
            label: ss.spec.label
            description: ss.spec.description
            terms: `script ${ss.scriptId} ${ss.spec.key}`
            options: (ss.spec.options || []).map((o) => {
                return {
                    "id": String(o),
                    "label": String(o)
                };
            })
            current: String(ss.spec.value)
            onPicked: (id) => {
                return Scripts.setSetting(ss.scriptId, ss.spec.key, id);
            }
        }
    }

    /*
     * A choice between named options: a picker, not three switches. Fetch mode
     * and blend were both radio groups drawn as switches, so "off" was a state
     * two of them showed and none of them could reach.
     *
     * The pills sit on their own line because three labels and a description
     * will not fit beside each other at 520px.
     */
    component Choice: ColumnLayout {
        id: choice

        property string icon: ""
        property string label: ""
        property string description: ""
        property string terms: ""
        /// [{ id, label, icon }]
        property var options: []
        property string current: ""
        readonly property bool matched: root.filter.length === 0 || (choice.label + " " + choice.description + " " + choice.terms + " " + choice.options.map((o) => {
            return o.label;
        }).join(" ")).toLowerCase().indexOf(root.filter) >= 0
        readonly property bool wanted: choice.matched

        signal picked(string id)

        Layout.fillWidth: true
        Layout.topMargin: 6
        Layout.bottomMargin: 6
        spacing: 8
        visible: choice.wanted

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 12
            Layout.rightMargin: 12
            spacing: 12

            MaterialSymbol {
                Layout.alignment: Qt.AlignVCenter
                visible: choice.icon.length > 0
                text: choice.icon
                iconSize: Appearance.font.pixelSize.larger
                color: Appearance.colors.colOnLayer1
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1

                StyledText {
                    Layout.fillWidth: true
                    text: choice.label
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colOnLayer1
                    elide: Text.ElideRight
                }

                StyledText {
                    Layout.fillWidth: true
                    visible: choice.description.length > 0
                    text: choice.description
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                    wrapMode: Text.WordWrap
                }

            }

        }

        Flow {
            Layout.fillWidth: true
            Layout.leftMargin: 46 // under the label, not the icon
            Layout.rightMargin: 12
            spacing: 6

            Repeater {
                model: choice.options

                delegate: PillTab {
                    required property var modelData

                    label: modelData.label
                    icon: modelData.icon ?? ""
                    active: choice.current === modelData.id
                    showBorder: true
                    verticalPadding: 6
                    labelSize: Appearance.font.pixelSize.smallie
                    iconSize: Appearance.font.pixelSize.small
                    onTriggered: choice.picked(modelData.id)
                }

            }

        }

    }

}
