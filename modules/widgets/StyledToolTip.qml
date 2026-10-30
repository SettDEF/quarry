import qs.modules.common
import QtQuick
import QtQuick.Window

/*
 * Hover tooltip. Themed like the rest of the UI (elevated dark surface)
 * rather than Material's light inverse-surface pill, matching the shell.
 *
 * Drop it inside the item it describes and bind `visible` to that item's
 * hover state; positioning and the delay are handled here.
 */
Item {
    id: root

    property string text: ""
    property int delay: 450
    property int side: Qt.BottomEdge

    // `visible` is the caller's hover condition; the popup fades in after the
    // delay so brushing past a control doesn't flash a tooltip.
    property bool shown: false

    anchors.fill: parent

    onVisibleChanged: {
        if (visible)
            showTimer.restart();
        else {
            showTimer.stop();
            root.shown = false;
        }
    }

    Timer {
        id: showTimer
        interval: root.delay
        onTriggered: {
            if (bubble.parent) bubble.origin = root.mapToItem(bubble.parent, 0, 0);
            root.shown = root.visible;
        }
    }

    Rectangle {
        id: bubble
        parent: root.Window.window ? root.Window.window.contentItem : root
        z: 10000
        visible: root.shown && root.text.length > 0
        opacity: visible ? 1 : 0
        // A label, not a menu: an outlined box the size of a menu row reads as
        // something you can click, and one appeared under every hover.
        radius: height / 2
        color: Appearance.colors.colTooltip
        border.width: 0

        implicitWidth: tipLabel.implicitWidth + 18
        implicitHeight: tipLabel.implicitHeight + 8

        // Anchor to the owner in window coordinates, clamped inside the window.
        // `parent` goes null while the owner is being torn down, and these
        // bindings get one last evaluation on the way out.
        readonly property real hostWidth: parent ? parent.width : 0
        readonly property real hostHeight: parent ? parent.height : 0
        // where the owner sits, taken each time the tip appears: mapToItem is not a binding
        // that follows layout, so worked out once it stays where the owner was at creation (0, 0)
        property point origin: Qt.point(0, 0)
        // Beside the item for a rail or a toolbar edge, where below would be
        // clipped by the window or drawn over the thing it describes.
        x: {
            const centred = origin.x + (root.width - width) / 2;
            const placed = root.side === Qt.RightEdge ? origin.x + root.width + 8
                : root.side === Qt.LeftEdge ? origin.x - width - 8 : centred;
            return Math.max(6, Math.min(hostWidth - width - 6, placed));
        }
        y: {
            const placed = root.side === Qt.TopEdge ? origin.y - height - 8
                : (root.side === Qt.RightEdge || root.side === Qt.LeftEdge) ? origin.y + (root.height - height) / 2
                : origin.y + root.height + 8;
            return Math.max(6, Math.min(hostHeight - height - 6, placed));
        }

        Behavior on opacity {
            NumberAnimation {
                duration: Appearance.animation.elementMoveFast.duration
            }
        }

        StyledText {
            id: tipLabel
            anchors.centerIn: parent
            text: root.text
            font.pixelSize: Appearance.font.pixelSize.smallest
            color: Appearance.colors.colOnTooltip
        }
    }
}
