import qs.modules.common
import QtQuick
import QtQuick.Effects

/*
 * A surface that floats above the app: the filter panel, the export sheet.
 *
 * They were plain rectangles with a border, which meant every one of them was
 * missing the same four things — you could not click away from it, Escape did
 * nothing, it appeared and vanished with no transition, and nothing separated
 * it from the gallery behind. Written once here, they all get it.
 *
 * Deliberately not `Popup`: these are laid out against the window rather than
 * against a mouse position, and Popup's own window/anchor machinery is more
 * than that needs.
 */
Item {
    id: root

    /*
     * Children go straight into the surface rectangle, which HAS NO LAYOUT.
     *
     * So anchor your own column (`anchors.fill: parent` + margins) the way
     * FilterPanel, ExportSheet and TargetSheet do. Declaring bare children with
     * `Layout.fillWidth` attached does nothing useful: they all stack at 0,0 and
     * take their natural width, which is how the settings panel ended up drawing
     * its title over its first section and running every sentence past the
     * rounded edge. Content taller than `surfaceHeight` is clipped, not
     * scrolled — put it in a Flickable if it can grow.
     */
    default property alias content: surface.data

    property bool open: false
    property real surfaceWidth: 360
    property real surfaceHeight: 420
    /// "center" or "topRight" — where the surface sits.
    property string placement: "center"
    property real inset: 12
    property real topInset: 74

    signal closed

    visible: opacity > 0
    opacity: root.open ? 1 : 0
    anchors.fill: parent
    /*
     * ABOVE THE APP, WHICHEVER ORDER IT WAS DECLARED IN.
     *
     * Siblings paint in declaration order, and a sheet is only above the
     * content if it happens to be written after it. cairn wrote its settings
     * sheet before the panel, so pressing the settings button dimmed nothing,
     * showed nothing, and swallowed the next click — a whole panel invisible
     * because of where its four lines sat in the file. "Floats above the app"
     * is what this widget is for, so it says so here rather than relying on
     * every caller to remember.
     */
    z: 50

    Behavior on opacity {
        NumberAnimation {
            duration: Appearance.animDur(180)
            easing.type: Easing.OutCubic
        }
    }

    function close() {
        root.open = false;
        root.closed();
    }

    // The scrim: dims what is behind, and takes the click that dismisses.
    Rectangle {
        anchors.fill: parent
        color: Appearance.colors.colLayer0Base
        opacity: root.open ? 0.45 : 0

        Behavior on opacity {
            NumberAnimation {
                duration: Appearance.animDur(120)
            }
        }

        /*
         * EVERY BUTTON, NOT JUST THE LEFT ONE.
         *
         * `acceptedButtons` defaults to Qt.LeftButton, so a RIGHT click was
         * never accepted here and fell straight through to the wall behind —
         * which opened the tile context menu underneath the open sheet. The
         * same class of bug the detail overlay had, in the one place that was
         * supposed to have solved it for everybody.
         *
         * Grab on press, too: the grab is what decides who else sees the
         * press, and without it a dismissing click also acted on whatever tile
         * happened to be under the scrim.
         */
        TapHandler {
            acceptedButtons: Qt.AllButtons
            gesturePolicy: TapHandler.ReleaseWithinBounds
            // Only the left button dismisses. A right click that closed the
            // panel would be a surprise; it is here to be swallowed, not to
            // become a second way out.
            onTapped: (point, button) => {
                if (button === Qt.LeftButton)
                    root.close();
            }
        }

        // Nothing behind a sheet should scroll, hover or react — the same
        // lesson the detail overlay learned by not doing it.
        WheelHandler {
            enabled: root.open
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: event => event.accepted = true
        }

        HoverHandler {
            enabled: root.open
            cursorShape: Qt.ArrowCursor
        }
    }

    /*
     * The shadow is drawn behind the surface, not applied to it.
     *
     * `layer.enabled` + MultiEffect renders the whole panel into an offscreen
     * texture first, which is a real cost for a decoration. RectangularShadow
     * draws the shape directly — depth is what says "above", and a one-pixel
     * border does not.
     */
    RectangularShadow {
        anchors.fill: surface
        radius: surface.radius
        blur: 34
        spread: 2
        offset: Qt.vector2d(0, 8)
        color: Qt.rgba(0, 0, 0, 0.5)
        opacity: root.open ? 1 : 0
        scale: surface.scale

        Behavior on opacity {
            NumberAnimation {
                duration: Appearance.animDur(120)
            }
        }
    }

    Rectangle {
        id: surface

        width: root.surfaceWidth
        height: root.surfaceHeight
        radius: Appearance.rounding.large
        color: Appearance.colors.colLayer1
        border.width: 1
        border.color: Appearance.colors.colLayer0Border
        clip: true

        x: root.placement === "topRight" ? root.width - width - root.inset : (root.width - width) / 2
        y: root.placement === "topRight" ? root.topInset : (root.height - height) / 2

        // Rises into place rather than appearing: a surface that pops in with
        // no transition reads as a glitch, especially over a moving gallery.
        /*
         * A drawer arrives from its edge. Scaling in from the middle is right
         * for a dialog and wrong for a panel attached to the side of the window,
         * which should look like it slid out from there.
         */
        transform: Translate {
            x: root.placement === "topRight" && !root.open ? 28 : 0
            Behavior on x {
                NumberAnimation {
                    duration: Appearance.animDur(220)
                    easing.type: Easing.OutCubic
                }
            }
        }

        scale: root.placement === "topRight" ? 1 : (root.open ? 1 : 0.97)
        Behavior on scale {
            NumberAnimation {
                duration: Appearance.animDur(140)
                easing.type: Easing.OutCubic
            }
        }

        // Clicks inside must not reach the scrim behind it — or the gallery
        // behind that. All buttons, for the same reason the scrim takes them:
        // a right click on the panel body was reaching the wall and opening a
        // tile menu under the surface it was aimed at.
        TapHandler {
            acceptedButtons: Qt.AllButtons
            gesturePolicy: TapHandler.WithinBounds
        }
    }

    Keys.onEscapePressed: root.close()
    focus: root.open
}
