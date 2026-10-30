import qs.modules.common
import QtQuick

/*
 * One button of a connected group — Material 3 Expressive's button group.
 *
 * The outer corners of the group are round, the inner ones nearly square, so
 * the buttons read as one control that is split, not as loose circles sitting
 * near each other. The one under the pointer rounds its inner corners out, a
 * small shape change that answers the hover more clearly than a tint alone;
 * pressing squeezes them back in.
 */
Rectangle {
    id: root

    property string icon: ""
    property string tooltip: ""
    property real size: 48
    property real iconSize: 22
    property bool toggled: false
    /// Where it sits in its group: "first", "middle", "last" or "only".
    property string position: "only"

    signal clicked

    readonly property real outer: height / 2
    readonly property real inner: mouse.containsPress ? 4 : mouse.containsMouse || root.toggled ? height / 2 : 8
    readonly property bool roundLeft: root.position === "first" || root.position === "only"
    readonly property bool roundRight: root.position === "last" || root.position === "only"

    implicitWidth: root.size + (mouse.containsPress ? 6 : 0)
    implicitHeight: root.size
    topLeftRadius: root.roundLeft ? root.outer : root.innerAnimated
    bottomLeftRadius: root.roundLeft ? root.outer : root.innerAnimated
    topRightRadius: root.roundRight ? root.outer : root.innerAnimated
    bottomRightRadius: root.roundRight ? root.outer : root.innerAnimated

    property real innerAnimated: root.inner
    Behavior on innerAnimated {
        NumberAnimation {
            duration: Appearance.animation.elementMoveFast.duration
            easing.type: Easing.OutCubic
        }
    }
    Behavior on implicitWidth {
        NumberAnimation {
            duration: Appearance.animation.elementMoveFast.duration
            easing.type: Easing.OutCubic
        }
    }

    color: root.toggled
        ? (mouse.containsPress ? Appearance.colors.colSecondaryContainerActive : mouse.containsMouse ? Appearance.colors.colSecondaryContainerHover : Appearance.colors.colSecondaryContainer)
        : (mouse.containsPress ? ColorUtils.mix(Appearance.colors.colSurfaceContainerHigh, Appearance.colors.colOnSurface, 0.84) : mouse.containsMouse ? ColorUtils.mix(Appearance.colors.colSurfaceContainerHigh, Appearance.colors.colOnSurface, 0.92) : Appearance.colors.colSurfaceContainerHigh)
    Behavior on color {
        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(root)
    }

    MaterialSymbol {
        anchors.centerIn: parent
        text: root.icon
        iconSize: root.iconSize
        fill: root.toggled ? 1 : 0
        color: root.toggled ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }

    StyledToolTip {
        visible: mouse.containsMouse && root.tooltip.length > 0
        text: root.tooltip
    }
}
