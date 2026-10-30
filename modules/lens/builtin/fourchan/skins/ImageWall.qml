import qs.modules.common
import qs.modules.widgets
import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import "../post.js" as Post

/*
 * THE THREAD AS A WALL.
 *
 * A thread that is fifty pictures and eight words is a gallery pretending to be
 * a conversation, and reading it post by post to find the two you want is the
 * long way round. This is the same thread with the words put away: every file
 * in it, laid out the way quarry lays out everything else, one click from full
 * size and one right-click from everything else.
 *
 * It holds nothing — the pictures, what has been taken and what is hidden all
 * live on the lens, so switching to it and back lands exactly where you were.
 */
GridView {
    id: root

    required property var lens
    signal contextRequested(var post, real sceneX, real sceneY)

    // The lens's own list, so the wall, the viewer's counter and the rail's
    // count can never disagree about what is here.
    readonly property var shots: root.lens.wallImages
    readonly property int columns: Math.max(2, Math.floor((root.width - 16) / 210))

    model: root.shots
    cellWidth: Math.floor((root.width - 16) / root.columns)
    cellHeight: root.cellWidth
    leftMargin: 8
    topMargin: 10
    bottomMargin: 24
    clip: true
    cacheBuffer: 800
    boundsBehavior: Flickable.StopAtBounds

    ScrollBar.vertical: StyledScrollBar {
        view: root
    }

    StyledText {
        // Parented to the view, not its content: a visual child declared in a
        // view lands in `contentItem`, where "centred" means centred on the
        // rows rather than on the screen.
        parent: root
        anchors.centerIn: parent
        visible: root.count === 0
        text: root.lens.fetching ? "Fetching…" : "No pictures in this thread."
        color: Appearance.colors.colSubtext
    }

    delegate: Item {
        id: cell
        required property var modelData

        width: root.cellWidth
        height: root.cellHeight

        readonly property bool added: root.lens.isAdded(cell.modelData)
        readonly property bool video: root.lens.isVideo(cell.modelData)
        property bool revealed: false
        readonly property bool blurred: root.lens.boardAdult && Prefs.blurNsfw && !cell.revealed && !hover.hovered

        Rectangle {
            anchors.fill: parent
            anchors.margins: 4
            radius: Appearance.rounding.small
            color: tap.pressed ? Appearance.colors.colLayer2Active : hover.hovered ? Appearance.colors.colLayer2Hover : Appearance.colors.colLayer2
            clip: true

            Behavior on color {
                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(cell)
            }

            Image {
                id: thumb
                anchors.fill: parent
                asynchronous: true
                fillMode: Image.PreserveAspectCrop
                source: root.lens.pictureFor(cell.modelData, false)
                sourceSize.width: cell.modelData.tn_w || 250
                sourceSize.height: cell.modelData.tn_h || 250

                layer.enabled: cell.blurred
                layer.effect: MultiEffect {
                    blurEnabled: true
                    blur: 1.0
                    blurMax: 48
                    autoPaddingEnabled: false
                }
            }

            HoverHandler {
                id: hover
                cursorShape: Qt.PointingHandCursor
            }
            TapHandler {
                id: tap
                gesturePolicy: TapHandler.ReleaseWithinBounds
                // Covered means covered: the first tap uncovers, as it does on
                // a thumbnail in a thread. Opening straight to full size would
                // be a way round the blur, not a shortcut.
                onTapped: {
                    if (cell.blurred) {
                        cell.revealed = true;
                        return;
                    }
                    root.lens.openViewer(cell.modelData);
                }
            }
            TapHandler {
                acceptedButtons: Qt.RightButton
                gesturePolicy: TapHandler.ReleaseWithinBounds
                onSingleTapped: eventPoint => root.contextRequested(cell.modelData, eventPoint.scenePosition.x, eventPoint.scenePosition.y)
            }

            // The file line, over the picture rather than beside it: a wall is
            // pictures, and the name is a thing you look for only sometimes.
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 22
                visible: hover.hovered
                color: Appearance.colors.colLayer0Base
                opacity: 0.9

                StyledText {
                    anchors.fill: parent
                    anchors.leftMargin: 6
                    anchors.rightMargin: 6
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideMiddle
                    text: `${root.lens.fileName(cell.modelData)} · ${cell.modelData.w}×${cell.modelData.h}`
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: Appearance.colors.colOnLayer0
                }
            }

            Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.margins: 6
                width: 26
                height: 18
                radius: 9
                visible: cell.video
                color: Appearance.colors.colLayer0Base
                opacity: 0.85

                MaterialSymbol {
                    anchors.centerIn: parent
                    text: "play_arrow"
                    iconSize: 14
                    color: Appearance.colors.colOnLayer0
                }
            }

            Rectangle {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 6
                width: 28
                height: 28
                radius: 14
                visible: cell.added || hover.hovered
                color: cell.added ? Appearance.colors.colPrimaryContainer : Appearance.colors.colLayer0Base
                opacity: cell.added ? 0.95 : 0.85

                MaterialSymbol {
                    anchors.centerIn: parent
                    text: cell.added ? "check" : "add_photo_alternate"
                    iconSize: 16
                    color: cell.added ? Appearance.colors.colOnPrimaryContainer : Appearance.colors.colOnLayer0
                }
                HoverHandler {
                    id: addHover
                    cursorShape: Qt.PointingHandCursor
                }
                TapHandler {
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: root.lens.addImage(cell.modelData, null)
                }
                StyledToolTip {
                    visible: addHover.hovered
                    text: cell.added ? "In your catalogue" : "Take it into quarry"
                }
            }
        }
    }
}
