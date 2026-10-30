import qs.modules.common
import QtQuick
import QtQuick.Layouts

// Rounded chip with optional icon + label — the shell's PillTab.
Rectangle {
    id: root

    property string icon: ""
    property string label: ""
    property bool active: false
    property string accent: "secondary"          // "primary" | "secondary"
    property bool showBorder: false
    property bool dimInactive: false
    property color inactiveColor: ColorUtils.transparentize(Appearance.colors.colLayer2Hover, 1)

    /*
     * The "off" colour is the hover colour at zero alpha, NOT `transparent`.
     *
     * `transparent` is rgba(0,0,0,0), so a ColorAnimation from a hover tint to
     * it interpolates the RGB toward BLACK while the alpha falls — the row
     * darkens on the way out and you see a black flash every time the pointer
     * leaves. Fading within one hue has no such midpoint.
     */
    property real horizontalPadding: 14
    property real verticalPadding: 8
    property real iconSize: Appearance.font.pixelSize.normal
    property real labelSize: Appearance.font.pixelSize.small

    signal triggered

    readonly property color _activeBg: root.accent === "primary" ? Appearance.colors.colPrimaryContainer : Appearance.colors.colSecondaryContainer
    readonly property color _activeFg: root.accent === "primary" ? Appearance.colors.colOnPrimaryContainer : Appearance.colors.colOnSecondaryContainer

    implicitWidth: pillContent.implicitWidth + root.horizontalPadding * 2
    implicitHeight: pillContent.implicitHeight + root.verticalPadding * 2
    radius: Appearance.rounding.full

    color: root.active ? root._activeBg : (hov.hovered ? Appearance.colors.colLayer2Hover : root.inactiveColor)
    border.width: (!root.active && root.showBorder) ? 1 : 0
    border.color: Appearance.colors.colOutlineVariant

    Behavior on color {
        animation: Appearance.animation.stateChange.colorAnimation.createObject(root)
    }

    HoverHandler {
        id: hov
        cursorShape: Qt.PointingHandCursor
    }
    TapHandler {
        // Grab on press. The default policy does not, so the press reaches
        // whatever is underneath and acts there while this only sees the tap.
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onTapped: root.triggered()
    }

    RowLayout {
        id: pillContent
        anchors.centerIn: parent
        spacing: 5

        MaterialSymbol {
            visible: root.icon.length > 0
            text: root.icon
            iconSize: root.iconSize
            fill: root.active ? 1 : 0
            color: root.active ? root._activeFg : Appearance.colors.colOnLayer1
            opacity: (!root.active && root.dimInactive) ? 0.45 : 1
        }
        StyledText {
            visible: root.label.length > 0
            text: root.label
            font.pixelSize: root.labelSize
            font.weight: root.active ? Font.Medium : Font.Normal
            color: root.active ? root._activeFg : Appearance.colors.colOnLayer1
            opacity: (!root.active && root.dimInactive) ? 0.55 : 1

            Behavior on color {
                animation: Appearance.animation.stateChange.colorAnimation.createObject(this)
            }
        }
    }
}
