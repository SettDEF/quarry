import qs.modules.common
import QtQuick
import QtQuick.Layouts

/*
 * A SETTING IN A MENU, WITH THE SWITCH THAT SETS IT.
 *
 * These were ordinary rows carrying a tick and, when on, a filled background —
 * so a menu of six settings was a patchwork of highlighted and unhighlighted
 * bars, and a tick that means "this is on" looked exactly like the tick that
 * means "this is the layout you chose". A switch says which of the two it is
 * without being read, and leaves the row's ground alone: only the pointer
 * tints a row now, so the eye can find where it is.
 *
 * The whole row is the target — a switch is 52px wide and a row is 260, and
 * nobody aims for the switch.
 */
Rectangle {
    id: root

    property string text: ""
    property string icon: ""
    property string hint: ""
    property bool checked: false

    signal toggled(bool on)

    Layout.fillWidth: true
    implicitWidth: label.implicitWidth + hintLabel.implicitWidth + 120
    implicitHeight: 40
    radius: Appearance.rounding.small
    // The hover colour at zero alpha, never `transparent`: fading to
    // rgba(0,0,0,0) walks the colour through black on the way out.
    color: tap.pressed ? Appearance.colors.colLayer4Active
        : hover.hovered ? Appearance.colors.colLayer4Hover
        : ColorUtils.transparentize(Appearance.colors.colLayer4Hover, 1)
    Behavior on color {
        animation: Appearance.animation.stateChange.colorAnimation.createObject(root)
    }

    HoverHandler {
        id: hover
        cursorShape: Qt.PointingHandCursor
    }
    TapHandler {
        id: tap
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onTapped: root.toggled(!root.checked)
    }

    MaterialSymbol {
        id: glyph
        anchors.left: parent.left
        anchors.leftMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        text: root.icon
        iconSize: 20
        color: root.checked ? Appearance.colors.colOnLayer1 : Appearance.colors.colSubtext
    }

    StyledText {
        id: label
        anchors.left: glyph.right
        anchors.leftMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        text: root.text
        font.pixelSize: Appearance.font.pixelSize.small
        color: Appearance.colors.colOnLayer1
    }

    StyledText {
        id: hintLabel
        anchors.right: knob.left
        anchors.rightMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        text: root.hint
        font.pixelSize: Appearance.font.pixelSize.smallest
        color: Appearance.colors.colSubtext
    }

    StyledSwitch {
        id: knob
        anchors.right: parent.right
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        scale: 0.78
        transformOrigin: Item.Right
        checked: root.checked
        // The row owns the gesture; the switch is the picture of the state.
        interactive: false
        onToggled: on => root.toggled(on)
    }
}
