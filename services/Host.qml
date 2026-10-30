pragma Singleton
import QtQuick
import qs.modules.common
import qs.services

/*
 * What an extension is allowed to touch.
 *
 * Extensions never reach into views: delegates are recycled and layouts swap at
 * runtime, so anything holding a reference to one breaks the first time you
 * scroll. They register *contributions* here instead, and the app reads them.
 *
 * Ported from Rodded, minus its feed and video machinery, plus the two things
 * quarry has that it did not: targets and query predicates.
 */
QtObject {
    id: root

    // ── contributions ────────────────────────────────────────────────────────

    /// Extra export targets: same shape as the built-ins in Targets.qml.
    property var targets: []

    /*
     * Extra layouts: { id, label, icon, hint, component }.
     *
     * `component` is drawn where the gallery's own layouts draw, filling the
     * picture area, and is picked by `Prefs.layoutMode === id` like any other.
     * It reads the result from `Catalog` and acts through the three verbs
     * below — never by reaching into a view, because the view it reached into
     * is swapped the moment somebody changes layout.
     */
    property var layouts: []

    /*
     * WHAT A CONTRIBUTED LAYOUT IS ALLOWED TO DO TO AN ITEM.
     *
     * Installed by the shell, which owns the viewer, the menu and the export
     * sheet. Null until it is — so a layout checks before calling, and a lens
     * or extension loaded in some other host degrades instead of throwing.
     */
    property var openItem: null      // (index, record) → show it full-screen
    property var itemMenu: null      // (record, sceneX, sceneY) → the item menu
    property var exportItem: null    // (record) → export to the usual target

    function open(index, record) {
        if (root.openItem)
            root.openItem(index, record);
    }

    function menu(record, sceneX, sceneY) {
        return root.itemMenu ? root.itemMenu(record, sceneX, sceneY) : false;
    }

    function exportOne(record) {
        return root.exportItem ? root.exportItem(record) : false;
    }

    /// Named actions an extension exposes, for menus and shortcuts:
    /// { id, label, icon, run }.
    property var actions: []

    signal contributionsChanged

    function registerTarget(target) {
        if (!target || !target.id)
            return;
        root.targets = root.targets.filter(t => t.id !== target.id).concat([target]);
        root.contributionsChanged();
    }

    function unregisterTarget(id) {
        root.targets = root.targets.filter(t => t.id !== id);
        root.contributionsChanged();
    }

    function registerLayout(layout) {
        if (!layout || !layout.id)
            return;
        root.layouts = root.layouts.filter(l => l.id !== layout.id).concat([layout]);
        root.contributionsChanged();
    }

    function unregisterLayout(id) {
        root.layouts = root.layouts.filter(l => l.id !== id);
        root.contributionsChanged();
    }

    /*
     * A DOCK, the strip of controls that floats over the pictures.
     *
     * Scripts have had these for a while and extensions have not, which was an
     * accident of order rather than a decision: an extension that adds a way of
     * looking at things usually wants a control or two for it while you are
     * looking, and until now its only options were a menu item or a keybind.
     *
     * Same shape a script declares, because it is the same list underneath:
     *
     *     Host.registerDock("my-extension", {
     *         title: "Compare", icon: "compare", overViewer: true,
     *         items: [{ id: "lock", kind: "toggle", label: "Lock",
     *                   value: false, on: on => { ... } }]
     *     })
     *
     * Registered on enable and dropped on disable, like every other
     * contribution here — see `unregisterDock`.
     */
    function registerDock(id, dock) {
        Scripts.registerDock(id, dock);
        root.contributionsChanged();
    }

    function unregisterDock(id) {
        Scripts.unregisterDock(id);
        root.contributionsChanged();
    }

    function registerAction(action) {
        if (!action || !action.id)
            return;
        root.actions = root.actions.filter(a => a.id !== action.id).concat([action]);
        root.contributionsChanged();
    }

    function unregisterAction(id) {
        root.actions = root.actions.filter(a => a.id !== id);
        root.contributionsChanged();
    }

    function runAction(id) {
        const action = root.actions.find(a => a.id === id);
        if (action && action.run)
            action.run();
    }

    // ── what the app lends them ──────────────────────────────────────────────

    /*
     * THE SURFACE YOU ARE LOOKING AT, said rather than guessed.
     *
     * Every layout and every lens skin claims this as it comes on screen. It
     * exists because the alternative is a tree walk that picks the biggest
     * scrollable it can find — which ran once a frame, could not tell a
     * sidebar from the thing beside it, and had to be taught about the viewer
     * and about lenses one special case at a time.
     *
     * A STACK, not a slot. The viewer opens over a wall that is still visible
     * and claims the surface, which is right; closing it has to hand the wall
     * back, and the wall's `visible` never changed, so it has no moment to
     * claim again. So claims are kept in order and the newest one that is
     * still on screen wins.
     */
    property var activeFlickable: null
    property var activeOwner: null

    signal viewChanged

    property var _claims: []

    function claimView(flickable, owner) {
        if (!owner)
            return;
        root._claims = root._claims.filter(c => c.owner !== owner).concat([{
            "flickable": flickable,
            "owner": owner
        }]);
        root._settleView();
    }

    function releaseView(owner) {
        const next = root._claims.filter(c => c.owner !== owner);
        if (next.length === root._claims.length)
            return;
        root._claims = next;
        root._settleView();
    }

    function _settleView() {
        for (let i = root._claims.length - 1; i >= 0; i--) {
            const claim = root._claims[i];
            let usable = false;
            try {
                // A view torn down without releasing leaves a dead reference.
                usable = !!claim.flickable && claim.flickable.visible !== false;
            } catch (e) {
                usable = false;
            }
            if (!usable)
                continue;
            if (root.activeFlickable === claim.flickable && root.activeOwner === claim.owner)
                return;
            root.activeFlickable = claim.flickable;
            root.activeOwner = claim.owner;
            root.viewChanged();
            return;
        }
        if (root.activeFlickable === null && root.activeOwner === null)
            return;
        root.activeFlickable = null;
        root.activeOwner = null;
        root.viewChanged();
    }

    /// Chrome hidden for an immersive mode.
    property bool chromeSuppressed: false
    /// Space an overlay has taken at the bottom, so a view can keep its last row
    /// reachable.
    property real bottomInset: 0
}
