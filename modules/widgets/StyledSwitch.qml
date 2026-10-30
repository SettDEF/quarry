import qs.modules.common
import QtQuick

/*
 * A SWITCH THAT IS DRAWN, NOT SPELLED.
 *
 * The settings rows used the `toggle_on` / `toggle_off` glyphs from the icon
 * font. A glyph cannot animate: flipping a switch swapped one character for
 * another, so the single most-pressed control in the app answered with a jump
 * cut. It was also stuck at whatever size the font was set to — 22px, small
 * enough that a column of them read as punctuation rather than as controls.
 *
 * So it is geometry now: a track and a handle that slides between two ends.
 * The Material 3 shape, which carries its state three ways at once — where the
 * handle IS, what the track is filled with, and whether there is an outline —
 * because a switch has to be readable at a glance down a list of twenty-nine.
 *
 * The handle grows on press and shrinks back, which is the part that makes it
 * feel like a physical thing rather than a state that changed nearby.
 */
Item {
    id: root

    property bool checked: false
    /*
     * Whether this switch takes the press ITSELF.
     *
     * False where the whole row is the target — which is most of them. That is
     * not the same as being disabled, and it must not look like it: a settings
     * list whose every switch is greyed out reads as an app with nothing turned
     * on. Dimming follows `enabled`, which is the property that actually means
     * "you cannot change this".
     */
    property bool interactive: true
    /*
     * Drawn inside the handle when on. EMPTY BY DEFAULT.
     *
     * A tick sat in a dark handle on a bright track read as a hole punched in
     * the switch — heavy, and the busiest thing in a column of twenty-nine.
     * M3 treats the icon as opt-in for exactly this reason.
     */
    property string icon: ""

    signal toggled(bool on)

    implicitWidth: 52
    implicitHeight: 32

    opacity: root.enabled ? 1 : 0.38

    HoverHandler {
        id: hover
        enabled: root.interactive && root.enabled
        cursorShape: Qt.PointingHandCursor
    }
    TapHandler {
        id: tap
        enabled: root.interactive && root.enabled
        // Grab the press — the same reason every other control here does: a
        // switch that lights up and then acts on whatever is underneath is
        // worse than one that does nothing.
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onTapped: root.toggled(!root.checked)
    }

    /*
     * THE OUTLINE IS THE OFF STATE.
     *
     * Off is a hollow track with a border and a small handle; on is a filled
     * track with a large one. Two switches side by side then differ in weight,
     * not just in hue — which is what still tells them apart when the accent is
     * a colour someone cannot easily distinguish from the surface.
     */
    Rectangle {
        id: track
        anchors.fill: parent
        radius: height / 2
        antialiasing: true

        color: root.checked
            ? (tap.pressed ? Appearance.colors.colPrimaryActive
                : hover.hovered ? Appearance.colors.colPrimaryHover
                : Appearance.colors.colPrimary)
            : (tap.pressed ? Appearance.colors.colLayer2Active
                : hover.hovered ? Appearance.colors.colLayer2Hover
                : Appearance.colors.colSurfaceContainerHighest)

        border.width: root.checked ? 0 : 2
        border.color: Appearance.colors.colOutline

        Behavior on color {
            animation: Appearance.animation.stateChange.colorAnimation.createObject(track)
        }
        Behavior on border.width {
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(track)
        }
    }

    Rectangle {
        id: knob

        /*
         * Three sizes, and the order matters: a press beats everything, then
         * on, then off. M3's 16 → 24 growth is what makes the switch read as
         * gaining weight when it is turned on rather than merely sliding.
         */
        readonly property real diameter: tap.pressed ? 28 : root.checked ? 24 : 16

        width: knob.diameter
        height: knob.diameter
        radius: height / 2
        antialiasing: true
        anchors.verticalCenter: parent.verticalCenter

        // Measured from the ends rather than interpolated across the middle, so
        // the inset stays even at both stops however the handle is sized.
        x: root.checked
            ? root.width - knob.diameter - (root.height - knob.diameter) / 2
            : (root.height - knob.diameter) / 2

        /*
         * A LIGHT HANDLE, NOT THE STRICT M3 `onPrimary`.
         *
         * On this palette `onPrimary` is #1e2300 — near black — so the spec's
         * own pairing puts a black disc in a lime track and the switch reads as
         * damaged rather than on. A light handle keeps the same contrast ratio
         * the spec is protecting and looks like a switch.
         */
        color: root.checked ? Appearance.colors.colOnSurface : Appearance.colors.colOutline

        Behavior on x {
            animation: Appearance.animation.elementMove.numberAnimation.createObject(knob)
        }
        Behavior on width {
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(knob)
        }
        Behavior on height {
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(knob)
        }
        Behavior on color {
            animation: Appearance.animation.stateChange.colorAnimation.createObject(knob)
        }

        // The tick only fits once the handle has grown, and fades rather than
        // appearing mid-slide — a glyph popping into a moving circle is the
        // one thing that would make this look worse than the icon it replaced.
        MaterialSymbol {
            anchors.centerIn: parent
            visible: opacity > 0.01
            opacity: root.checked && root.icon.length > 0 ? 1 : 0
            text: root.icon
            iconSize: 16
            fill: 1
            // Dark on the light handle — the reverse of what it was.
            color: Appearance.colors.colOnPrimary

            Behavior on opacity {
                animation: Appearance.animation.stateChange.numberAnimation.createObject(root)
            }
        }
    }
}
