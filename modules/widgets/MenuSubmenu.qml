import qs.modules.common
import QtQuick
import QtQuick.Controls
import QtQuick.Window
import QtQuick.Layouts

/*
 * A MENU ROW THAT OPENS A MENU.
 *
 * The item menu listed every recent export target at the top level -- "Export ·
 * Steam avatar", "Export · Wallpaper · eDP-1 (3072×1920)" -- so the two rows
 * you use most were also the two longest strings in the menu, and they pushed
 * the menu wide enough to matter. They collapse to one "Export" row now, and
 * the targets live behind it.
 *
 * It CASCADES ON HOVER, which is not decoration: the parent menu closes on a
 * press outside itself, and a flyout is outside itself. Opening on hover means
 * the pointer must leave this row to reach anything else -- which closes the
 * flyout first, and restores the parent's close policy before the press lands.
 * A click-to-open submenu would eat that press and the whole menu would vanish
 * as you reached for it.
 */
Item {
    id: root

    property string text: ""
    property string icon: ""
    property string hint: ""
    /// Passed to the flyout, so a submenu of long labels is not forced to the
    /// parent's width and a submenu of short ones does not stretch to it.
    property real minWidth: 210

    /*
     * WHETHER A TAP OPENS THE FLYOUT OR DOES THE ROW'S OWN JOB.
     *
     * "Export" is only a way in, so tapping it opens the submenu. "In context"
     * is a layout you can switch to that also HAS settings, so tapping it must
     * switch layout and the submenu belongs to hover alone -- otherwise the
     * one row people press most stops doing the thing it says.
     */
    property bool tapOpens: true
    /// Shown checked regardless of whether the flyout is up.
    property bool checked: false

    signal triggered

    default property alias submenuContent: flyout.menuContent

    /// The menu this row belongs to. Its close-on-press-outside has to stand
    /// down while the flyout is up, or moving the pointer into the flyout --
    /// which is outside the parent -- would dismiss everything.
    property var parentMenu: null

    readonly property bool showing: flyout.visible

    Layout.fillWidth: true
    implicitWidth: row.implicitWidth
    implicitHeight: row.implicitHeight

    MenuRow {
        id: row
        anchors.fill: parent
        text: root.text
        icon: root.icon
        hint: root.hint
        hasSubmenu: true
        // Keep it lit while the flyout is up, so the trail from the row to the
        // submenu is unbroken even once the pointer has left the row.
        checked: root.checked || root.showing
        onTriggered: {
            if (!root.tapOpens) {
                root.triggered();
                return;
            }
            // A tap is a second way in for anyone who does not wait on hover.
            root.showing ? root.hide() : root.show();
        }
    }

    HoverHandler {
        id: rowHover
        onHoveredChanged: {
            if (hovered)
                openDelay.restart();
            else
                closeDelay.restart();
        }
    }

    // Short enough to feel immediate, long enough that dragging the pointer
    // down the menu past this row does not flash a submenu on the way.
    Timer {
        id: openDelay
        interval: 180
        onTriggered: {
            if (rowHover.hovered)
                root.show();
        }
    }

    /*
     * The gap between the row and the flyout is real: they are separate popups
     * with a few pixels between them, and the pointer crosses unhovered space
     * on the way over. Closing instantly would make the submenu impossible to
     * reach with anything but a perfectly straight line.
     */
    Timer {
        id: closeDelay
        interval: 260
        onTriggered: {
            if (!rowHover.hovered && !flyout.surfaceHovered)
                root.hide();
        }
    }

    function show() {
        openDelay.stop();
        root.reposition();
        if (root.parentMenu)
            root.parentMenu.closePolicy = Popup.CloseOnEscape;
        flyout.open();
    }

    function hide() {
        closeDelay.stop();
        flyout.close();
    }

    /*
     * Placed by hand, once, on open -- NOT by a binding on mapToItem().
     *
     * mapToItem reads geometry without depending on it, so a binding written
     * that way is evaluated during the first layout and then never again. That
     * is exactly how the completions dropdown ended up 900px from its field.
     */
    function reposition() {
        const win = root.Window.window;
        if (!win)
            return;
        const here = root.mapToItem(null, 0, 0);
        const w = flyout.implicitWidth;
        const h = flyout.implicitHeight;

        // Prefer the right, flip to the left when there is no room -- a menu
        // opened near the screen edge is the normal case, not the exception.
        const roomRight = win.width - (here.x + root.width) - 8;
        flyout.x = roomRight >= w ? root.width + 4 : -w - 4;

        // Lifted so the first submenu row lines up with this one, then pulled
        // back on-screen if that would run it off the bottom.
        const wantY = here.y - 6;
        const maxY = win.height - h - 8;
        flyout.y = (wantY > maxY ? maxY : wantY) - here.y;
    }

    Connections {
        target: root.Window.window
        function onWidthChanged() {
            if (root.showing)
                root.reposition();
        }
        function onHeightChanged() {
            if (root.showing)
                root.reposition();
        }
    }

    MenuPopup {
        id: flyout
        parent: root
        minWidth: root.minWidth
        // The parent already dims everything under it; a second scrim would
        // darken the menu this flyout belongs to.
        closePolicy: Popup.CloseOnEscape

        onSurfaceHoveredChanged: {
            if (surfaceHovered)
                closeDelay.stop();
            else
                closeDelay.restart();
        }

        onClosed: {
            // Hand the parent its dismissal back, or the next click anywhere
            // outside would be swallowed and the menu would sit there.
            if (root.parentMenu)
                root.parentMenu.closePolicy = Popup.CloseOnEscape | Popup.CloseOnPressOutside;
        }
    }
}
