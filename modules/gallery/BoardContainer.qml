import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick

/*
 * A CONTAINER — pictures that belong together, said out loud.
 *
 * A board answers how things sit next to each other, and past a dozen pictures
 * the answer is usually "in groups": three for the palette, four for the pose,
 * two for the light. Without somewhere to say that, the grouping exists only in
 * how close things happen to be, and the first time you move anything it is
 * gone.
 *
 * Drawn UNDER the pictures and dragged by its header, so it is a surface they
 * sit on rather than a box drawn over them. Moving it takes its contents along;
 * that is the whole point of having one.
 *
 * Membership is decided by where a picture ENDS UP, not by a mode you enter:
 * drop something inside the outline and it belongs, drag it out and it does
 * not. Anything else means teaching people a verb before they can group two
 * pictures.
 */
Item {
    id: root

    required property var board
    required property var entry

    signal movedBy(real dx, real dy)
    signal committed
    signal menuRequested(var entry, real sceneX, real sceneY)

    property real bx: entry.x
    property real by: entry.y
    property real bw: entry.w
    property real bh: entry.h

    readonly property bool chosen: root.board.chosenContainer === root.entry.id

    /// How many pictures are recorded as belonging to this one.
    readonly property int count: {
        let n = 0;
        for (let i = 0; i < Catalog.boardItems.length; i++)
            if (Catalog.boardItems[i].container === root.entry.id)
                n++;
        return n;
    }

    // Board coordinates — the canvas carries the view. See `content` in
    // GalleryBoard.
    x: root.bx
    y: root.by
    width: root.bw
    height: root.bh

    /*
     * A container is part of the BOARD, not part of the pictures.
     *
     * So it fades with the ground: turning the board see-through to work over
     * your canvas should take the outlines with it, or the pictures end up
     * floating inside boxes drawn on nothing — the one solid thing left in a
     * window you deliberately made transparent.
     */
    opacity: Prefs.boardGround

    function nudge(dx, dy) {
        root.bx += dx;
        root.by += dy;
    }

    function commit() {
        Catalog.placeContainer({
            "id": root.entry.id,
            "x": root.bx,
            "y": root.by,
            "w": root.bw,
            "h": root.bh,
            "label": root.entry.label
        });
    }

    Rectangle {
        anchors.fill: parent
        radius: Appearance.rounding.normal
        // A tint rather than a fill: whatever is behind the board — the desktop,
        // when the board is transparent — has to stay visible through it, or a
        // container would be a hole in the see-through window.
        color: ColorUtils.transparentize(Appearance.colors.colLayer1, root.chosen ? 0.72 : 0.86)
        // Screen-pixel hairlines whatever the zoom is.
        border.width: (root.chosen ? 2 : 1) / root.board.zoom
        border.color: root.chosen
            ? Appearance.colors.colPrimary
            : Appearance.colors.colOutlineVariant

        Behavior on color {
            animation: Appearance.animation.stateChange.colorAnimation.createObject(root)
        }
    }

    // The header is the handle. A container you can drag from anywhere would
    // swallow every click meant for the pictures sitting on it.
    Item {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        // A constant height on SCREEN: a header that scaled with the board
        // would be unreadable zoomed out and a banner zoomed in, and it is the
        // only handle the container has.
        height: Math.min(34 / root.board.zoom, root.height)

        Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 12 / root.board.zoom
            spacing: 8 / root.board.zoom

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: root.entry.label.length > 0 ? root.entry.label : "Untitled"
                elide: Text.ElideRight
                font.pixelSize: Appearance.font.pixelSize.smaller / root.board.zoom
                font.weight: Font.DemiBold
                color: root.chosen
                    ? Appearance.colors.colPrimary
                    : Appearance.colors.colSubtext
            }

            /*
             * WHAT IS ACTUALLY IN IT.
             *
             * A container with an outline and a name says where it is, not what
             * it holds — and the two differ the moment you drag something in or
             * out, which is exactly when you want to know. Counting the
             * membership the daemon recorded means this cannot drift from the
             * truth the way a number kept by hand would.
             */
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: root.count === 0 ? "empty" : `${root.count}`
                font.family: Appearance.font.family.monospace
                font.pixelSize: Appearance.font.pixelSize.smallest / root.board.zoom
                color: Appearance.colors.colSubtext
                opacity: root.count === 0 ? 0.7 : 1
            }
        }

        MouseArea {
            id: handle
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton

            property real lastX: 0
            property real lastY: 0
            property real startX: 0
            property real startY: 0
            property bool moved: false
            property bool dragging: false
            property bool fromTouch: false

            // Ours, not Qt's — see the note in BoardPiece.
            Timer {
                id: hold
                interval: 500
                onTriggered: {
                    if (handle.moved || !handle.fromTouch)
                        return;
                    handle.dragging = false;
                    root.menuRequested(root.entry, handle.startX, handle.startY);
                }
            }

            onPressed: mouse => {
                handle.lastX = mouse.x;
                handle.lastY = mouse.y;
                handle.startX = mouse.x;
                handle.startY = mouse.y;
                handle.moved = false;
                handle.fromTouch = mouse.source !== Qt.MouseEventNotSynthesized;
                root.board.chosenContainer = root.entry.id;
                handle.dragging = mouse.button === Qt.LeftButton;
                if (handle.fromTouch)
                    hold.restart();
            }

            onPositionChanged: mouse => {
                // Screen pixels: these are board units inside the scaled layer.
                const slop = 4 / root.board.zoom;
                if (Math.abs(mouse.x - handle.startX) > slop || Math.abs(mouse.y - handle.startY) > slop) {
                    handle.moved = true;
                    hold.stop();
                }
                if (!handle.dragging)
                    return;
                // Already board units inside the scaled layer.
                root.board.moveContainer(root.entry.id,
                    mouse.x - handle.lastX, mouse.y - handle.lastY);
                handle.lastX = mouse.x;
                handle.lastY = mouse.y;
            }

            onReleased: mouse => {
                hold.stop();
                const wasDragging = handle.dragging;
                handle.dragging = false;
                if (mouse.button === Qt.RightButton && !handle.moved) {
                    root.menuRequested(root.entry, mouse.x, mouse.y);
                    return;
                }
                if (wasDragging && handle.moved)
                    root.board.commitContainer(root.entry.id);
            }

        }
    }

    /*
     * The corner resizes it — and only the corner.
     *
     * A container is mostly empty space with pictures on it, so an edge-drag
     * anywhere would steal presses from the things inside. One grip, in the
     * one place nothing else wants.
     */
    Rectangle {
        id: grip
        // Constant on screen for the same reason as the header: at 0.3× an
        // 18-unit grip is five pixels and cannot be hit.
        width: 18 / root.board.zoom
        height: 18 / root.board.zoom
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        radius: 4 / root.board.zoom
        color: gripArea.pressed ? Appearance.colors.colPrimary
            : gripHover.hovered ? Appearance.colors.colPrimaryHover
            : ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.4)

        HoverHandler {
            id: gripHover
            cursorShape: Qt.SizeFDiagCursor
        }

        MouseArea {
            id: gripArea
            anchors.fill: parent
            anchors.margins: -6 / root.board.zoom   // a bigger target than it looks
            onPositionChanged: mouse => {
                if (!gripArea.pressed)
                    return;
                // Board units already, inside the scaled layer.
                root.bw = Math.max(160, root.bw + mouse.x);
                root.bh = Math.max(120, root.bh + mouse.y);
            }
            onReleased: {
                root.commit();
                // The outline moved over things, or off them — see
                // `reconcileMembership`.
                root.board.reconcileMembership();
            }
        }
    }
}
