import qs.modules.common
import QtQuick

/*
 * Material Symbols Rounded, tuned to Google's current (Gemini, 2026) look:
 * thin, rounded outlines that thicken slightly when filled.
 *
 * The icon set Gemini draws with is Google's own and not published; the public
 * variable font carries the same shapes, and its weight axis is what separates
 * that look from the heavier default. `fill` still animates outlined → filled,
 * which is how M3 marks a selected state, and the stroke follows it from 300 to
 * 400 so a filled icon does not look bolder than its neighbours by more than a
 * selected one should.
 */
StyledText {
    id: root

    property real iconSize: Appearance.font.pixelSize.normal
    property real fill: 0
    // Rounding keeps the variable-axis remap from re-running on every frame of
    // the fill animation, which otherwise spikes memory.
    readonly property real truncatedFill: Number(fill.toFixed(1))

    /*
     * THE OPTICAL SIZE IS SNAPPED, FOR THE SAME REASON `fill` IS ROUNDED.
     *
     * Every distinct set of variable-axis values is a separate font engine in
     * Qt, and each engine MAPS THE WHOLE FONT FILE AGAIN. Material Symbols
     * Rounded is 14.6 MB, so a handful of icon sizes is a hundred megabytes of
     * the same file mapped over and over — measured in a running quarry: 12
     * mappings, 167 MB, out of 370 MB resident.
     *
     * `fill` was already rounded for this; `opsz` was left continuous and takes
     * a value from every icon size in the app. Snapping it to a ladder cannot
     * be seen — opsz is a subtle optical correction and the steps are within a
     * few pixels — and it collapses the axis combinations that cost the memory.
     */
    readonly property real snappedOpsz: {
        const want = Math.max(20, Math.min(48, root.iconSize));
        const ladder = [20, 24, 32, 40, 48];
        let best = ladder[0];
        for (let i = 1; i < ladder.length; i++) {
            if (Math.abs(ladder[i] - want) < Math.abs(best - want))
                best = ladder[i];

        }
        return best;
    }
    /// The outline's stroke weight; 300 is the thin rounded look.
    property real strokeWeight: 300

    renderType: Text.NativeRendering
    color: Appearance.colors.colOnLayer1

    font {
        hintingPreference: Font.PreferNoHinting
        family: Appearance.font.family.iconMaterial
        // A light stroke reads smaller than a regular one at the same size, so
        // the glyph is drawn a size up: the icon keeps its visual weight in the
        // rows and buttons that were sized around the heavier default.
        pixelSize: Math.round(root.iconSize * 1.12)
        variableAxes: ({
                "FILL": root.truncatedFill,
                "wght": root.strokeWeight + 100 * root.truncatedFill,
                "opsz": root.snappedOpsz
            })
    }

    Behavior on fill {
        NumberAnimation {
            duration: Appearance.animation.elementMoveFast.duration
            easing.type: Appearance.animation.elementMoveFast.type
            easing.bezierCurve: Appearance.animation.elementMoveFast.bezierCurve
        }
    }

    Behavior on color {
        animation: Appearance.animation.stateChange.colorAnimation.createObject(this)
    }
}
