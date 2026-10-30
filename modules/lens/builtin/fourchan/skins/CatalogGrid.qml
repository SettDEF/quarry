import "../post.js" as Post
import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import qs.modules.common
import qs.modules.widgets

/*
 * ONE BOARD'S CATALOGUE — every live thread as a card.
 *
 * A card is the OP: its picture, its subject, the first few lines, and how many
 * replies and images are waiting inside. That is the whole reason a catalogue
 * exists, and it is what a masonry wall of loose pictures cannot show.
 *
 * A GridView rather than a Flow: a board runs to a hundred and fifty threads
 * and the delegates have to recycle.
 */
GridView {
    id: root

    required property var lens
    readonly property int columns: root.asList ? 1 : Math.max(2, Math.floor((root.width - 20) / Math.max(90, root.lens.layoutCell || 240)))
    /*
     * The cell comes from the chosen layout now (Lens.layoutCell), so the
     * app's layout button changes the board the way it changes everything
     * else. "Compact" is a row rather than a tile, which is why it gets a
     * height of its own.
     */
    readonly property bool asList: root.lens.layout === "compact"

    signal contextRequested(var post, real sceneX, real sceneY)

    cellWidth: root.asList ? root.width - 20 : Math.floor((root.width - 20) / root.columns)
    cellHeight: root.asList ? 96 : root.lens.keepsShape ? Math.round(root.cellWidth * 1.15) : Math.round(root.cellWidth * 1)
    leftMargin: 10
    topMargin: 12
    bottomMargin: 20
    clip: true
    cacheBuffer: 600
    boundsBehavior: Flickable.StopAtBounds
    model: root.lens.visibleThreads

    ScrollBar.vertical: StyledScrollBar {
        view: root
    }

    delegate: Item {
        id: cell

        required property var modelData

        width: root.cellWidth
        height: root.cellHeight

        Rectangle {
            id: card

            anchors.fill: parent
            anchors.margins: 5
            radius: Appearance.rounding.normal
            color: cardTap.pressed ? Appearance.colors.colLayer1Active : cardHover.hovered ? Appearance.colors.colLayer1Hover : Appearance.colors.colLayer1
            clip: true

            HoverHandler {
                id: cardHover

                cursorShape: Qt.PointingHandCursor
            }

            TapHandler {
                id: cardTap

                gesturePolicy: TapHandler.ReleaseWithinBounds
                onTapped: root.lens.showThread(cell.modelData.no, cell.modelData.sub || "")
            }

            TapHandler {
                acceptedButtons: Qt.RightButton
                gesturePolicy: TapHandler.ReleaseWithinBounds
                onSingleTapped: (eventPoint) => {
                    return root.contextRequested(cell.modelData, eventPoint.scenePosition.x, eventPoint.scenePosition.y);
                }
            }

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                // The OP's picture, filling the card's top. Collapsed only:
                // expanding belongs in the thread, not over the catalogue.
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 150
                    clip: true

                    Image {
                        id: opThumb

                        anchors.centerIn: parent
                        width: parent.width
                        height: parent.height
                        asynchronous: true
                        fillMode: Image.PreserveAspectCrop
                        source: root.lens.hasImage(cell.modelData) ? root.lens.pictureFor(cell.modelData, false) : ""
                        sourceSize.width: cell.modelData.tn_w || 250
                        sourceSize.height: cell.modelData.tn_h || 250
                        visible: source.toString().length > 0
                        layer.enabled: cardImage.blurred

                        layer.effect: MultiEffect {
                            blurEnabled: true
                            blur: 1
                            blurMax: 48
                            autoPaddingEnabled: false
                        }

                    }

                    QtObject {
                        id: cardImage

                        readonly property bool blurred: root.lens.boardAdult && Prefs.blurNsfw && !cardHover.hovered
                    }

                    MaterialSymbol {
                        anchors.centerIn: parent
                        visible: !root.lens.hasImage(cell.modelData)
                        text: "chat_bubble"
                        iconSize: 32
                        color: Appearance.colors.colOnLayer1Inactive
                    }

                    // Straight into the catalogue from the catalogue: the OP
                    // image is usually the one worth keeping.
                    Rectangle {
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 6
                        width: 28
                        height: 28
                        radius: 14
                        visible: root.lens.hasImage(cell.modelData) && (cardHover.hovered || root.lens.isAdded(cell.modelData))
                        color: root.lens.isAdded(cell.modelData) ? Appearance.colors.colPrimaryContainer : Appearance.colors.colLayer0Base
                        opacity: 0.9

                        MaterialSymbol {
                            anchors.centerIn: parent
                            text: root.lens.isAdded(cell.modelData) ? "check" : "add_photo_alternate"
                            iconSize: 16
                            color: root.lens.isAdded(cell.modelData) ? Appearance.colors.colOnPrimaryContainer : Appearance.colors.colOnLayer0
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
                            text: root.lens.isAdded(cell.modelData) ? "In your catalogue" : "Add to quarry"
                        }

                    }

                    // The OP's picture, full size, without opening the thread
                    // first — a catalogue is browsed by its pictures.
                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.margins: 6
                        width: 28
                        height: 28
                        radius: 14
                        // Not over a covered picture: the badge would open it
                        // full size without the reveal step the blur is for.
                        visible: root.lens.hasImage(cell.modelData) && !cardImage.blurred && (cardHover.hovered || fullHover.hovered)
                        opacity: fullHover.hovered ? 1 : 0.85
                        color: Appearance.colors.colLayer0Base

                        MaterialSymbol {
                            anchors.centerIn: parent
                            text: root.lens.isVideo(cell.modelData) ? "play_circle" : "open_in_full"
                            iconSize: 16
                            color: Appearance.colors.colOnLayer0
                        }

                        HoverHandler {
                            id: fullHover

                            cursorShape: Qt.PointingHandCursor
                        }

                        TapHandler {
                            gesturePolicy: TapHandler.ReleaseWithinBounds
                            onTapped: root.lens.openViewer(cell.modelData)
                        }

                        StyledToolTip {
                            visible: fullHover.hovered
                            text: "Open the picture full size"
                        }

                    }

                    Rectangle {
                        anchors.left: parent.left
                        anchors.bottom: parent.bottom
                        anchors.margins: 6
                        width: 26
                        height: 18
                        radius: 9
                        visible: root.lens.isVideo(cell.modelData)
                        color: Appearance.colors.colLayer0Base
                        opacity: 0.85

                        MaterialSymbol {
                            anchors.centerIn: parent
                            text: "play_arrow"
                            iconSize: 14
                            color: Appearance.colors.colOnLayer0
                        }

                    }

                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.margins: 10
                    spacing: 2

                    StyledText {
                        Layout.fillWidth: true
                        visible: text.length > 0
                        elide: Text.ElideRight
                        text: Post.plain(cell.modelData.sub)
                        font.pixelSize: Appearance.font.pixelSize.small
                        font.weight: Font.DemiBold
                        color: Appearance.colors.colOnLayer1
                    }

                    StyledText {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        wrapMode: Text.Wrap
                        elide: Text.ElideRight
                        maximumLineCount: 4
                        text: Post.plain(cell.modelData.com)
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        MaterialSymbol {
                            text: "forum"
                            iconSize: 13
                            color: Appearance.colors.colSubtext
                        }

                        StyledText {
                            text: String(cell.modelData.replies || 0)
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            color: Appearance.colors.colSubtext
                        }

                        MaterialSymbol {
                            text: "image"
                            iconSize: 13
                            color: Appearance.colors.colSubtext
                        }

                        StyledText {
                            text: String(cell.modelData.images || 0)
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            color: Appearance.colors.colSubtext
                        }

                        Item {
                            Layout.fillWidth: true
                        }

                        StyledText {
                            text: Post.age(cell.modelData.time)
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            color: Appearance.colors.colSubtext
                        }

                    }

                }

            }

            Behavior on color {
                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(card)
            }

        }

    }

}
