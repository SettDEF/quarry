import qs.modules.common
import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts

/*
 * M3 menu surface. Wraps Controls.Popup so outside-click and Escape dismissal
 * come for free, and restyles it to the live palette.
 *
 * Put MenuRow children inside `contentColumn` via the default property:
 *
 *   MenuPopup {
 *       id: sortMenu
 *       MenuRow { text: "Hot"; icon: "local_fire_department"; onTriggered: ... }
 *   }
 */
Popup {
    id: root

    default property alias menuContent: contentColumn.data
    property real minWidth: 210

    /// Whether the pointer is anywhere on this menu -- rows, padding, gaps and
    /// separators alike. A cascading submenu needs the WHOLE surface, not just
    /// the rows: the few pixels of padding between them are exactly where the
    /// pointer sits mid-travel, and a submenu that closes there cannot be used.
    /// The padding (the MouseArea behind) OR the rows: hover reaches the topmost
    /// item and its ancestors only, and the background is a sibling underneath
    /// the rows — so over a row it read false, and a submenu closed under the
    /// pointer 260ms after you reached it.
    readonly property bool surfaceHovered: swallow.containsMouse || rowsHover.hovered

    padding: 8
    // Modal so a click outside only closes the menu: non-modal, that same click
    // also landed on whatever was underneath. The overlay itself stays invisible.
    modal: true
    dim: false
    Overlay.modal: Item {}
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    /*
     * A MENU MUST FIT ON THE SCREEN.
     *
     * This measured its own content and became exactly that tall — so the
     * settings menu, which had grown to twenty rows plus every installed
     * extension, ran off the bottom of the display and the last items simply
     * could not be reached. There was nothing to scroll, either: the content
     * was a plain column with no view around it.
     *
     * It is capped at most of the window now and scrolls past that, which is
     * what every other menu on the desktop does. The scrollbar only appears
     * when there is something to scroll.
     */
    readonly property real maxHeight: {
        const window = root.parent ? root.parent.height : 900;
        return Math.max(240, window * 0.82);
    }
    readonly property real wantedHeight: contentColumn.implicitHeight + root.padding * 2

    implicitWidth: Math.max(root.minWidth, contentColumn.implicitWidth + root.padding * 2)
    implicitHeight: Math.min(root.maxHeight, root.wantedHeight)

    background: Item {
        // Nothing under an open menu should be clickable through it. Rows take
        // their own taps; this swallows everything that lands on the padding,
        // the separators and the gaps between them.
        MouseArea {
            id: swallow
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true
            onWheel: wheel => wheel.accepted = true
        }

        // Same treatment as the sheets: a shadow drawn behind the shape rather
        // than an effect applied over it, so a menu reads as floating without
        // costing a render target.
        // The shell's own elevation: a soft, close shadow and a hairline edge
        // in the layer's border colour — depth from tone, not from outline.
        RectangularShadow {
            anchors.fill: surface
            radius: surface.radius
            blur: 14
            spread: 1
            offset: Qt.vector2d(0, 2)
            color: Appearance.colors.colShadow
        }

        Rectangle {
            id: surface
            anchors.fill: parent
            radius: Appearance.rounding.normal
            color: Appearance.colors.colLayer3
            border.width: 1
            border.color: Appearance.colors.colLayer0Border
        }
    }

    /*
     * ColumnLayout rather than Column: it derives its implicitWidth from the
     * children's *implicit* widths and then stretches them to its own width.
     * A plain Column measures children's actual widths, so stretching rows to
     * fill it would be a binding loop.
     */
    contentItem: Flickable {
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        // Only when it has somewhere to go: a menu that fits must not wobble
        // under the wheel.
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        // An ancestor of every row, so it hears the pointer over any of them.
        HoverHandler {
            id: rowsHover
        }

        /*
         * A scrollbar in a menu is a hint, not a control.
         *
         * The default sat inset from the edge at full strength, so it read as
         * a component in its own right — and the rows scrolled UNDER it, which
         * put a bright bar across the end of every highlighted row. Pushed to
         * the border, made thin and dim, and the rows given room so nothing
         * passes beneath it.
         */
        ScrollBar.vertical: StyledScrollBar {
            policy: parent.contentHeight > parent.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
            leftPadding: 0
            rightPadding: 0
            // Dim at rest; the pointer brings it up.
            opacity: hovered || pressed ? 0.85 : 0.32
            Behavior on opacity {
                NumberAnimation {
                    duration: Appearance.animDur(140)
                }
            }
        }

        ColumnLayout {
            id: contentColumn
            // Room for the bar when there is one, so a highlighted row ends
            // before it rather than sliding underneath.
            width: parent.width - (parent.contentHeight > parent.height ? 8 : 0)
            spacing: 1
        }
    }

    // M3 menus grow from the top edge on the way in and just fade on the way
    // out, so a reopen doesn't feel like it stutters.
    enter: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "opacity"
                from: 0
                to: 1
                duration: Appearance.animDur(150)
            }
            NumberAnimation {
                property: "scale"
                from: 0.92
                to: 1
                duration: Appearance.animDur(220)
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.animationCurves.expressiveFastSpatial
            }
        }
    }

    exit: Transition {
        NumberAnimation {
            property: "opacity"
            from: 1
            to: 0
            duration: Appearance.animDur(120)
        }
    }
}
