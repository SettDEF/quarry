pragma Singleton
import QtQuick

// Same helpers the shell's ColorUtils exposes, so widget code ported from
// the quickshell config keeps working unchanged.
QtObject {
    id: root

    function clamp01(x) {
        return Math.max(0, Math.min(1, x));
    }

    function mix(color1, color2, percentage = 0.5) {
        const c1 = Qt.color(color1);
        const c2 = Qt.color(color2);
        return Qt.rgba(percentage * c1.r + (1 - percentage) * c2.r, percentage * c1.g + (1 - percentage) * c2.g, percentage * c1.b + (1 - percentage) * c2.b, percentage * c1.a + (1 - percentage) * c2.a);
    }

    function transparentize(color, percentage = 1) {
        const c = Qt.color(color);
        return Qt.rgba(c.r, c.g, c.b, c.a * (1 - percentage));
    }

    // Given a base and the colour we want to *appear* on top of it, work out
    // the overlay that produces it at the requested opacity. This is what lets
    // the layered surfaces stay correct when the window is translucent.
    function solveOverlayColor(baseColor, targetColor, overlayOpacity) {
        const base = Qt.color(baseColor);
        const target = Qt.color(targetColor);
        if (overlayOpacity <= 0)
            return Qt.rgba(target.r, target.g, target.b, 0);
        const invA = 1.0 - overlayOpacity;
        const r = (target.r - base.r * invA) / overlayOpacity;
        const g = (target.g - base.g * invA) / overlayOpacity;
        const b = (target.b - base.b * invA) / overlayOpacity;
        return Qt.rgba(clamp01(r), clamp01(g), clamp01(b), overlayOpacity);
    }

    function colorWithLightness(color, lightness) {
        const c = Qt.color(color);
        return Qt.hsla(c.hslHue, c.hslSaturation, clamp01(lightness), c.a);
    }

    // Pick whichever of two foregrounds reads better on `background`.
    function contrastingText(background, light, dark) {
        const c = Qt.color(background);
        // Rec. 709 relative luminance is good enough for a binary choice.
        const lum = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
        return lum > 0.5 ? dark : light;
    }
}
