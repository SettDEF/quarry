import QtQuick
import qs.modules.common
import qs.modules.widgets

/*
 * AUTOSCROLL — the feed reads itself.
 *
 * Moves `flickable` at `lens.autoSpeed` px/s, a little every frame (so it is
 * smooth, not stepped). It gets out of the way:
 *   - you scroll yourself  → it waits 1.5 s, then carries on from there
 *   - you move the pointer over the feed → it waits until you stop
 *   - a video reaches the middle (Cards) → it waits while it plays
 *     (`lens.dwellUntil`, set by the card)
 *   - you open a post, or switch to the theater → it stops (the lens does
 *     that: `screen` leaving "feed" switches it off)
 * Near the end it asks for the next page; at the very end it stops.
 */
Item {
    id: root
    required property var lens
    property Flickable flickable: null
    anchors.fill: parent

    property real expected: -1          // where we put contentY last frame
    property double waitUntil: 0        // user scroll / pointer pause
    property double now: 0
    readonly property bool dwelling: root.now < root.lens.dwellUntil
    readonly property bool waiting: root.now < root.waitUntil
    property bool held: false           // the dock's pause

    FrameAnimation {
        running: root.lens.autoscroll && root.visible && !!root.flickable
        onTriggered: {
            root.now = Date.now();
            const f = root.flickable;
            // somebody else moved it: that was you — wait, then go on from there
            if (root.expected >= 0 && Math.abs(f.contentY - root.expected) > 2) root.waitUntil = root.now + 1500;
            root.expected = f.contentY;
            if (root.held || root.waiting || root.dwelling || f.moving) return;
            const end = f.originY + Math.max(0, f.contentHeight - f.height);
            if (end - f.contentY < f.height * 1.5) root.lens.more();
            if (f.contentY >= end - 0.5) {
                if (!root.lens.loading && !root.lens.hasMore) root.lens.autoscroll = false;
                return;
            }
            f.contentY = Math.min(end, f.contentY + root.lens.autoSpeed * frameTime);
            root.expected = f.contentY;
        }
        onRunningChanged: { root.expected = -1; root.held = false; }
    }

    // the pointer moving over the feed means "let me look"
    HoverHandler {
        enabled: root.lens.autoscroll
        onPointChanged: root.waitUntil = Date.now() + 900
    }

    // ── the dock ──
    Rectangle {
        visible: root.lens.autoscroll
        anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 16 }
        implicitWidth: dock.implicitWidth + 16; implicitHeight: 44; radius: 22
        color: Appearance.colors.colLayer2
        border.width: 1; border.color: Appearance.colors.colOutlineVariant
        Row {
            id: dock
            anchors.centerIn: parent
            spacing: 2
            IconButton {
                size: 34
                icon: root.held ? "play_arrow" : "pause"
                tooltip: root.held ? "Go on" : "Hold"
                onClicked: root.held = !root.held
            }
            IconButton { size: 34; icon: "remove"; tooltip: "Slower"; onClicked: root.lens.autoSpeed = Math.max(15, Math.round(root.lens.autoSpeed / 1.25)) }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                width: 64
                horizontalAlignment: Text.AlignHCenter
                text: root.dwelling ? "video…" : root.waiting ? "waiting" : `${Math.round(root.lens.autoSpeed)} px/s`
                font.family: Appearance.font.family.monospace
                font.pixelSize: Appearance.font.pixelSize.smallest
                color: Appearance.colors.colOnLayer2
            }
            IconButton { size: 34; icon: "add"; tooltip: "Faster"; onClicked: root.lens.autoSpeed = Math.min(600, Math.round(root.lens.autoSpeed * 1.25)) }
            IconButton { size: 34; icon: "close"; tooltip: "Stop autoscroll (A)"; onClicked: root.lens.autoscroll = false }
        }
    }
}
