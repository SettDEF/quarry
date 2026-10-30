import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick

/*
 * The right-click menu for a picture ON a board.
 *
 * Deliberately not `ItemContextMenu`: that menu's job is "I have found this,
 * what do I do with it" — export, copy the URL, find similar. A picture that is
 * already on a board has been chosen, and what you want from it there is
 * arrangement: order it, flip it, sharpen it, take it off.
 */
MenuPopup {
    id: root

    property var item: null
    property var canvas: null

    /*
     * The same menu serves a picture and a container.
     *
     * They are opened from the same right click on the same surface and share
     * most of what you would want — bring it forward, take it away — so two
     * near-identical menus would be two places to keep the same list correct.
     * `container` non-null switches which rows apply.
     */
    property var container: null

    minWidth: 236

    function openFor(item, sceneX, sceneY) {
        root.container = null;
        root.item = item;
        const local = root.parent.mapFromItem(null, sceneX, sceneY);
        root.x = Math.max(8, Math.min(local.x, root.parent.width - root.implicitWidth - 8));
        root.y = Math.max(8, Math.min(local.y, root.parent.height - root.implicitHeight - 8));
        root.open();
    }

    function openForContainer(entry, sceneX, sceneY) {
        root.item = null;
        root.container = entry;
        const local = root.parent.mapFromItem(null, sceneX, sceneY);
        root.x = Math.max(8, Math.min(local.x, root.parent.width - root.implicitWidth - 8));
        root.y = Math.max(8, Math.min(local.y, root.parent.height - root.implicitHeight - 8));
        root.open();
    }

    MenuRow {
        visible: !root.container
        text: "Fill the view with it"
        icon: "zoom_in"
        hint: "double-click"
        onTriggered: {
            root.close();
            if (root.canvas)
                root.canvas.fitTo(root.item);
        }
    }

    MenuRow {
        separator: true
    }

    MenuRow {
        visible: !root.container
        text: "Flip across"
        icon: "flip"
        hint: "H"
        onTriggered: {
            root.close();
            if (root.canvas)
                root.canvas.eachSelected(p => p.flip(true));
        }
    }

    MenuRow {
        visible: !root.container
        text: "Flip over"
        icon: "flip"
        hint: "V"
        onTriggered: {
            root.close();
            if (root.canvas)
                root.canvas.eachSelected(p => p.flip(false));
        }
    }

    MenuRow {
        visible: !root.container
        text: "Turn a quarter"
        icon: "rotate_right"
        hint: "R"
        onTriggered: {
            root.close();
            if (root.canvas)
                root.canvas.eachSelected(p => p.rotateBy(90));
        }
    }

    MenuRow {
        visible: !root.container
        text: "Straighten"
        icon: "straighten"
        onTriggered: {
            root.close();
            if (root.canvas)
                root.canvas.eachSelected(p => {
                    p.angle_ = 0;
                    p.commit();
                });
        }
    }

    MenuRow {
        separator: true
    }

    /*
     * Nearest-neighbour, for pixel art.
     *
     * The one per-image render setting RIA got right and the only one worth
     * keeping: smoothing a 64px sprite scaled up eight times destroys exactly
     * what you put it on the board to look at.
     */
    MenuRow {
        visible: !root.container
        text: "Keep the pixels hard"
        icon: "grain"
        onTriggered: {
            root.close();
            if (root.canvas)
                root.canvas.eachSelected(p => {
                    p.sharp = !p.sharp;
                    p.commit();
                });
        }
    }

    MenuRow {
        separator: true
    }

    MenuRow {
        visible: !root.container
        text: "Take it off the board"
        icon: "close"
        hint: "Del"
        destructive: true
        onTriggered: {
            root.close();
            if (root.canvas)
                root.canvas.removeSelected();
        }
    }

    // ── a container ─────────────────────────────────────────────────────────

    MenuRow {
        visible: !!root.container
        text: "Rename this group…"
        icon: "edit"
        onTriggered: {
            root.close();
            root.renameContainer(root.container);
        }
    }

    MenuRow {
        visible: !!root.container
        separator: true
    }

    /*
     * "Ungroup", not "delete": the pictures stay.
     *
     * A container says these belong together, and changing your mind about
     * that must not cost you the pictures — so the row says what actually
     * happens rather than borrowing the word for throwing things away.
     */
    MenuRow {
        visible: !!root.container
        text: "Ungroup — the pictures stay"
        icon: "layers_clear"
        onTriggered: {
            root.close();
            Catalog.deleteContainer(root.container.id);
        }
    }

    signal renameContainer(var entry)
}
