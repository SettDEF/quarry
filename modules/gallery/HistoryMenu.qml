import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick

/*
 * Where you have been — a browser's long-press on Back.
 *
 * Newest first: forward steps on top (greyed like a browser's), the page you
 * are on marked with a check, and the way back below it. Choosing one jumps
 * straight there; the steps skipped over stay reachable in both directions.
 */
MenuPopup {
    id: root

    minWidth: 280

    function popupAt(x, y) {
        root.x = Math.max(8, Math.min(x, root.parent.width - root.implicitWidth - 8));
        root.y = y;
        root.visible ? root.close() : root.open();
    }

    function iconFor(step) {
        if (step.similar)
            return "image_search";
        return step.query && step.query.length > 0 ? "search" : "auto_awesome_mosaic";
    }

    // Forward: the furthest first, so the list reads top to bottom as time.
    Repeater {
        model: root.visible ? Catalog.future.length : 0
        delegate: MenuRow {
            required property int index
            readonly property var step: Catalog.future[index]
            text: Catalog.describeStep(step)
            icon: root.iconFor(step)
            hint: index === Catalog.future.length - 1 ? "Alt →" : ""
            opacity: 0.7
            onTriggered: {
                Catalog.forward(Catalog.future.length - index);
                root.close();
            }
        }
    }

    MenuRow {
        text: Catalog.describeStep({ "query": Catalog.query, "similar": Catalog.similarTo })
        icon: root.iconFor({ "query": Catalog.query, "similar": Catalog.similarTo })
        checked: true
        hint: "here"
        onTriggered: root.close()
    }

    Repeater {
        model: root.visible ? Catalog.history.length : 0
        delegate: MenuRow {
            required property int index
            // Newest first.
            readonly property int at: Catalog.history.length - 1 - index
            readonly property var step: Catalog.history[at]
            text: Catalog.describeStep(step)
            icon: root.iconFor(step)
            hint: index === 0 ? "Alt ←" : ""
            onTriggered: {
                Catalog.back(index + 1);
                root.close();
            }
        }
    }

    MenuRow {
        separator: true
    }
    MenuRow {
        visible: Catalog.canGoBack || Catalog.canGoForward
        text: "Clear history"
        icon: "history_toggle_off"
        onTriggered: {
            Catalog.history = [];
            Catalog.future = [];
            root.close();
        }
    }
    MenuRow {
        text: Prefs.railExpanded ? "Collapse sidebar" : "Expand sidebar"
        icon: Prefs.railExpanded ? "left_panel_close" : "left_panel_open"
        onTriggered: {
            Prefs.railExpanded = !Prefs.railExpanded;
            root.close();
        }
    }
}
