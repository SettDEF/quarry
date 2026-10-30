import QtQuick
import qs.modules.common
import qs.modules.widgets
import qs.services

/*
 * Six layouts behind one button.
 *
 * They used to be six permanent icons in the header, which is six things to
 * scan past every time you look at the toolbar to find the one control you
 * actually wanted. A layout is chosen rarely and remembered per kind, so it
 * belongs behind the button that shows the current one rather than beside five
 * that are not selected.
 */
MenuPopup {
    id: root

    /*
     * The app's own, plus whatever an extension registered. `Host.layouts` was
     * written to by nothing and read by nothing: a contributed layout appeared
     * in no menu and drew nothing. See shell.qml for the other half.
     */
    readonly property var layouts: root.builtinLayouts.concat(Host.layouts.filter(l => l && l.id && l.component))

    readonly property var builtinLayouts: [{
        "id": "wall",
        "label": "Wall",
        "icon": "view_quilt",
        "hint": "real shapes"
    }, {
        "id": "grid",
        "label": "Grid",
        "icon": "grid_view",
        "hint": "even tiles"
    }, {
        "id": "sheet",
        "label": "Contact sheet",
        "icon": "apps",
        "hint": "hundreds"
    }, {
        "id": "compact",
        "label": "Compact",
        "icon": "view_list",
        "hint": "the facts"
    }, {
        "id": "compare",
        "label": "Compare",
        "icon": "compare",
        "hint": "side by side"
    }, {
        "id": "context",
        "label": "In context",
        "icon": "wallpaper",
        "hint": "at final size"
    }]
    /// The sorts a layout can keep — the same tokens the query bar takes, so
    /// choosing one here is the same act as typing it.
    readonly property var sorts: [{
        "token": "",
        "label": "However it was asked",
        "icon": "sort"
    }, {
        "token": "new",
        "label": "Newest first",
        "icon": "schedule"
    }, {
        "token": "large",
        "label": "Largest first",
        "icon": "photo_size_select_large"
    }, {
        "token": "wide",
        "label": "Widest first",
        "icon": "panorama"
    }, {
        "token": "title",
        "label": "A to Z",
        "icon": "sort_by_alpha"
    }, {
        "token": "random",
        "label": "Shuffled",
        "icon": "shuffle"
    }]
    //
    //     * A LENS BORROWS THIS MENU RATHER THAN GROWING ITS OWN.
    //     *
    //     * Reddit and Morse both draw walls of pictures and both learned the same
    //     * four shapes — and both had put the switch in their own overflow menu,
    //     * so the button that means "how is this laid out" everywhere else in
    //     * quarry did nothing while a lens was open. Two controls for one idea.
    //     *
    //     * A lens that declares `layouts` drives this menu instead: its own list,
    //     * its own current choice, its own setter. Everything below that belongs
    //     * to the catalogue — "In context", the sort tokens, what the grid shows —
    //     * is hidden while it does, because none of it applies to somebody else's
    //     * feed.
    //
    //
    //     * WHO OWNS THIS MENU RIGHT NOW.
    //     *
    //     * History first, because it is a panel drawn OVER whatever is behind it:
    //     * while it is open it is what you are looking at, and a layout button
    //     * that changed the wall underneath would change something you cannot
    //     * see. Then the open lens. Then the catalogue, which owns it the rest of
    //     * the time.
    //
    readonly property var lens: {
        if (Shell.historyPanel && Shell.historyPanel.open)
            return Shell.historyPanel;

        return Lenses.activeId.length > 0 ? Lenses.instanceOf(Lenses.activeId) : null;
    }
    readonly property var lensLayouts: root.lens && root.lens.layouts ? root.lens.layouts : []
    readonly property bool lensDriving: root.lensLayouts.length > 0

    /// A layout asked for its own sort: the shell writes it into the query,
    /// because the query is where sorting lives in this app.
    signal sortRequested(string token)

    /// The icon and the name of whatever this menu is driving right now — the
    /// history panel, an open lens, or the catalogue. The header button read
    /// `Prefs.layoutMode` unconditionally, so with History open it drew the
    /// wall's icon above a menu that was setting the panel's layout.
    readonly property var current: {
        const list = root.lensDriving ? root.lensLayouts : root.layouts;
        const now = root.lensDriving ? root.lens.layout : Prefs.layoutMode;
        const found = list.find((l) => {
            return l.id === now;
        });
        return found ? found : {
            "icon": "grid_view",
            "label": now
        };
    }

    function iconFor(id) {
        const found = root.layouts.find((l) => {
            return l.id === id;
        });
        return found ? found.icon : "grid_view";
    }

    function choose(id) {
        if (root.lensDriving) {
            root.lens.setLayout(id);
            return ;
        }
        Prefs.layoutMode = id;
    }

    function chosen(id) {
        return root.lensDriving ? root.lens.layout === id : Prefs.layoutMode === id;
    }

    function popupAt(x, y) {
        root.x = Math.max(8, Math.min(x, root.parent.width - root.implicitWidth - 8));
        root.y = y;
        root.visible ? root.close() : root.open();
    }

    minWidth: 220

    Repeater {
        // A lens's own shapes when one is open; otherwise the catalogue's.
        // "In context" is drawn separately below: it is the one layout with
        // settings of its own, so it is the one row that cascades.
        model: root.lensDriving ? root.lensLayouts : root.layouts.filter((l) => {
            return l.id !== "context";
        })

        delegate: MenuRow {
            required property var modelData

            text: modelData.label
            icon: modelData.icon
            hint: modelData.hint
            checked: root.chosen(modelData.id)
            onTriggered: {
                root.close();
                root.choose(modelData.id);
            }
        }

    }

    /*
     * THE ONE LAYOUT THAT HAS SETTINGS OF ITS OWN.
     *
     * "In context" draws the candidate into the slots it is going to, and
     * WHICH slots is personal -- they are packs, and each one can be switched
     * off. Those belong behind this row rather than as six more rows in a menu
     * whose other entries have nothing to do with them.
     *
     * The row still does its own job: a tap switches to the layout, and only
     * hover opens the packs. A layout row that stopped switching layouts to
     * become a folder would be a worse menu, not a better one.
     */
    MenuSubmenu {
        readonly property var spec: root.layouts.find((l) => {
            return l.id === "context";
        })

        // Belongs to the catalogue: a lens's feed has no slots to draw into.
        visible: !root.lensDriving
        text: spec.label
        icon: spec.icon
        hint: spec.hint
        checked: Prefs.layoutMode === "context"
        tapOpens: false
        minWidth: 268
        parentMenu: root
        onTriggered: {
            root.close();
            Prefs.layoutMode = "context";
        }

        MenuRow {
            text: "Mockups drawn"
            icon: "dashboard_customize"
            hint: `${Extensions.mockPacks.filter(p => Extensions.isEnabled(p.id)).length}/${Extensions.mockPacks.length}`
            enabled: false
        }

        MenuRow {
            separator: true
        }

        Repeater {
            model: Extensions.mockPacks

            delegate: MenuRow {
                required property var modelData

                text: modelData.name
                icon: "aspect_ratio"
                checked: Extensions.isEnabled(modelData.id)
                // Deliberately does NOT close the menu: switching packs on and
                // off is a comparison, and closing after each one turns three
                // toggles into three trips back through the menu.
                onTriggered: Extensions.toggle(modelData.id)
            }

        }

        MenuRow {
            text: "No packs installed"
            icon: "extension_off"
            enabled: false
            visible: Extensions.mockPacks.length === 0
        }

    }

    MenuRow {
        separator: true
        visible: tuning.visible
    }

    /*
     * WHAT THIS LAYOUT SHOWS — AND ONLY THIS LAYOUT.
     *
     * A wall and a list are not one screen at two sizes. On the wall the
     * picture is the point and a caption over it is noise; in a list the
     * caption IS the row. One global set of toggles made every choice a
     * compromise between them, so each layout now keeps its own answer —
     * every badge, every hover button, its size, its sort.
     *
     * It sits behind the layout rows rather than among them because it is
     * about the layout you are ON, and a menu whose entries switch layouts
     * should not suddenly have entries that change one.
     */
    MenuSubmenu {
        id: tuning

        readonly property string lay: Prefs.layoutMode
        readonly property var opts: Prefs.layoutSettings(tuning.lay)
        readonly property string label: {
            const found = root.layouts.find((l) => {
                return l.id === tuning.lay;
            });
            return found ? found.label : tuning.lay;
        }
        /*
         * The compact list draws rows, not tiles: it prints the title and the
         * source itself and has no picture to put a button on. Offering it
         * those toggles would be a menu promising something it cannot do,
         * which is the same lie as an empty state that will not say why.
         */
        readonly property bool tiles: ["wall", "grid"].indexOf(tuning.lay) >= 0

        // Only the layouts that draw tiles have anything to say here — and
        // only the catalogue's, since these toggles write into the app's own
        // per-layout settings and a lens draws its feed its own way.
        visible: !root.lensDriving && ["wall", "grid", "compact"].indexOf(tuning.lay) >= 0
        // "What wall shows" is not a sentence; the article is what makes this
        // read as the name of a place rather than a keyword.
        text: `What the ${tuning.label.toLowerCase()} shows`
        icon: "tune"
        hint: "just here"
        minWidth: 290
        parentMenu: root

        MenuRow {
            text: "On the picture"
            enabled: false
            visible: tuning.tiles
        }

        Repeater {
            model: [{
                "key": "badges",
                "label": "Kind badges",
                "icon": "label"
            }, {
                "key": "length",
                "label": "Video length",
                "icon": "schedule"
            }, {
                "key": "ring",
                "label": "Outline on hover",
                "icon": "crop_square"
            }]

            delegate: MenuRow {
                required property var modelData

                text: modelData.label
                icon: modelData.icon
                visible: tuning.tiles
                checked: tuning.opts[modelData.key] !== false
                // Never closes: setting up a layout is several toggles, and a
                // menu that shuts after each one turns that into several trips.
                onTriggered: Prefs.setLayoutOption(tuning.lay, modelData.key, tuning.opts[modelData.key] === false)
            }

        }

        MenuRow {
            separator: true
            visible: tuning.tiles
        }

        MenuRow {
            text: "The caption, while hovered"
            enabled: false
            visible: tuning.tiles
        }

        Repeater {
            model: [{
                "key": "strip",
                "label": "Caption at all",
                "icon": "subtitles"
            }, {
                "key": "title",
                "label": "Title",
                "icon": "title"
            }, {
                "key": "meta",
                "label": "Source and size",
                "icon": "info"
            }]

            delegate: MenuRow {
                required property var modelData

                text: modelData.label
                icon: modelData.icon
                checked: tuning.opts[modelData.key] !== false
                // Title and detail are inside the caption: with the caption
                // off they have nothing to appear on, and saying so beats
                // letting someone toggle a row that cannot do anything.
                visible: tuning.tiles
                enabled: modelData.key === "strip" || tuning.opts["strip"] !== false
                onTriggered: Prefs.setLayoutOption(tuning.lay, modelData.key, tuning.opts[modelData.key] === false)
            }

        }

        MenuRow {
            separator: true
            visible: tuning.tiles
        }

        MenuRow {
            text: "Buttons on a hovered picture"
            enabled: false
            visible: tuning.tiles
        }

        Repeater {
            model: [{
                "key": "export",
                "label": "Export",
                "icon": "crop"
            }, {
                "key": "open",
                "label": "Open",
                "icon": "open_in_full"
            }, {
                "key": "keep",
                "label": "Keep",
                "icon": "bookmark_add"
            }, {
                "key": "board",
                "label": "Put on a board",
                "icon": "dashboard_customize"
            }, {
                "key": "wallpaper",
                "label": "Wallpaper",
                "icon": "wallpaper"
            }, {
                "key": "copy",
                "label": "Copy",
                "icon": "content_copy"
            }, {
                "key": "similar",
                "label": "Find similar",
                "icon": "image_search"
            }, {
                "key": "hide",
                "label": "Hide",
                "icon": "visibility_off"
            }]

            delegate: MenuRow {
                required property var modelData

                text: modelData.label
                icon: modelData.icon
                visible: tuning.tiles
                checked: tuning.opts[modelData.key] === true
                onTriggered: Prefs.setLayoutOption(tuning.lay, modelData.key, tuning.opts[modelData.key] !== true)
            }

        }

        MenuRow {
            separator: true
            visible: tuning.tiles
        }

        MenuRow {
            separator: true
        }

        MenuRow {
            text: "Back to how it ships"
            icon: "restart_alt"
            enabled: JSON.stringify((Prefs.layoutOptions || {
            })[tuning.lay] || {
            }) !== "{}"
            onTriggered: Prefs.resetLayoutOptions(tuning.lay)
        }

    }

    /*
     * SORTING IS NOT A PROPERTY OF THE TILE SHAPE.
     *
     * It lived inside "What the wall shows", which is drawn only for the wall,
     * the grid and the compact list — so in the contact sheet, compare and in
     * context there was no sort control at all, and the only way to order
     * 275,000 items was to know the grammar and type `sort:new`. Sorting writes
     * a query token like every other filter here; it belongs to the menu.
     */
    MenuSubmenu {
        id: sorting

        readonly property var opts: Prefs.layoutSettings(Prefs.layoutMode)

        visible: !root.lensDriving
        text: "Sort"
        icon: "sort"
        hint: {
            const found = root.sorts.find((s) => {
                return s.token === (sorting.opts["sort"] || "");
            });
            return found ? found.label : "as asked";
        }
        minWidth: 230
        parentMenu: root

        Repeater {
            model: root.sorts

            delegate: MenuRow {
                required property var modelData

                text: modelData.label
                icon: modelData.icon
                checked: (sorting.opts["sort"] || "") === modelData.token
                onTriggered: {
                    Prefs.setLayoutOption(Prefs.layoutMode, "sort", modelData.token);
                    root.sortRequested(modelData.token);
                }
            }

        }

    }

}
