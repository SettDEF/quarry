import qs.modules.common
import QtQuick
import QtQuick.Layouts

/*
 * A small − value + control for a number with a handful of sensible values.
 *
 * Not a slider: the range here is 0..8 and every step is meaningful, so a
 * slider would ask you to aim at a 12-pixel target to say "three pages".
 * Not a text field either -- there is nothing to type that the two buttons
 * cannot say faster, and a field invites a value the daemon will refuse.
 */
RowLayout {
    id: root

    property int value: 0
    property int from: 0
    property int to: 8
    /// What to draw. Separate from `value` because 0 usually means "default",
    /// and a control reading "0" when it means "auto" is a lie.
    property string display: `${root.value}`

    signal changed_(int value)

    spacing: 2

    component Step: Rectangle {
        id: step

        required property string glyph
        required property bool canPress

        signal pressed_

        implicitWidth: 28
        implicitHeight: 28
        radius: Appearance.rounding.small
        color: !step.canPress ? ColorUtils.transparentize(Appearance.colors.colLayer3, 1)
            : stepTap.pressed ? Appearance.colors.colLayer3Active
            : stepHover.hovered ? Appearance.colors.colLayer3Hover
            : Appearance.colors.colLayer3
        Behavior on color {
            animation: Appearance.animation.stateChange.colorAnimation.createObject(step)
        }

        HoverHandler {
            id: stepHover
            enabled: step.canPress
            cursorShape: Qt.PointingHandCursor
        }
        TapHandler {
            id: stepTap
            enabled: step.canPress
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: step.pressed_()
        }

        MaterialSymbol {
            anchors.centerIn: parent
            text: step.glyph
            iconSize: Appearance.font.pixelSize.small
            // Dimmed, not recoloured: `colLayer2Disabled` is so close to the
            // card behind it that a stepper at its limit looked cut in half.
            color: Appearance.colors.colOnLayer1
            opacity: step.canPress ? 1 : 0.3
        }
    }

    Step {
        glyph: "remove"
        canPress: root.value > root.from
        onPressed_: root.changed_(root.value - 1)
    }

    StyledText {
        Layout.preferredWidth: 42
        horizontalAlignment: Text.AlignHCenter
        text: root.display
        font.family: Appearance.font.family.monospace
        font.pixelSize: Appearance.font.pixelSize.smaller
        color: Appearance.colors.colOnLayer1
    }

    Step {
        glyph: "add"
        canPress: root.value < root.to
        onPressed_: root.changed_(root.value + 1)
    }
}
