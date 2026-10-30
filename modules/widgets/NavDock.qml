import qs.modules.common
import QtQuick
import QtQuick.Effects
import QtQuick.Layouts

/*
 * Navigation as a floating dock at the bottom centre — Rodded's shape, and the
 * M3 navigation-bar idiom: the active destination expands to show its label
 * while the rest stay icon circles.
 *
 * It floats over the content rather than reserving space, so the gallery adds
 * `bottomInset` to its own margin to keep the last row reachable.
 */
Rectangle {
    id: root

    property var destinations: []      // [{ id, icon, label }]
    property string current: ""

    signal selected(string id)

    /*
     * THE SAME PILL THE MEDIA BAR IS.
     *
     * This drew itself on colLayer1 with a layer-0 border while the video
     * controls used the container-highest surface with an outline — two floating
     * bars, in the same corner of the same window, made of different materials.
     * Rodded gets this right by having exactly one shape for "a bar over the
     * content", and matching it is most of what made that app look finished.
     *
     * The shadow is the other half: a bar sitting over pictures with no shadow
     * reads as part of the picture, and this one floats over a wall of them.
     */
    implicitWidth: row.implicitWidth + 24
    implicitHeight: Math.max(56, row.implicitHeight + 14)
    radius: Appearance.rounding.full
    color: Appearance.colors.colSurfaceContainerHighest
    border.width: 1
    border.color: Appearance.colors.colOutlineVariant
    antialiasing: true

    // Drawn behind the shape rather than as an effect over it — see MenuPopup:
    // an effect costs a render target, and this is on screen the whole time.
    RectangularShadow {
        anchors.fill: parent
        z: -1
        radius: parent.radius
        blur: 22
        spread: 1
        offset: Qt.vector2d(0, 4)
        color: Qt.rgba(0, 0, 0, 0.38)
    }

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 4

        Repeater {
            model: root.destinations

            delegate: PillTab {
                required property var modelData
                icon: modelData.icon
                // Only the active destination spends horizontal space on words.
                label: root.current === modelData.id ? modelData.label : ""
                active: root.current === modelData.id
                accent: "primary"
                horizontalPadding: root.current === modelData.id ? 16 : 12
                onTriggered: root.selected(modelData.id)

                Behavior on implicitWidth {
                    animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
                }
            }
        }
    }
}
