import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick

/*
 * ONE PICTURE ON THE BOARD.
 *
 * Holds its geometry in BOARD units and converts to screen only for drawing, so
 * a drag at 3× zoom moves the picture by the distance the pointer actually
 * travelled on the board rather than three times it.
 *
 * The geometry lives here rather than in the model while a gesture is running.
 * Writing every frame of a drag back through the daemon and re-reading it would
 * replace the very object being dragged, mid-drag; so the piece is the
 * authority while you are holding it and the daemon is told once, on release.
 */
Item {
    id: root

    required property var board
    required property var entry
    property var record: null

    signal picked(string id, bool additive)
    signal opened(var rec)
    signal menuRequested(var rec, real sceneX, real sceneY)
    signal movedBy(real dx, real dy)
    signal committed

    // Board-space geometry, seeded from the stored entry and owned from then on.
    property real bx: entry.x
    property real by: entry.y
    property real bw: entry.w > 0 ? entry.w : 420
    property real bh: entry.h > 0 ? entry.h : 315
    property real angle_: entry.angle
    property bool hflip: entry.hflip === true
    property bool vflip: entry.vflip === true
    property bool sharp: entry.sharp === true

    readonly property bool chosen: root.board.isSelected(root.entry.id)

    // Board coordinates, straight through. The canvas carries the view — see
    // `content` in GalleryBoard — so nothing here knows what the zoom is.
    x: root.bx
    y: root.by
    width: root.bw
    height: root.bh
    z: entry.z

    rotation: root.angle_

    function nudge(dx, dy) {
        root.bx += dx;
        root.by += dy;
    }

    function flip(horizontal) {
        if (horizontal)
            root.hflip = !root.hflip;
        else
            root.vflip = !root.vflip;
        root.commit();
    }

    function rotateBy(degrees) {
        root.angle_ = (root.angle_ + degrees) % 360;
        root.commit();
    }

    function scaleBy(factor) {
        root.resize(root.bw * factor, root.bh * factor);
    }

    /// Set both sides at once, about the centre. Growing from the top-left
    /// corner walks the picture away from where you are looking every time.
    function resize(w, h) {
        const cx = root.bx + root.bw / 2;
        const cy = root.by + root.bh / 2;
        root.bw = Math.max(40, w);
        root.bh = Math.max(30, h);
        root.bx = cx - root.bw / 2;
        root.by = cy - root.bh / 2;
    }

    /// Put this piece on top, and say what the new z is so the board can keep
    /// its counter moving. RIA raises on select and never persists it, so a
    /// saved board reopens stacked differently from the one you arranged.
    function raise_(z) {
        root.entry.z = z;
        root.z = z;
    }

    /// Tell the daemon where this ended up. Called on release, not per frame.
    function commit() {
        Catalog.placeOnBoard(root.entry.id, {
            "x": root.bx,
            "y": root.by,
            "w": root.bw,
            "h": root.bh,
            "angle": root.angle_,
            "hflip": root.hflip,
            "vflip": root.vflip,
            "z": root.entry.z,
            "sharp": root.sharp,
            /*
             * WITHOUT THIS, EVERY WRITE FORGOT THE GROUP.
             *
             * `place` takes the whole row, so a field left out of the payload
             * is not "unchanged" — it is written as its default. Membership was
             * therefore reset to none on every commit, which meant the moment a
             * picture was moved, resized, flipped or turned it silently fell
             * out of its container, and the reconcile that had just worked out
             * the right answer wrote 0 over it.
             */
            "container": root.entry.container || 0
        });
    }

    // A picture whose record has not arrived yet is a frame, not a hole: the
    // board knows where it goes before it knows what it looks like.
    Rectangle {
        anchors.fill: parent
        visible: !root.record
        color: Appearance.colors.colLayer1
        border.width: 1
        border.color: Appearance.colors.colOutlineVariant
    }

    /*
     * The step to ask for. Settling it — so a zoom does not throw away a
     * decoded picture on every ladder boundary it crosses — is ThumbImage's
     * job now, since a resizing window does exactly the same thing to the wall
     * and the fix belongs in one place rather than two.
     *
     * The board's ladder goes higher than a wall's: a wall draws hundreds of
     * tiles and must never ask for 4K, a board draws a handful and zooming into
     * one is the point. Costs nothing for small pictures — the daemon never
     * upscales, so asking 3840 of a 900px original returns 900px.
     */
    readonly property int wantedSize: {
        const want = Math.ceil(root.bw * root.board.zoom * (Screen.devicePixelRatio || 1));
        for (const step of [160, 320, 640, 1280, 1920, 2560, 3840])
            if (step >= want)
                return step;
        return 3840;
    }

    ThumbImage {
        id: picture
        anchors.fill: parent
        item: root.record
        size: root.wantedSize
        // A board holds a handful of pictures deliberately chosen, not a wall
        // of them — they must not queue behind each other.
        gated: false
        smoothing: !root.sharp
        // The picture fills the frame it was given: the frame's proportions
        // came from the picture in the first place, and a letterboxed
        // reference with grey bars around it is not what was arranged.
        fillMode: Image.PreserveAspectCrop

        transform: Scale {
            origin.x: picture.width / 2
            origin.y: picture.height / 2
            xScale: root.hflip ? -1 : 1
            yScale: root.vflip ? -1 : 1
        }
    }

    // Selected reads as an outline rather than a tint: a tint over a reference
    // picture changes the colours, which is the one thing reference is for.
    Rectangle {
        anchors.fill: parent
        color: "transparent"
        // Divided by the zoom so the outline is two SCREEN pixels at any zoom —
        // scaled with everything else it would be invisible zoomed out and a
        // slab zoomed in.
        border.width: root.chosen ? 2 / root.board.zoom : 0
        border.color: Appearance.colors.colPrimary
        visible: root.chosen
    }

    MouseArea {
        id: grab
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        hoverEnabled: true

        property real lastX: 0
        property real lastY: 0
        property bool dragging: false
        property bool scaling: false
        property bool ratioLocked: false
        property real startX: 0
        property real startY: 0
        property real startW: 0
        property real startH: 0
        property bool rotating: false
        property real startAngle: 0
        property bool fromTouch: false
        /// Whether this gesture has travelled far enough to BE a gesture.
        /// Both bugs below turn on it: a press that has moved is never a menu,
        /// and a press that has not moved is never a scale.
        property bool moved: false

        /*
         * THE LONG PRESS, RUN BY US.
         *
         * `onPressAndHold` fires on Qt's schedule and there is no way to call
         * it off — so every attempt to suppress it during a drag was a guess
         * evaluated after the fact, and a slow drag still popped the menu. A
         * timer we start and stop cannot fire once the gesture has become a
         * drag, because we stop it the moment it does.
         */
        Timer {
            id: hold
            interval: 500
            onTriggered: {
                if (grab.moved || !grab.fromTouch)
                    return;
                grab.dragging = false;
                grab.scaling = false;
                grab.rotating = false;
                root.menuRequested(root.record, grab.startX, grab.startY);
            }
        }

        onPressed: mouse => {
            grab.lastX = mouse.x;
            grab.lastY = mouse.y;
            grab.startX = mouse.x;
            grab.startY = mouse.y;
            grab.moved = false;
            grab.fromTouch = mouse.source !== Qt.MouseEventNotSynthesized;
            // Only a finger needs it: a mouse has a second button, and a mouse
            // held still for half a second is usually someone thinking.
            if (grab.fromTouch)
                hold.restart();
            root.picked(root.entry.id, (mouse.modifiers & Qt.ShiftModifier) !== 0);

            if (mouse.button === Qt.RightButton) {
                // RIA's right-drag-to-scale, which is genuinely good: it needs
                // no handles, so it works at any size and never puts a grab
                // target outside a picture that is bigger than the window.
                // Shift locks the proportions, the way RIA's does.
                grab.scaling = true;
                grab.ratioLocked = (mouse.modifiers & Qt.ShiftModifier) !== 0;
                grab.startX = mouse.x;
                grab.startY = mouse.y;
                grab.startW = root.bw;
                grab.startH = root.bh;
                return;
            }
            // Rotating is a drag with R held rather than a mode, so it can be
            // done and undone inside one gesture while watching the result.
            if (root.board.rotateHeld) {
                grab.rotating = true;
                grab.startAngle = root.angle_;
                grab.startX = mouse.x;
                return;
            }
            grab.dragging = true;
            // Raise on select. The one place RIA's behaviour is right and its
            // persistence is not — this is written down on release.
            root.board.raiseSelection();
        }

        onPositionChanged: mouse => {
            /*
             * The threshold is in SCREEN pixels.
             *
             * These coordinates are board units — the piece lives inside the
             * scaled layer — so a flat 4 meant 12 screen pixels at 3× zoom and
             * one pixel at 0.3×. Dividing by the zoom makes "has it moved yet"
             * mean the same thing however far in you are.
             */
            const slop = 4 / root.board.zoom;
            if (Math.abs(mouse.x - grab.startX) > slop || Math.abs(mouse.y - grab.startY) > slop) {
                grab.moved = true;
                // A drag is not a long press. Stopping the timer is the only
                // reliable way to say so — `pressAndHold` cannot be cancelled,
                // it can only be reacted to after it has already fired.
                hold.stop();
            }

            if (grab.rotating) {
                let next = grab.startAngle + (mouse.x - grab.startX) / 3;
                // Shift snaps to 15°, which is what makes a row of reference
                // line up rather than nearly line up.
                if (mouse.modifiers & Qt.ShiftModifier)
                    next = Math.round(next / 15) * 15;
                root.board.eachSelected(p => { p.angle_ = next; });
                return;
            }
            if (grab.scaling) {
                if (grab.ratioLocked) {
                    const factor = 1 + (mouse.y - grab.startY) / 200;
                    root.board.eachSelected(p => p.scaleTo(grab.startW, factor));
                    return;
                }
                // Free: each axis follows its own direction, so a picture can
                // be squared up or stretched to match a neighbour.
                const fw = 1 + (mouse.x - grab.startX) / 200;
                const fh = 1 + (mouse.y - grab.startY) / 200;
                root.board.eachSelected(p => p.resize(
                    Math.max(40, grab.startW * Math.max(0.05, fw)),
                    Math.max(30, grab.startH * Math.max(0.05, fh))));
                return;
            }
            if (!grab.dragging)
                return;
            // Already board units: a MouseArea inside the scaled layer reports
            // its own unscaled coordinates, so the zoom is divided out for us.
            root.movedBy(mouse.x - grab.lastX, mouse.y - grab.lastY);
        }

        onReleased: mouse => {
            hold.stop();
            const wasScaling = grab.scaling;
            const wasDragging = grab.dragging;
            const wasRotating = grab.rotating;
            grab.scaling = false;
            grab.dragging = false;
            grab.rotating = false;

            /*
             * A RIGHT CLICK IS A MENU. A RIGHT DRAG IS A SCALE.
             *
             * `scaling` is armed on every right press, because a scale has to
             * start somewhere — so treating "was scaling" as "was a gesture"
             * meant a right CLICK, which never moved, was swallowed as a
             * zero-distance scale and the piece menu could not be opened with a
             * mouse at all.
             */
            if (mouse.button === Qt.RightButton && !grab.moved) {
                root.menuRequested(root.record, mouse.x, mouse.y);
                return;
            }
            if (wasScaling || wasDragging || wasRotating) {
                root.committed();
                return;
            }
        }

        onDoubleClicked: {
            if (root.record)
                root.opened(root.record);
        }

    }

    /// Scale relative to the width the gesture started from, so a long drag
    /// does not compound into an exponential explosion.
    function scaleTo(startW, factor) {
        const target = Math.max(40, startW * Math.max(0.05, factor));
        root.scaleBy(target / root.bw);
    }
}
