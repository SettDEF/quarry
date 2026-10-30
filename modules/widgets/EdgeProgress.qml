import qs.modules.common
import QtQuick
import QtQuick.Shapes

/*
 * AN INDETERMINATE PROGRESS STRIP THAT RIDES A ROUNDED EDGE.
 *
 * A browser's loading line is a straight bar because a browser's viewport has
 * square corners. This one sits on the top edge of a rounded card, and a
 * straight bar there has to stop short at both ends — inset by the corner
 * radius, so it ends in mid-air a dozen pixels before the card does and reads
 * as a bar that was placed badly rather than as the card's own edge lighting up.
 *
 * So the strip IS the edge: a stroked path up through the left corner's curve,
 * across the top, and down through the right corner's, with a lit segment
 * travelling along it. At the ends it bends away out of sight, which is what
 * makes it belong to the card.
 *
 * Built on the same Shape/CurveRenderer path as RoundedCorners, for the same
 * reason given there — a segmented arc has visible flats at this size, and
 * `layer.enabled` would render the card it decorates into a texture every frame
 * to light up three pixels.
 */
Item {
    id: root

    /// Whether anything is on its way. The strip fades rather than blinks.
    property bool active: false
    /// The corner radius to follow. Match the card's own, or the curve and the
    /// edge part company.
    property real radius: Appearance.rounding.large
    property real thickness: 3
    property color colour: Appearance.colors.colPrimary
    /// How much of the edge is lit at once, as a fraction of the whole path.
    property real litFraction: 0.28
    property int cycleMs: 1300

    /*
     * The stroke is centred on the path, so the path runs half a stroke inside
     * the edge and the arcs are tightened to match. Without the inset the outer
     * half of the line hangs off the card and is clipped to a flat-topped
     * 1.5px smear along the straight run.
     */
    readonly property real _inset: root.thickness / 2
    readonly property real _arc: Math.max(0, root.radius - root._inset)
    /// Two quarter circles plus the straight run between them — the length the
    /// dash pattern is measured against.
    readonly property real _pathLength: Math.PI * root._arc + Math.max(0, root.width - root.radius * 2)
    /*
     * `dashPattern` and `dashOffset` are in units of the PEN WIDTH, not pixels.
     * Reading them as pixels gives a pattern `thickness` times too short, which
     * looks like a dotted line rather than one travelling segment.
     */
    readonly property real _lit: Math.max(1, root._pathLength * root.litFraction / root.thickness)
    readonly property real _gap: Math.max(1, root._pathLength / root.thickness)

    /*
     * Tall enough to CONTAIN the arcs, not just the line.
     *
     * At `thickness` the item is 3px and the corner curves run down to `radius`
     * — outside its bounds, where any clipping ancestor cuts them off and the
     * strip goes back to being the flat bar this component exists to replace.
     */
    implicitHeight: root.radius + root.thickness
    opacity: root.active ? 1 : 0
    visible: opacity > 0
    // Decoration over the pictures, never in front of a sheet or a menu.
    z: 60

    /// The path, given once and stroked twice — as the dim track and as the lit
    /// segment. Two copies of the arcs would be two chances to get them out of
    /// step by a pixel.
    component EdgePath: ShapePath {
        fillColor: "transparent"
        strokeWidth: root.thickness
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin

        startX: root._inset
        startY: root.radius

        PathArc {
            x: root.radius
            y: root._inset
            radiusX: root._arc
            radiusY: root._arc
            direction: PathArc.Clockwise
        }

        PathLine {
            x: Math.max(root.radius, root.width - root.radius)
            y: root._inset
        }

        PathArc {
            x: Math.max(root.radius, root.width - root._inset)
            y: root.radius
            radiusX: root._arc
            radiusY: root._arc
            direction: PathArc.Clockwise
        }
    }

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        asynchronous: false
        // The strip is three pixels tall and its own height is 0 in the layout,
        // so it must not be asked to contain the curve it draws.
        clip: false

        // The unlit edge, so the strip reads as a track with something moving
        // along it rather than as a stray mark crossing the corner.
        EdgePath {
            strokeColor: ColorUtils.transparentize(root.colour, 0.82)
        }

        EdgePath {
            id: lit

            strokeColor: root.colour
            strokeStyle: ShapePath.DashLine
            // One lit run, then a gap as long as the whole edge — so exactly one
            // segment is ever on the path and it sweeps rather than marching.
            dashPattern: [root._lit, root._gap]

            /*
             * Counting DOWN, because a rising `dashOffset` slides the pattern
             * back towards the path's start — the segment travelled right to
             * left, against every progress indicator anyone has seen.
             */
            NumberAnimation on dashOffset {
                running: root.visible
                from: root._lit + root._gap
                to: 0
                duration: root.cycleMs
                loops: Animation.Infinite
                easing.type: Easing.InOutCubic
            }
        }
    }

    // Quick to appear, unhurried to leave: a strip that vanishes the instant a
    // page lands flickers on every page of a scroll.
    Behavior on opacity {
        NumberAnimation {
            duration: Appearance.animDur(root.active ? 120 : 420)
        }
    }
}
