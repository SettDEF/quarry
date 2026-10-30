import qs.modules.common
import QtQuick

/*
 * M3 text / filled / tonal / outlined button in one component.
 *
 * variant: "text" | "filled" | "tonal" | "outlined"
 */
Rectangle {
    id: root

    property string text: ""
    property string icon: ""
    property string variant: "text"
    property bool destructive: false
    property real horizontalPadding: root.variant === "text" ? 12 : 20

    signal clicked

    readonly property color _accent: root.destructive ? Appearance.colors.colError : Appearance.colors.colPrimary
    readonly property color _onAccent: root.destructive ? Appearance.colors.colOnError : Appearance.colors.colOnPrimary
    readonly property color _container: root.destructive ? Appearance.colors.colErrorContainer : Appearance.colors.colSecondaryContainer
    readonly property color _onContainer: root.destructive ? Appearance.colors.colOnErrorContainer : Appearance.colors.colOnSecondaryContainer

    readonly property color foreground: {
        if (root.variant === "filled")
            return root._onAccent;
        if (root.variant === "tonal")
            return root._onContainer;
        return root._accent;
    }

    implicitWidth: content.implicitWidth + root.horizontalPadding * 2
    implicitHeight: 40
    radius: Appearance.rounding.full
    opacity: root.enabled ? 1 : 0.38

    color: {
        const pressed = mouse.containsPress;
        const hovered = mouse.containsMouse;
        if (root.variant === "filled")
            return pressed ? ColorUtils.mix(root._accent, root._onAccent, 0.8) : hovered ? ColorUtils.mix(root._accent, root._onAccent, 0.9) : root._accent;
        if (root.variant === "tonal")
            return pressed ? ColorUtils.mix(root._container, root._onContainer, 0.8) : hovered ? ColorUtils.mix(root._container, root._onContainer, 0.9) : root._container;
        // text + outlined share a transparent resting state
        return pressed ? ColorUtils.transparentize(root._accent, 0.78) : hovered ? ColorUtils.transparentize(root._accent, 0.9) : ColorUtils.transparentize(root._accent, 1);
    }

    border.width: root.variant === "outlined" ? 1 : 0
    border.color: Appearance.colors.colOutline

    Behavior on color {
        animation: Appearance.animation.stateChange.colorAnimation.createObject(root)
    }

    Row {
        id: content
        anchors.centerIn: parent
        spacing: 8

        MaterialSymbol {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.icon.length > 0
            text: root.icon
            iconSize: Appearance.font.pixelSize.normal
            color: root.foreground
        }
        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            text: root.text
            color: root.foreground
            font.pixelSize: Appearance.font.pixelSize.small
            font.weight: Font.Medium
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        enabled: root.enabled
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
