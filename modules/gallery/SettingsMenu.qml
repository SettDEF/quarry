import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

/*
 * Settings, in the overflow — which is what an overflow is for.
 *
 * The ⋮ was wrong when it held the app's main verb; it is right for the things
 * you set once and forget: how the wall looks, whether adult results appear,
 * where the cache lives, what the daemon is doing.
 *
 * IT HAD BECOME A LIST OF TWENTY-FOUR BARS, taller than the window, mixing
 * four different kinds of thing that all looked the same: six layouts you pick
 * between, two rows that were really one number, six settings you turn on and
 * off, and a handful of actions — every one a full-width row with a tick on
 * the right and, when on, a filled ground. That reads as a patchwork, and the
 * thing you came for is somewhere in it.
 *
 * Each kind is drawn as what it IS now:
 *   - the layouts are one picker of six icons, the way a toolbar shows a choice
 *   - the tile size is one row with − 240px +
 *   - the settings are rows with switches
 *   - the rest are actions, behind a submenu when they are rarely used
 * Same contents; a third of the height, and nothing to read twice.
 */
MenuPopup {
    id: root

    minWidth: 288

    signal settingsRequested
    signal reloadRequested
    signal cacheRequested
    signal searchRequested
    signal paletteRequested
    signal surpriseRequested
    signal restoreRequested

    function popupAt(x, y) {
        root.x = Math.max(8, Math.min(x, root.parent.width - root.implicitWidth - 8));
        root.y = y;
        root.visible ? root.close() : root.open();
    }

    readonly property var layouts: [
        { "id": "wall", "label": "Wall", "icon": "view_quilt" },
        { "id": "grid", "label": "Grid", "icon": "grid_view" },
        { "id": "sheet", "label": "Contact sheet", "icon": "apps" },
        { "id": "compact", "label": "Compact", "icon": "view_list" },
        { "id": "compare", "label": "Compare", "icon": "compare" },
        { "id": "context", "label": "In context", "icon": "preview" }
    ]

    /*
     * A LENS IS A DIFFERENT PLACE.
     *
     * While one is open, the wall's layout and tile size set nothing you can
     * see — so its own controls come first, and the gallery's follow for when
     * you go back.
     */
    readonly property bool inLens: Lenses.activeId.length > 0

    MenuSection {
        visible: root.inLens
        text: Lenses.activeEntry ? Lenses.activeEntry.name : "Lens"
        rule: false
    }

    MenuSubmenu {
        visible: root.inLens && Lenses.skinsOf(Lenses.activeId).length > 1
        text: "Skin"
        icon: "palette"
        hint: {
            const skins = root.inLens ? Lenses.skinsOf(Lenses.activeId) : [];
            const now = root.inLens ? Lenses.skinOf(Lenses.activeId) : "";
            const found = skins.find(s => s.id === now);
            return found ? found.name : "";
        }
        minWidth: 220
        parentMenu: root

        Repeater {
            model: root.inLens ? Lenses.skinsOf(Lenses.activeId) : []
            delegate: MenuRow {
                required property var modelData
                text: modelData.name
                icon: "brush"
                checked: Lenses.skinOf(Lenses.activeId) === modelData.id
                onTriggered: {
                    Lenses.setSkin(Lenses.activeId, modelData.id);
                    root.close();
                }
            }
        }
    }

    /*
     * EXTENSIONS, WHEREVER YOU ARE.
     *
     * Rows from a lens belong to that lens and show while it is open — see
     * Lenses.menuItems. Rows from a pack that is not a reader for any site
     * (the slideshow) have nowhere else to be, so they show here, with the
     * registered actions under them.
     */
    MenuSection {
        visible: !root.inLens && (Lenses.menuItems.length > 0 || Host.actions.length > 0)
        text: "Extensions"
        rule: false
    }

    // Whatever the lens itself put here — its own verbs, not the app's.
    Repeater {
        model: Lenses.menuItems
        delegate: MenuRow {
            required property var modelData
            // Lenses.menuItems wraps each row as {lensId, item: {...}} so the
            // menu knows whose row it is. Reading the label off the WRAPPER
            // left every lens's rows blank and dead.
            readonly property var row: modelData.item || modelData
            text: row.label || row.text || ""
            icon: row.icon || "bolt"
            hint: row.hint || ""
            // A lens row that is a SWITCH must look like one. Dropping this
            // made "Start Morse when this opens" read as an action: clicking
            // it turned the feature off and the menu said nothing.
            checked: row.checked === true
            onTriggered: {
                root.close();
                if (row.trigger)
                    row.trigger();
                else if (row.action)
                    row.action();
            }
        }
    }

    /*
     * `Host.registerAction` — the other half of a promise nothing kept.
     *
     * An extension could register an action and nothing read the list, so
     * `Host.actions` was a write-only property: the slideshow registered one at
     * enable and it existed in no menu, under no shortcut, reachable by
     * nothing. This is where they land.
     */
    Repeater {
        model: Host.actions

        delegate: MenuRow {
            required property var modelData

            text: modelData.label || modelData.id
            icon: modelData.icon || "extension"
            hint: modelData.hint || ""
            checked: modelData.checked === true
            onTriggered: {
                root.close();
                if (modelData.run)
                    modelData.run();
            }
        }
    }

    MenuRow {
        visible: root.inLens
        text: "Close the lens"
        icon: "close"
        hint: "Esc"
        onTriggered: {
            root.close();
            Lenses.close();
        }
    }

    // ── how the wall is laid out ────────────────────────────────────────────

    MenuSection {
        text: "Layout"
        rule: false
    }

    Item {
        /*
         * THE SAME CHOICE THE LAYOUT BUTTON MAKES, MADE THE SAME WAY.
         *
         * These wrote `Prefs.layoutMode` straight, while LayoutMenu.choose()
         * hands the choice to whoever is actually on screen — the history
         * panel, then an open lens, then the catalogue. With a lens up, this
         * picker re-laid-out the wall UNDERNEATH it: six buttons that changed
         * something you could not see and could not show you what they had
         * done. It stands down while something else is driving.
         */
        Layout.fillWidth: true
        implicitHeight: 44
        visible: !!Shell.layoutMenu && !Shell.layoutMenu.lensDriving

        Row {
            id: picker
            anchors.centerIn: parent
            spacing: 3

            Repeater {
                model: root.layouts
                delegate: SegmentButton {
                    required property var modelData
                    required property int index
                    size: 40
                    iconSize: 20
                    icon: modelData.icon
                    tooltip: modelData.label
                    toggled: !!Shell.layoutMenu && Shell.layoutMenu.chosen(modelData.id)
                    position: index === 0 ? "first" : index === root.layouts.length - 1 ? "last" : "middle"
                    onClicked: Shell.layoutMenu.choose(modelData.id)
                }
            }
        }
    }

    // The name of what is selected, so the icons never have to be guessed.
    StyledText {
        Layout.fillWidth: true
        Layout.bottomMargin: 4
        horizontalAlignment: Text.AlignHCenter
        text: {
            const found = root.layouts.find(l => l.id === Prefs.layoutMode);
            return found ? found.label : "";
        }
        font.pixelSize: Appearance.font.pixelSize.smallest
        color: Appearance.colors.colSubtext
    }

    Item {
        Layout.fillWidth: true
        implicitHeight: 40

        StyledText {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: "Tile size"
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colOnLayer1
        }

        Stepper {
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            // Steps of twenty pixels: the two rows this replaces moved by
            // forty, which is a jump you have to undo half the time.
            from: 5
            to: 21
            value: Math.round(Prefs.gridTileSize / 20)
            display: `${Math.round(Prefs.gridTileSize / 20) * 20}px`
            onChanged_: v => Prefs.gridTileSize = Math.max(100, Math.min(420, v * 20))
        }
    }

    // ── what is shown ───────────────────────────────────────────────────────

    MenuSection {
        text: "What is shown"
    }

    // One choice, three answers — two switches made "show" and "blur" look
    // independent when hiding them makes the blur meaningless.
    Item {
        Layout.fillWidth: true
        implicitHeight: 44

        readonly property string mode: !Prefs.showNsfw ? "hide" : Prefs.blurNsfw ? "blur" : "show"

        function choose(mode) {
            Catalog.setAdult(mode !== "hide");
            Prefs.blurNsfw = mode === "blur";
            /*
             * Any `-nsfw` a previous version left in the bar is cleared, because
             * the daemon applies the rule now and a leftover predicate would show
             * as a filter the user did not type and cannot see the reason for.
             */
            if (Catalog.query.indexOf("-nsfw") >= 0)
                Catalog.query = Catalog.query.replace(/\s*-nsfw/g, "").trim();

        }

        StyledText {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: "Adult"
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colOnLayer1
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 3

            Repeater {
                model: [
                    { "id": "hide", "label": "Hide", "icon": "visibility_off" },
                    { "id": "blur", "label": "Blur", "icon": "blur_on" },
                    { "id": "show", "label": "Show", "icon": "visibility" }
                ]
                delegate: SegmentButton {
                    required property var modelData
                    required property int index
                    size: 34
                    iconSize: 18
                    icon: modelData.icon
                    tooltip: modelData.label
                    toggled: parent.parent.mode === modelData.id
                    position: index === 0 ? "first" : index === 2 ? "last" : "middle"
                    onClicked: parent.parent.choose(modelData.id)
                }
            }
        }
    }

    /*
     * Video, which now has settings worth having.
     *
     * Sound is off by default and stays a decision you make once: a gallery
     * that makes noise when you click a thumbnail is startling in a way an
     * apology does not undo. Autoplay is on, because you opened it.
     */
    MenuToggle {
        text: "Play videos on open"
        icon: "smart_display"
        checked: Prefs.videoAutoplay
        onToggled: Prefs.videoAutoplay = !Prefs.videoAutoplay
    }

    MenuToggle {
        text: "Sound in videos"
        icon: Prefs.videoSound ? "volume_up" : "volume_off"
        checked: Prefs.videoSound
        onToggled: Prefs.videoSound = !Prefs.videoSound
    }

    MenuToggle {
        text: "Media in its own window"
        icon: "open_in_new"
        hint: "keep browsing behind it"
        checked: Prefs.mediaOwnWindow
        onToggled: Prefs.mediaOwnWindow = !Prefs.mediaOwnWindow
    }

    MenuToggle {
        // Only means anything once there is a window to fill — and a row that
        // ignores clicks must look like it will.
        enabled: Prefs.mediaOwnWindow
        opacity: enabled ? 1 : 0.45
        text: "Open it full screen"
        icon: "fullscreen"
        hint: "f toggles it"
        checked: Prefs.mediaFullscreen
        onToggled: Prefs.mediaFullscreen = !Prefs.mediaFullscreen
    }

    MenuToggle {
        text: "Animate on hover"
        icon: "gif_box"
        checked: Prefs.animateOnHover
        onToggled: Prefs.animateOnHover = !Prefs.animateOnHover
    }

    MenuToggle {
        text: "Show performance"
        icon: "speed"
        hint: "fps · memory"
        checked: Prefs.showStats
        onToggled: Prefs.showStats = !Prefs.showStats
    }

    // ── things you do, rather than set ──────────────────────────────────────

    MenuSection {
        text: "Catalogue"
    }

    MenuRow {
        text: "All settings…"
        icon: "tune"
        onTriggered: {
            root.close();
            root.settingsRequested();
        }
    }

    MenuRow {
        text: "Reload the catalogue"
        icon: "refresh"
        onTriggered: {
            root.close();
            root.reloadRequested();
        }
    }

    /*
     * The two that were wired up and unreachable.
     *
     * `paletteRequested` and `surpriseRequested` are both handled in shell.qml
     * — one types `color:<accent> dist<30 sort:random`, the other `sort:random`
     * — and nothing anywhere in the app emitted either, so two finished
     * features shipped with no way to run them. They are written into the query
     * bar like every other filter, so what they did stays visible and editable
     * afterwards.
     */
    MenuRow {
        text: "Match my colours"
        icon: "palette"
        hint: "wallpaper accent"
        onTriggered: {
            root.close();
            root.paletteRequested();
        }
    }

    MenuRow {
        text: "Surprise me"
        icon: "shuffle"
        onTriggered: {
            root.close();
            root.surpriseRequested();
        }
    }

    /*
     * The rarely-used three, behind one row.
     *
     * Restoring hidden rows, opening the cache folder and switching extensions
     * on are each done about once a month, and they were three permanent rows
     * between you and the things you change weekly.
     */
    MenuSubmenu {
        text: "More"
        icon: "more_horiz"
        minWidth: 264
        parentMenu: root

        /*
         * Rows the daemon hid on its own, given back.
         *
         * Only shown when there are some, and it says how many — an action
         * whose effect you cannot see beforehand is one nobody dares press.
         * Rows hidden on purpose are not counted here and are never touched.
         */
        MenuRow {
            text: "Restore hidden pictures"
            icon: "restore_from_trash"
            hint: Catalog.autoHiddenCount > 0 ? `${Catalog.autoHiddenCount}` : ""
            visible: Catalog.autoHiddenCount > 0
            onTriggered: {
                root.close();
                root.restoreRequested();
            }
        }

        MenuRow {
            text: "Open the cache folder"
            icon: "folder_open"
            hint: "thumbs"
            onTriggered: {
                root.close();
                root.cacheRequested();
            }
        }

    }

    /*
     * THE LENSES YOU HAVE, AND WHICH ARE ON.
     *
     * This lived in the More submenu as a list of "extensions" under a puzzle
     * icon, and the switch reported to a signal nobody had connected — so the
     * only way to turn a lens on did nothing, and a lens that ships off (every
     * one but 4chan) could not be found at all. Each row carries the lens's
     * own icon, and turning one on puts it in the rail.
     */
    MenuSection {
        text: "Lenses"
        visible: Lenses.count > 0
    }

    Repeater {
        model: Lenses.catalog

        delegate: MenuToggle {
            required property var modelData
            text: modelData.name
            icon: modelData.icon && modelData.icon.length > 0 ? modelData.icon : "lens_blur"
            checked: Lenses.isEnabled(modelData.id)
            hint: modelData.error && modelData.error.length > 0 ? "failed" : (modelData.adult === true ? "adult" : "")
            onToggled: Lenses.toggle(modelData.id)
        }
    }

    /*
     * THE SCRIPTS RUNNING HERE, WITH A SWITCH ON EACH.
     *
     * Switching a script on or off is done while looking at the thing it
     * changes — the filter and the wall it filters — and the only place to do
     * it was a settings page, which is to say: not while looking at it. The
     * list is the ones that APPLY here, the same rule the docks below use: a
     * menu that offered five 4chan scripts over the gallery would be a menu
     * nobody reads to the bottom of.
     */
    MenuSection {
        text: "Scripts"
        visible: Prefs.scriptsEnabled && Scripts.revision >= 0 && Scripts.hereScripts().length > 0
    }

    /*
     * THE SCRIPTS' OWN ACTIONS, the way a Rodded extension contributes rows to
     * the header's overflow: autoscroll puts "Start autoscroll" and its speed
     * in the menu, not a switch that says it exists.
     *
     * A row per CONTROL, not per script — a switch labelled "Autoscroll is
     * enabled" is the least interesting thing a script has to offer, and what
     * anybody actually opens this menu for is to start the thing and change
     * the one number it runs on. Managing which scripts exist is a rarer act
     * and lives one row further down.
     */
    Repeater {
        model: Prefs.scriptsEnabled && Scripts.revision >= 0 ? Scripts.menuControls() : []

        delegate: MenuToggle {
            required property var modelData

            visible: modelData.kind === "toggle"
            text: modelData.label
            icon: modelData.icon
            checked: modelData.value === true
            onToggled: Scripts.runDock(modelData.dock, modelData.id, !modelData.value)
        }

    }

    Repeater {
        model: Prefs.scriptsEnabled && Scripts.revision >= 0 ? Scripts.menuControls() : []

        delegate: MenuRow {
            required property var modelData

            visible: modelData.kind === "button"
            text: modelData.label
            icon: modelData.icon
            onTriggered: Scripts.runDock(modelData.dock, modelData.id, undefined)
        }

    }

    /*
     * A number in a menu is a Stepper, not a slider — the same control "Tile
     * size" uses six rows above this one, because a menu row is not wide
     * enough to drag along and a slider in one is a thing you miss and close
     * the menu with.
     */
    Repeater {
        model: Prefs.scriptsEnabled && Scripts.revision >= 0 ? Scripts.menuControls() : []

        delegate: Item {
            id: numberRow

            required property var modelData

            visible: modelData.kind === "slider"
            implicitWidth: parent ? parent.width : 0
            implicitHeight: visible ? 40 : 0

            StyledText {
                anchors.left: parent.left
                anchors.leftMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                text: numberRow.modelData.label
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colOnLayer1
            }

            Stepper {
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                from: Math.round(numberRow.modelData.min / numberRow.modelData.step)
                to: Math.round(numberRow.modelData.max / numberRow.modelData.step)
                value: Math.round((Number(numberRow.modelData.value) || 0) / numberRow.modelData.step)
                display: `${Math.round(Number(numberRow.modelData.value) || 0)}${numberRow.modelData.unit.length > 0 ? ` ${numberRow.modelData.unit}` : ""}`
                onChanged_: (v) => {
                    return Scripts.runDock(numberRow.modelData.dock, numberRow.modelData.id, v * numberRow.modelData.step);
                }
            }

        }

    }

    /*
     * Which scripts exist at all, behind one row — the same treatment the
     * rarely-used catalogue actions get. Switching a script off is a monthly
     * act; starting the one that is already installed is a daily one.
     */
    MenuSubmenu {
        id: scriptMenu

        readonly property var here: Prefs.scriptsEnabled && Scripts.revision >= 0 ? Scripts.hereScripts() : []

        text: "Scripts here"
        icon: "code"
        hint: {
            const on = scriptMenu.here.filter(s => s.enabled).length;
            return `${on} of ${scriptMenu.here.length} on`;
        }
        visible: scriptMenu.here.length > 0
        minWidth: 300
        parentMenu: root

        Repeater {
            model: scriptMenu.here

            delegate: MenuToggle {
                required property var modelData

                text: modelData.name
                icon: modelData.error.length > 0 ? "error" : "code"
                hint: {
                    if (modelData.error.length > 0)
                        return "failed";

                    const dock = Scripts.docks().find(d => d.id === modelData.id);
                    if (dock)
                        return Scripts.dockShowing(dock.id) ? "dock showing" : "has a dock";

                    return "";
                }
                checked: modelData.enabled
                onToggled: Scripts.setEnabled(modelData.id, !modelData.enabled)
            }

        }

    }

    /*
     * WHAT THE SCRIPTS YOU HAVE ON OFFER HERE.
     *
     * A script used to be keys and nothing else — autoscroll's nine speeds
     * were discoverable only by opening the file. A script that declares a
     * dock gets a row here, and only when it applies where you are standing:
     * the 4chan ones do not belong in this menu while you are in the gallery,
     * which is the whole reason the list is filtered rather than listed.
     */
    MenuSubmenu {
        id: dockMenu

        readonly property var offered: Scripts.revision >= 0 ? Scripts.docks().filter(d => Scripts.appliesHere(d.match)) : []

        text: "Docks"
        icon: "dashboard"
        hint: {
            const on = dockMenu.offered.filter(d => Scripts.dockShowing(d.id)).length;
            return on > 0 ? `${on} showing` : (dockMenu.offered.length > 0 ? `${dockMenu.offered.length} here` : "none here");
        }
        visible: Prefs.scriptsEnabled && dockMenu.offered.length > 0
        minWidth: 280
        parentMenu: root

        Repeater {
            model: dockMenu.offered

            delegate: MenuRow {
                required property var modelData

                text: modelData.title
                icon: modelData.icon
                hint: Scripts.scopeLabel(modelData.match)
                checked: Scripts.dockShowing(modelData.id)
                onTriggered: Scripts.setDockShowing(modelData.id, !Scripts.dockShowing(modelData.id))
            }

        }

    }

    // ── the daemon, stated rather than guessed at ───────────────────────────

    MenuRow {
        text: Client.connected ? `Daemon · ${Client.backend}` : "Daemon offline"
        icon: Client.connected ? "check_circle" : "error"
        hint: Client.connected ? `${Catalog.count}` : "retrying"
        enabled: false
    }
}
