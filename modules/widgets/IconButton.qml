import qs.modules.common
import QtQuick

// Circular icon-only button with a hover pill and optional tooltip.
Rectangle {
    id: root

    property string icon: ""
    property string tooltip: ""
    property real size: 38
    property real iconSize: Appearance.font.pixelSize.larger
    property bool toggled: false
    property color iconColor: root.toggled ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
    property color hoverColor: Appearance.colors.colLayer1Hover
    property color toggledColor: Appearance.colors.colSecondaryContainer
    property real fill: root.toggled ? 1 : 0

    signal clicked
    signal rightClicked

    implicitWidth: size
    implicitHeight: size
    radius: Appearance.rounding.full

    /*
     * The "off" colour is the hover colour at zero alpha, NOT `transparent`.
     *
     * `transparent` is rgba(0,0,0,0), so a ColorAnimation from a hover tint to
     * it interpolates the RGB toward BLACK while the alpha falls — the row
     * darkens on the way out and you see a black flash every time the pointer
     * leaves. Fading within one hue has no such midpoint.
     */
    readonly property color offColor: ColorUtils.transparentize(root.hoverColor, 1)

    opacity: root.enabled ? 1 : 0.35

    color: root.toggled ? (mouse.containsPress ? Appearance.colors.colSecondaryContainerActive : mouse.containsMouse ? Appearance.colors.colSecondaryContainerHover : root.toggledColor) : (mouse.containsPress ? Appearance.colors.colLayer1Active : mouse.containsMouse ? root.hoverColor : root.offColor)

    Behavior on color {
        animation: Appearance.animation.stateChange.colorAnimation.createObject(root)
    }

    MaterialSymbol {
        anchors.centerIn: parent
        text: root.icon
        iconSize: root.iconSize
        fill: root.fill
        color: root.iconColor
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        enabled: root.enabled
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: event => {
            if (event.button === Qt.RightButton)
                root.rightClicked();
            else
                root.clicked();
        }
    }

    StyledToolTip {
        visible: root.tooltip.length > 0 && mouse.containsMouse
        text: root.tooltip
    }
}
