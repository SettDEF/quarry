import qs.modules.common
import QtQuick
import Qt5Compat.GraphicalEffects

/*
 * One lens entry as a tile: its picture over its name, two to a row in the rail.
 *
 * For lenses whose entries are known by face — Morse's chats. A picture when
 * there is one, else initials on a colour from the entry's id, else the glyph.
 * Narrow rail: no name, just the face, with the name as a tooltip.
 */
Rectangle {
    id: root

    property string label: ""
    property string picture: ""
    property string icon: "chat"
    property string initials: ""
    /// 0..1, the fallback disc's hue; below 0 means the plain layer colour.
    property real hue: -1
    property string count: ""
    property bool active: false
    property bool showLabel: true

    signal triggered
    signal contextRequested(real x, real y)

    implicitHeight: root.showLabel ? 76 : 50
    radius: Appearance.rounding.normal
    color: root.active ? Appearance.colors.colSecondaryContainer
        : mouse.containsMouse ? Appearance.colors.colLayer1Hover : "transparent"

    Behavior on color {
        ColorAnimation {
            duration: Appearance.animDur(160)
        }
    }

    Item {
        id: face

        width: 40
        height: 40
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: root.showLabel ? 8 : 5

        Rectangle {
            id: disc

            anchors.fill: parent
            radius: width / 2
            visible: !photo.shown
            color: root.hue >= 0 ? Qt.hsla(root.hue, 0.40, Appearance.darkmode ? 0.36 : 0.66, 1) : Appearance.colors.colLayer2

            StyledText {
                anchors.centerIn: parent
                visible: root.initials.length > 0
                text: root.initials
                font.pixelSize: Appearance.font.pixelSize.small
                font.weight: Font.DemiBold
                // As ChatList draws it: whichever of the two reads on the disc.
                color: ColorUtils.contrastingText(disc.color, "#ffffff", "#141414")
            }

            MaterialSymbol {
                anchors.centerIn: parent
                visible: root.initials.length === 0
                text: root.icon
                iconSize: 20
                color: Appearance.colors.colOnLayer1
            }
        }

        Image {
            id: photo

            readonly property bool shown: root.picture.length > 0 && status === Image.Ready

            anchors.fill: parent
            visible: photo.shown
            source: root.picture
            sourceSize.width: 80
            sourceSize.height: 80
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            layer.enabled: photo.shown
            layer.effect: OpacityMask {
                maskSource: Rectangle {
                    width: face.width
                    height: face.height
                    radius: face.width / 2
                }
            }
        }

        // Unread, on the face's corner as every messenger draws it.
        Rectangle {
            visible: root.count.length > 0
            x: face.width - width + 6
            y: -4
            width: Math.max(18, countText.implicitWidth + 8)
            height: 18
            radius: 9
            color: Appearance.colors.colPrimary
            border.width: 2
            border.color: Appearance.colors.colLayer0

            StyledText {
                id: countText

                anchors.centerIn: parent
                text: root.count
                font.pixelSize: Appearance.font.pixelSize.smallest
                font.weight: Font.DemiBold
                color: Appearance.colors.colOnPrimary
            }
        }
    }

    StyledText {
        visible: root.showLabel
        anchors.top: face.bottom
        anchors.topMargin: 5
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 4
        anchors.rightMargin: 4
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        text: root.label
        font.pixelSize: Appearance.font.pixelSize.smallest
        color: root.active ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
    }

    MouseArea {
        id: mouse

        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: (m) => {
            if (m.button === Qt.RightButton)
                root.contextRequested(m.x, m.y);
            else
                root.triggered();
        }
    }

    StyledToolTip {
        visible: mouse.containsMouse && !root.showLabel
        text: root.label
    }
}
