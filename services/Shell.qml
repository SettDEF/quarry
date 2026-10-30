pragma Singleton
import QtQuick
import Quickshell

/*
 * The window, reachable from anywhere.
 *
 * IPC and the launcher both need to raise the app, and neither can reach into
 * the component tree to find it — so the window registers itself here on
 * creation and everything else asks this.
 */
Singleton {
    id: root

    property var window: null
    property var detail: null
    /// The viewer's own window, when media opens outside the main one.
    property var mediaWindow: null
    /// Whether the viewer is up. Tiles read it to stop playing behind it — a
    /// clip decoding under a modal is work nobody can see.
    readonly property bool detailOpen: !!root.detail && root.detail.open === true
    /// The filter panel, so a terminal can open it and see what it holds —
    /// which is how the "opens as an empty box" bug is checked rather than
    /// described.
    property var filterPanel: null
    /// The kept record of searches, opens and exports.
    property var historyPanel: null
    /// The settings panel, so a terminal can open it and say what it holds.
    property var settingsPanel: null

    /*
     * IS THE POINTER ON A PICTURE — the one fact autoscroll cannot see.
     *
     * A script is handed `view`, `keys` and its own storage; it is never handed
     * the pointer, and that is deliberate. But "stop moving while I am looking
     * at this one" is the most reasonable thing to ask of a wall that scrolls
     * itself, so the host has to answer it.
     *
     * A COUNT rather than a flag: tiles overlap at their edges and recycle
     * under the pointer, so two can be hovered for a frame while the handover
     * happens. A flag written by both of them ends up false with the pointer
     * still on a picture, which reads as the pause randomly not working.
     */
    property int hoveredTiles: 0

    /*
     * WHERE THE POINTER SITS DOWN THE SCREEN, 0 at the top and 1 at the bottom.
     *
     * For "mouse Y influence": a self-scrolling wall that runs at one rate is
     * either too fast to read or too slow to get anywhere, and the control
     * nobody has to learn is the pointer itself — keep it low and the wall
     * hurries, raise it and the wall slows to let you read. −1 means the
     * pointer is not over the wall at all, which is not the same as the top.
     */
    property real pointerFrac: -1
    readonly property bool overPicture: root.hoveredTiles > 0
    /// The window-edge scrollbar and the search bar, so a terminal can ask how
    /// big they actually are. Both have shipped correct-but-invisible.
    property var scrollBar: null
    property var queryBar: null
    property var exportSheet: null
    /// The active gallery view, for `perf geometry` — a blank grid with no
    /// errors is the one failure the counters cannot describe.
    property var gallery: null
    // The window's content item, so it can capture itself (`app shot`).
    property var content: null
    // The menus, so they can be opened and looked at over IPC (`app menu`).
    property var overlay: null
    property var itemMenu: null
    property var layoutMenu: null
    /// The rail's right-click menu, and the builder for the app's own rows —
    /// registered so `app railMenu` can exercise exactly the path a pointer
    /// takes. A popup cannot be seen in a window grab, so without this the only
    /// way to check a rail menu is to click it.
    property var navRowMenu: null
    property var railMenuFor: null
    property var settingsMenu: null
    /// The in-app browser, so IPC can open a page in it and the settings
    /// section can clear what it stored.
    property var browser: null
    readonly property bool browserOpen: !!root.browser && root.browser.open === true

    /*
     * Show the window.
     *
     * quickshell's FloatingWindow has no `raise()` or `requestActivate()` —
     * calling them throws — so mapping it is all this can do, and raising an
     * already-visible window is left to the compositor, which is the one that
     * owns stacking anyway. A launcher action on a running instance therefore
     * changes the query and leaves the window where it is.
     */
    function present() {
        if (!root.window)
            return false;
        root.window.visible = true;
        return true;
    }

    function toggle() {
        if (!root.window)
            return false;
        if (root.window.visible) {
            root.window.visible = false;
            return false;
        }
        return root.present();
    }
}
