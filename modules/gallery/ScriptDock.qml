import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

/*
 * A SCRIPT'S CONTROLS, ON SCREEN — the shape Rodded's autoscroll dock has.
 *
 * Scripts were keys-only, and a key you have to already know about is a
 * feature nobody finds: autoscroll has had nine speeds since the day it was
 * written and the only way to learn that was to open the file.
 *
 * WHAT RODDED'S DOCK GETS RIGHT, AND WHY EACH PART IS HERE
 *
 *   · A pill at the bottom centre that SAYS what it does at rest: its name and
 *     a one-line summary of its settings. The controls come out on hover
 *     (inline in the player they stay out), so a resting dock is not a toolbar.
 *   · THE PRIMARY CONTROL IS RIGHTMOST AND NEVER MOVES. Everything else slides
 *     out from under it, so the button you press twice a minute stays where
 *     your pointer left it instead of walking away as the bar grows.
 *   · The housekeeping — here, hiding the dock — appears ONLY ON HOVER, so a
 *     resting dock reads as a control and not as a toolbar.
 *   · It sits slightly back at rest (0.92) so it does not compete with the
 *     pictures it is scrolling.
 *
 * WHAT A SCRIPT CANNOT DO HERE
 *
 * It does not build this. It hands over a DESCRIPTION — "a toggle called
 * Scroll, a slider called px/s" — and the app draws its own controls from it.
 * That is why a dock looks like the rest of the app, and why a script with
 * `@grant dock` still cannot reach the window it is drawn in.
 */
Rectangle {
    id: root

    /// One entry from `Scripts.docks()`.
    required property var dock

    /*
     * The one control that is always on screen: whatever the script marked
     * `primary`, else its first toggle — which for both shipped docks is the
     * thing the script is actually for. Everything else is an extra.
     */
    readonly property var primary: {
        const items = root.dock.items;
        const marked = items.find(i => i.primary === true);
        if (marked)
            return marked;

        const toggle = items.find(i => i.kind === "toggle");
        return toggle ? toggle : (items.length > 0 ? items[items.length - 1] : null);
    }
    readonly property bool running: !!root.primary && root.primary.value === true
    /// What the dock says about itself when nothing is hovering it.
    readonly property string state: {
        const said = root.dock.items.find(i => i.kind === "label");
        if (said)
            return said.label;

        return root.running ? "running" : "idle";
    }
    /// One line under the title: slider values, labels and lit toggles, then on/off.
    readonly property string summary: {
        const parts = [];
        for (const i of root.dock.items) {
            if (root.primary && i.id === root.primary.id)
                continue;
            if (i.kind === "slider")
                parts.push(`${Math.round(Number(i.value) || 0)} ${i.label}`);
            else if (i.kind === "label")
                parts.push(i.label);
            else if (i.kind === "toggle" && i.label.length > 0 && i.value === true)
                parts.push(i.label.toLowerCase());
        }
        parts.push(root.running ? "on" : "off");
        return parts.join(" · ");
    }
    /// Calm at rest (title, summary, play); the controls come out under the pointer.
    /// Inline in the player's bar they stay out, as before.
    readonly property bool expanded: root.inline || barHover.hovered

    /*
     * SLIM, because it floats OVER the pictures.
     *
     * At 56 tall with 26 of side padding it was a bar rather than a control,
     * and it sits on top of the wall it is scrolling — every pixel of it is a
     * pixel of picture you cannot see. The controls inside are 32 high, so the
     * chrome around them was doing most of the covering.
     */
    /// Padding either side of the controls. The width is built from it so the
    /// two cannot disagree.
    readonly property int pad: 9

    /*
     * INLINE, when the dock is sitting in someone else's bar.
     *
     * The video controls have their own pill, their own background and their
     * own row of 32px buttons — a second pill inside it reads as a widget that
     * wandered in. In this mode the chrome goes: no background, no border, no
     * running outline, no title. The controls themselves are untouched, so a
     * script or an extension writes one dock and it is at home in both places.
     */
    property bool inline: false

    implicitWidth: strip.implicitWidth + (root.inline ? 0 : root.pad * 2)
    implicitHeight: root.inline ? 36 : 48
    radius: Appearance.rounding.full
    antialiasing: true
    color: root.inline ? "transparent" : Appearance.colors.colSurfaceContainerHigh
    border.width: root.inline ? 0 : 1
    border.color: ColorUtils.transparentize(Appearance.colors.colOutlineVariant, 0.4)

    Behavior on opacity {
        NumberAnimation {
            duration: Appearance.animDur(220)
        }
    }

    // The width changes as the extras appear, and it is the one thing on this
    // bar that moves — so it moves on the expressive spatial curve rather than
    // snapping the whole pill wider under the pointer.
    Behavior on implicitWidth {
        NumberAnimation {
            duration: Appearance.animDur(260)
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Appearance.animationCurves.expressiveDefaultSpatial
        }
    }

    HoverHandler {
        id: barHover
    }

    /*
     * THE DOCK EATS ITS OWN CLICKS.
     *
     * It floats over the wall, and a Rectangle does not take input — so every
     * press that missed a button went straight through to the picture
     * underneath and opened it. Reaching for the speed slider opened whatever
     * happened to be behind the dock, which reads as the app opening things at
     * random.
     *
     * Declared BEFORE the controls so they stay on top of it: in QML a later
     * sibling is drawn and hit-tested above an earlier one, so this catches
     * only the gaps and the padding.
     */
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        hoverEnabled: true
        onWheel: wheel => wheel.accepted = true
    }

    RowLayout {
        id: strip

        anchors.right: parent.right
        /*
         * HALF THE PADDING, because `implicitWidth` is `strip + 18`.
         *
         * It was 13 against a width of `strip + 26` — symmetric. Slimming the
         * dock to +18 without touching this left 5px on the left and 13 on the
         * right, so the whole strip, and the primary button at the end of it,
         * sat visibly off-centre. Tie the two together in one place or they
         * drift apart again the next time either is adjusted.
         */
        anchors.rightMargin: root.pad
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2

        // Housekeeping first, so it is furthest from the thumb.
        IconButton {
            visible: barHover.hovered && !root.inline
            icon: "close"
            tooltip: `Hide ${root.dock.title}`
            size: 32
            iconSize: 17
            // Switched on from the overflow menu, and switched off from the
            // thing itself: hunting back through a menu to close what is in
            // front of you is what makes a person leave it open instead.
            onClicked: Scripts.setDockShowing(root.dock.id, false)
        }

        IconButton {
            visible: barHover.hovered && !root.inline
            icon: "tune"
            tooltip: "Settings for " + (root.dock.title || "this script")
            size: 32
            iconSize: 17
            // Straight to THIS script's settings — the button is on the thing
            // it configures, so landing on a list of everything is a step the
            // press already paid for. See SettingsPanel.showScript.
            onClicked: {
                if (Shell.settingsPanel)
                    Shell.settingsPanel.showScript(root.dock.id);

            }
        }

        // Who this is: its mark in a tonal circle (primary while running), the name
        // over a one-line summary of its settings.
        Rectangle {
            visible: !root.inline
            Layout.preferredWidth: 32
            Layout.preferredHeight: 32
            radius: 16
            color: root.running ? Appearance.colors.colPrimaryContainer : Appearance.colors.colLayer2

            Behavior on color {
                ColorAnimation {
                    duration: Appearance.animDur(200)
                }
            }

            MaterialSymbol {
                anchors.centerIn: parent
                text: root.dock.icon
                iconSize: 18
                color: root.running ? Appearance.colors.colOnPrimaryContainer : Appearance.colors.colOnLayer1
            }
        }

        Column {
            visible: !root.inline
            Layout.leftMargin: 6
            Layout.rightMargin: 6
            spacing: -1

            StyledText {
                text: root.dock.title
                font.pixelSize: Appearance.font.pixelSize.smaller
                font.weight: Font.DemiBold
                color: Appearance.colors.colOnSurface
            }

            StyledText {
                // Open, the controls show these values themselves.
                visible: !root.expanded
                text: root.summary
                font.pixelSize: Appearance.font.pixelSize.smallest
                color: Appearance.colors.colSubtext
            }
        }

        // ── everything the script asked for, except its primary ──────────────
        Repeater {
            /*
             * By id, NOT by identity.
             *
             * `dock.items` crosses the QML `var` boundary on every read, so
             * two reads hand back two different JS arrays — `i !== root.primary`
             * was true for every item including the primary, and the dock drew
             * its main control twice: once in the strip and once as the big
             * button beside it.
             */
            model: Scripts.revision >= 0 && root.primary ? root.dock.items.filter(i => i.id !== root.primary.id) : (root.dock.items || [])

            delegate: RowLayout {
                id: control

                required property var modelData

                visible: root.expanded
                spacing: 4

                IconButton {
                    visible: control.modelData.kind === "button" || (control.modelData.kind === "toggle" && control.modelData.label.length === 0)
                    icon: control.modelData.icon.length > 0 ? control.modelData.icon : "play_arrow"
                    tooltip: control.modelData.label
                    size: 32
                    iconSize: 17
                    toggled: control.modelData.kind === "toggle" && control.modelData.value === true
                    onClicked: Scripts.runDock(root.dock.id, control.modelData.id, control.modelData.kind === "toggle" ? !control.modelData.value : undefined)
                }

                RippleButton {
                    visible: control.modelData.kind === "toggle" && control.modelData.label.length > 0
                    /*
                     * 32, the same as every IconButton beside it.
                     *
                     * At 28 it sat four pixels short in a row of 32s, so the
                     * strip had two heights in it and read as controls dropped
                     * into a bar rather than as one control. Nothing else about
                     * the pill changes — it is the alignment that was wrong.
                     */
                    implicitHeight: 32
                    implicitWidth: toggleRow.implicitWidth + 20
                    buttonRadius: Appearance.rounding.full
                    toggled: control.modelData.value === true
                    // A chip you can see on the dock's own surface, filled when on.
                    colBackground: Appearance.colors.colSurfaceContainerHighest
                    colBackgroundToggled: Appearance.colors.colSecondaryContainer
                    onClicked: Scripts.runDock(root.dock.id, control.modelData.id, !control.modelData.value)

                    Row {
                        id: toggleRow

                        anchors.centerIn: parent
                        spacing: 5

                        MaterialSymbol {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: control.modelData.icon.length > 0
                            text: control.modelData.icon
                            iconSize: 16
                            color: control.modelData.value === true ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: control.modelData.label
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: control.modelData.value === true ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                        }

                    }

                }

                StyledSlider {
                    /*
                     * Wider, because the useful part of this range is the
                     * bottom of it. Autoscroll runs 10…340 px/s and is used at
                     * 40–120, so at 104px the whole working range was the first
                     * thirty pixels of the track and the control looked empty
                     * and broken at every speed anyone actually picks.
                     */
                    Layout.preferredWidth: 132
                    // The thin track the player uses: at S the low end drew as a lone square.
                    configuration: StyledSlider.Configuration.XS
                    visible: control.modelData.kind === "slider"
                    from: control.modelData.min
                    to: control.modelData.max
                    stepSize: control.modelData.step
                    value: Number(control.modelData.value) || 0
                    // `moved`, not `valueChanged`: the binding above writes this
                    // whenever the script sets it, and answering that would call
                    // the script back with the value it had just chosen.
                    onMoved: Scripts.runDock(root.dock.id, control.modelData.id, value)
                }

                StyledText {
                    Layout.minimumWidth: control.modelData.kind === "slider" ? 56 : 0
                    Layout.leftMargin: control.modelData.kind === "slider" ? 2 : 0
                    visible: control.modelData.kind === "label" || control.modelData.kind === "slider"
                    horizontalAlignment: Text.AlignHCenter
                    text: control.modelData.kind === "slider" ? `${Math.round(Number(control.modelData.value) || 0)} ${control.modelData.label}` : control.modelData.label
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    font.weight: Font.Medium
                    color: Appearance.colors.colOnSurface
                }

            }

        }

        // ── the primary: always visible, always rightmost ────────────────────
        IconButton {
            visible: !!root.primary
            icon: {
                if (!root.primary)
                    return "play_arrow";

                if (root.primary.kind !== "toggle")
                    return root.primary.icon.length > 0 ? root.primary.icon : "play_arrow";

                return root.running ? "pause" : (root.primary.icon.length > 0 ? root.primary.icon : "play_arrow");
            }
            tooltip: root.primary ? `${root.primary.label || root.dock.title} · ${root.state}` : ""
            /*
             * SIZED TO THE DOCK, not to the old one.
             *
             * 44 was right while the dock was 56 tall — it is exactly the dock's
             * height now, so the button filled it edge to edge with no chrome
             * around it and read as a blob rather than as a control.
             */
            size: root.inline ? 32 : 36
            iconSize: Appearance.font.pixelSize.large
            // Filled whatever its state: this is the thing the dock is for, and
            // a primary that is only a circle while active is a dock you have
            // to read before you can use it.
            toggled: true
            // The one strong colour on the dock: primary while running, tonal at rest.
            toggledColor: root.running ? Appearance.colors.colPrimary : Appearance.colors.colSecondaryContainer
            iconColor: root.running ? Appearance.colors.colOnPrimary : Appearance.colors.colOnSecondaryContainer
            Layout.leftMargin: 6
            onClicked: Scripts.runDock(root.dock.id, root.primary.id, root.primary.kind === "toggle" ? !root.primary.value : undefined)
        }

    }

}
