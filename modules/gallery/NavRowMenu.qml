import qs.modules.common
import qs.modules.widgets
import QtQuick

/*
 * WHAT CAN BE DONE TO ONE ROW OF THE RAIL.
 *
 * The rail's lower half belongs to whichever lens is open — a subreddit, a
 * chat, a board — and the app has no idea what any of them are. So the rows
 * come from the lens and so does this menu: `navMenu(id)` answers with what
 * that row can do, and a lens that offers nothing gets no menu at all rather
 * than an empty box.
 *
 * Deliberately flat and short. A rail row has one or two obvious verbs —
 * remove it, forget it, open it somewhere — and a submenu on a right-click is
 * a menu you have to aim at twice.
 */
MenuPopup {
    id: root

    /// `[{ label, icon, hint, destructive, action }]`, straight from the lens.
    property var rows: []

    minWidth: 220

    function popupAt(x, y) {
        root.x = Math.max(8, Math.min(x, root.parent.width - root.implicitWidth - 8));
        root.y = Math.max(8, Math.min(y, root.parent.height - root.implicitHeight - 8));
        root.open();
    }

    Repeater {
        model: root.rows

        delegate: MenuRow {
            required property var modelData

            text: modelData.label || ""
            icon: modelData.icon || "chevron_right"
            hint: modelData.hint || ""
            // MenuRow already knows how to look dangerous — same treatment as
            // every other destructive row in the app.
            destructive: modelData.destructive === true
            onTriggered: {
                root.close();
                if (typeof modelData.action === "function")
                    modelData.action();
            }
        }

    }

}
