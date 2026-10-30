import qs.modules.common
import QtQuick
import QtQuick.Shapes

/*
 * MAKE A ROUNDED PANEL ACTUALLY ROUND.
 *
 * `clip: true` clips to an item's RECTANGLE. It has never respected `radius`,
 * and nothing in Qt Quick says so out loud — so a rounded panel with a picture
 * in it looks correct everywhere except its four corners, where the picture
 * squares off straight over the curve and the border. That is the "there is a
 * shape but the image gets through" bug, and it is invisible until something
 * bright is in a corner.
 *
 * The usual fix is `layer.enabled` with an OpacityMask, which renders the whole
 * panel — the entire gallery, every frame — into an offscreen texture to hide
 * four wedges of about 300 pixels each. This app has a frame budget; a
 * decoration does not get to spend it.
 *
 * So: four small filled shapes, one per corner, each the square corner minus
 * the quarter circle. Static geometry, no offscreen pass, and exact rather than
 * approximate. It works because what surrounds the panel is a known colour —
 * which is the one thing this needs told, and the reason `background` has no
 * default.
 */
Item {
    id: root

    /// The corner radius to cut to. Match the panel's own.
    property real radius: Appearance.rounding.large
    /// What is BEHIND the panel. The wedges are painted in it, so a wrong
    /// colour here shows up as four visible tabs rather than as nothing.
    required property color background
    /// Drawn over the wedges, so the outline stays crisp and unbroken. Set the
    /// width to 0 for no border.
    property color border: Appearance.colors.colLayer0Border
    property real borderWidth: 1

    anchors.fill: parent
    // Decoration: it must never eat a click meant for the pictures underneath.
    z: 100

    Repeater {
        // One wedge per corner, as (x, y, rotation). A square rotated about its
        // own centre maps corner onto corner, so one path serves all four.
        model: [
            { "hx": 0, "hy": 0, "turn": 0 },
            { "hx": 1, "hy": 0, "turn": 90 },
            { "hx": 1, "hy": 1, "turn": 180 },
            { "hx": 0, "hy": 1, "turn": 270 }
        ]

        delegate: Item {
            required property var modelData

            width: root.radius
            height: root.radius
            x: modelData.hx * (root.width - width)
            y: modelData.hy * (root.height - height)
            rotation: modelData.turn

            Shape {
                anchors.fill: parent
                // The curve renderer draws the arc as real geometry rather than
                // as a stack of line segments — at 12-16px a segmented arc has
                // visible flats along it.
                preferredRendererType: Shape.CurveRenderer
                asynchronous: false

                ShapePath {
                    fillColor: root.background
                    strokeWidth: 0

                    // Down the left edge, across the top, then back around the
                    // curve: the corner, minus the disc.
                    startX: 0
                    startY: root.radius
                    PathLine {
                        x: 0
                        y: 0
                    }
                    PathLine {
                        x: root.radius
                        y: 0
                    }
                    PathArc {
                        x: 0
                        y: root.radius
                        radiusX: root.radius
                        radiusY: root.radius
                        direction: PathArc.Counterclockwise
                    }
                }
            }
        }
    }

    // The outline, over the wedges. Drawing it here rather than on the panel
    // means the corners cannot cover the very border they exist to reveal.
    Rectangle {
        anchors.fill: parent
        color: "transparent"
        radius: root.radius
        border.width: root.borderWidth
        border.color: root.border
        visible: root.borderWidth > 0
        antialiasing: true
    }
}
