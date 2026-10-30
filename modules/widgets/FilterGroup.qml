import qs.modules.common
import QtQuick
import QtQuick.Layouts

/*
 * A collapsible card of filters: a 46px header, a note saying what is on, and
 * a body that only matters once you open it.
 *
 * Nine flat sections in one 420px drawer meant scrolling past six of them to
 * reach the sources. Shut, the header still says what the group is set to.
 */
ColumnLayout {
    id: root

    property string icon: ""
    property string title: ""
    /// What this group is set to, shown on the header while it is shut.
    property string note: ""

    property bool open_: false
    /// Matched by the search. Named like SettingRow's so the panel can count
    /// cards the same way — `visible` is effective and would deadlock.
    property bool matched: true
    readonly property bool wanted: root.matched

    /// Something in here is selected, so the header offers a way to undo it.
    property bool active: false
    property bool locked: false
    property string lockedNote: ""

    signal toggled
    signal cleared

    default property alias body: holder.data

    // A search opens what it found; the caller decides the rest.
    readonly property bool shown_: root.open_ && !root.locked

    Layout.fillWidth: true
    spacing: 0
    visible: root.wanted

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: head.implicitHeight + ((root.open_ || root.locked) ? bodyWrap.implicitHeight + 6 : 0)
        Behavior on implicitHeight {
            animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
        }
        radius: Appearance.rounding.normal
        color: Appearance.colors.colLayer1
        clip: true

        Rectangle {
            id: head
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            implicitHeight: 46
            height: implicitHeight
            radius: Appearance.rounding.normal
            color: headTap.pressed ? Appearance.colors.colLayer2Active : headHover.hovered ? Appearance.colors.colLayer2Hover : ColorUtils.transparentize(Appearance.colors.colLayer2Hover, 1)
            Behavior on color {
                animation: Appearance.animation.stateChange.colorAnimation.createObject(this)
            }

            HoverHandler {
                id: headHover
                cursorShape: Qt.PointingHandCursor
            }
            TapHandler {
                id: headTap
                gesturePolicy: TapHandler.ReleaseWithinBounds
                onTapped: root.toggled()
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 6
                spacing: 10

                MaterialSymbol {
                    Layout.alignment: Qt.AlignVCenter
                    visible: root.icon.length > 0
                    text: root.icon
                    iconSize: Appearance.font.pixelSize.large
                    fill: root.active ? 1 : 0
                    color: root.active ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer1
                }

                StyledText {
                    text: root.title
                    font.pixelSize: Appearance.font.pixelSize.smallie
                    font.weight: Font.DemiBold
                    color: Appearance.colors.colOnLayer1
                }

                StyledText {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignRight
                    text: root.note
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: root.active ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                    elide: Text.ElideRight
                }

                // Undo the whole group from where you can read it, rather than
                // hunting the one chip that is on.
                Rectangle {
                    Layout.alignment: Qt.AlignVCenter
                    visible: root.active
                    implicitWidth: 26
                    implicitHeight: 26
                    radius: height / 2
                    color: clearTap.pressed ? Appearance.colors.colLayer3Active : clearHover.hovered ? Appearance.colors.colLayer3Hover : ColorUtils.transparentize(Appearance.colors.colLayer3Hover, 1)
                    Behavior on color {
                        animation: Appearance.animation.stateChange.colorAnimation.createObject(this)
                    }

                    HoverHandler {
                        id: clearHover
                        cursorShape: Qt.PointingHandCursor
                    }
                    TapHandler {
                        id: clearTap
                        gesturePolicy: TapHandler.ReleaseWithinBounds
                        onTapped: root.cleared()
                    }
                    MaterialSymbol {
                        anchors.centerIn: parent
                        text: "backspace"
                        iconSize: Appearance.font.pixelSize.smallie
                        color: Appearance.colors.colSubtext
                    }
                    StyledToolTip {
                        visible: clearHover.hovered
                        text: "Clear this group"
                    }
                }

                MaterialSymbol {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.rightMargin: 8
                    text: "expand_more"
                    iconSize: Appearance.font.pixelSize.large
                    color: Appearance.colors.colSubtext
                    rotation: root.open_ ? 180 : 0
                    Behavior on rotation {
                        animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
                    }
                }
            }
        }

        ColumnLayout {
            id: bodyWrap
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: head.bottom
            anchors.leftMargin: 14
            anchors.rightMargin: 14
            spacing: 8
            opacity: (root.open_ || root.locked) ? 1 : 0
            visible: opacity > 0
            Behavior on opacity {
                animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
            }

            StyledText {
                Layout.fillWidth: true
                visible: root.locked
                text: root.lockedNote
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colSubtext
                wrapMode: Text.WordWrap
            }

            ColumnLayout {
                id: holder
                Layout.fillWidth: true
                visible: !root.locked
                spacing: 8
            }

            Item {
                implicitHeight: 4
            }
        }
    }
}
