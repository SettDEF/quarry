import qs.modules.common
import QtQuick
import QtQuick.Controls

/*
 * Thin M3 scrollbar that shows itself while the view is moving.
 *
 * It used to appear only while *the bar itself* was hovered, which in a
 * full-bleed gallery meant never: there was no way to tell how far down a
 * catalogue you were, or that there was anything below. Handing it the view it
 * scrolls lets it fade in whenever that view moves, which is when the answer is
 * wanted.
 */
ScrollBar {
    id: root

    /// The Flickable this scrolls. Optional — without it the old
    /// hover-only behaviour remains.
    property var view: null

    policy: ScrollBar.AsNeeded
    topPadding: Appearance.rounding.normal
    bottomPadding: Appearance.rounding.normal
    active: hovered || pressed || (root.view ? (root.view.moving || root.view.flicking || root.view.dragging) : false)

    // A 4px bar is hard to grab; the padding gives it a real hit area without
    // making it look heavier.
    leftPadding: 4
    rightPadding: 4

    /*
     * THE HANDLE HAS A COLOUR. THE RAIL DOES NOT.
     *
     * Two mistakes, in order. It used to fade the handle to opacity 0 whenever
     * the view was still, so most of the time nothing at all told you how far
     * down forty thousand pictures you were — and a scrollbar that appears once
     * you are already scrolling answers a question you have stopped asking.
     *
     * The fix for that added a full-height track, which is worse in a different
     * way: a permanent pale rail down the side of the window, competing with
     * the pictures, to say something the handle's own position already says.
     * The bar you can grab is the part that carries information. It is solid,
     * it is always there while there is anywhere to scroll, and the rail it
     * runs in is nothing.
     */
    contentItem: Rectangle {
        // Thin: it is a position indicator, and the wider it gets the more it
        // competes with what it is indicating the position of.
        implicitWidth: root.pressed ? 7 : 4
        implicitHeight: 40
        radius: width / 2
        color: root.pressed || root.hovered
            ? Appearance.colors.colPrimary
            : Appearance.colors.colOnSurfaceVariant
        // Opaque. The only thing that hides it is having nothing to scroll.
        opacity: root.size < 1.0 || root.policy === ScrollBar.AlwaysOn ? 1 : 0

        Behavior on implicitWidth {
            NumberAnimation {
                duration: Appearance.animDur(120)
            }
        }

        Behavior on color {
            animation: Appearance.animation.stateChange.colorAnimation.createObject(this)
        }

        Behavior on opacity {
            NumberAnimation {
                duration: Appearance.animDur(250)
            }
        }
    }

    // No rail: see above.
    background: null
}
