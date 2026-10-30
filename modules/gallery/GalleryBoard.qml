import qs.modules.common
import qs.modules.widgets
import qs.services
import Quickshell
import QtQuick.Layouts
import QtQuick

/*
 * A REFERENCE BOARD — pictures arranged, rather than listed.
 *
 * Every other layout here answers "which picture". This answers "how do these
 * sit next to each other", which is the question an artist actually asks of
 * reference material and the one a grid cannot answer at all: a colour study
 * needs three pictures touching, at sizes you chose, in an order you chose.
 *
 * The shape is RIA's (github.com/mckset/RIA) and PureRef's before it: an
 * infinite canvas you pan and zoom, with pictures placed on it freely. What is
 * different is what sits underneath. RIA is a folder browser with tags, and it
 * links both tags and boards to ABSOLUTE PATHS — move a folder and the tags are
 * silently dropped, because `Load` discards any path that fails `stat`. Quarry
 * already has a far better library than the one RIA had to build, and its ids
 * survive a re-crawl, so a board here survives the catalogue being rebuilt
 * underneath it.
 *
 * Geometry is in BOARD units. The view has its own offset and zoom, so a board
 * laid out on a 4K screen opens correctly on a laptop rather than off-canvas.
 */
Item {
    id: root

    signal activated(var item, int index)
    signal contextRequested(var item, real sceneX, real sceneY)

    /// Board-space offset of the viewport's top-left, and the zoom.
    property real viewX: 0
    property real viewY: 0
    property real zoom: 1

    readonly property real minZoom: 0.1
    readonly property real maxZoom: 4

    /// Held while R is down, which turns a drag into a rotation. A modifier
    /// rather than a mode: you can start, watch, and abandon it in one gesture.
    property bool rotateHeld: false

    /// The next z to hand out. Raising on select needs a counter that only ever
    /// goes up, or two raises in a row can land on the same layer.
    property int topZ: 1

    /// Ids currently selected. A list rather than a single item because the
    /// whole point of arranging is moving several things at once.
    property var selection: []

    function isSelected(id) {
        return root.selection.indexOf(id) >= 0;
    }

    function selectOnly(id) {
        root.selection = id ? [id] : [];
    }

    function toggleSelected(id) {
        const at = root.selection.indexOf(id);
        const next = root.selection.slice();
        if (at >= 0)
            next.splice(at, 1);
        else
            next.push(id);
        root.selection = next;
    }

    /*
     * One transparency, labelled, with its value written next to it.
     *
     * `id: fadeRow` rather than `parent`: inside an inline component `parent`
     * is the VISUAL parent — the layout it happens to be sitting in — not the
     * component itself, so every one of these read its label off whatever
     * contained it.
     */
    component FadeRow: RowLayout {
        id: fadeRow

        required property string label
        required property real value
        required property real floor

        signal moved_(real value)

        Layout.fillWidth: true
        spacing: 10

        StyledText {
            Layout.preferredWidth: 84
            text: fadeRow.label
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colOnLayer4
        }

        StyledSlider {
            Layout.fillWidth: true
            configuration: StyledSlider.Configuration.XS
            from: fadeRow.floor
            to: 1
            value: fadeRow.value
            onMoved: fadeRow.moved_(value)
        }

        StyledText {
            Layout.preferredWidth: 38
            horizontalAlignment: Text.AlignRight
            text: `${Math.round(fadeRow.value * 100)}%`
            font.family: Appearance.font.family.monospace
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
        }
    }

    // ── board space ↔ screen space ──────────────────────────────────────────

    function toScreenX(bx) {
        return (bx - root.viewX) * root.zoom;
    }
    function toScreenY(by) {
        return (by - root.viewY) * root.zoom;
    }
    function toBoardX(sx) {
        return sx / root.zoom + root.viewX;
    }
    function toBoardY(sy) {
        return sy / root.zoom + root.viewY;
    }

    /*
     * ZOOM ABOUT A POINT, OVER TIME.
     *
     * Two problems, and they are the same problem. Zooming about the ORIGIN
     * walks whatever you were looking at off the screen, so you zoom in and
     * then go hunting for your work. And setting the zoom in one step made
     * every wheel notch a jump — a 12% snap with nothing in between, which on
     * an infinite canvas reads as the board teleporting rather than moving.
     *
     * So the zoom is animated, and the view offset is DERIVED from it on every
     * frame rather than computed once alongside it. That is the part that is
     * easy to get wrong: if the offset is set once and the zoom then animates
     * toward its target, the anchor drifts across the whole animation and the
     * thing under the cursor slides away. `onZoomChanged` re-solves it each
     * frame, so the anchor is nailed down for the whole animation.
     */
    /*
     * WHERE THE ZOOM IS GOING, as opposed to where it is.
     *
     * `zoom` is the animated value, so mid-flight it is some number between the
     * old one and the new. Computing the next step from it — which is what
     * `zoom * factor` did — means a second wheel notch arriving during the
     * first one's animation compounds off a half-finished value. Spin the wheel
     * quickly and each notch does less than the one before, so the board seems
     * to resist you exactly when you are asking for a lot of zoom.
     *
     * Steps are taken from the TARGET instead, so five fast notches are five
     * whole notches and the animation simply chases the sum.
     */
    property real zoomTarget: 1

    property real anchorSx: 0
    property real anchorSy: 0

    /// Off while fingers are on the glass — a pinch is already continuous, and
    /// animating toward a target that moves every frame lags the fingers.
    property bool smoothZoom: true

    Behavior on zoom {
        enabled: root.smoothZoom
        NumberAnimation {
            id: zoomAnim
            duration: Appearance.animDur(160)
            // Out, not InOut: a zoom should leave immediately when you ask and
            // settle gently, not hesitate first.
            easing.type: Easing.OutCubic
        }
    }

    /// The zoom this view has already been adjusted for.
    property real _appliedZoom: 1

    /*
     * THE ZOOM MOVES THE VIEW. IT DOES NOT OWN IT.
     *
     * This used to set the view ABSOLUTELY from the anchor every frame, which
     * made zoom and pan fight over the same two numbers: whichever ran last
     * won, so panning during a zoom was a tug of war and the only way out was
     * to cancel one of them. Cancelling works and feels exactly like what it
     * is — the board locking up and refusing one of the two things you are
     * doing.
     *
     * Applying the DIFFERENCE instead means the zoom only ever contributes the
     * shift needed to hold its anchor still, and a pan is free to add whatever
     * it likes on top. They compose. You can pan through a zoom, zoom through
     * a pan, and neither has to stop for the other.
     *
     *   view = anchor_board - anchor_screen / zoom
     *   Δview = -anchor_screen · (1/zoom_new - 1/zoom_old)
     */
    onZoomChanged: {
        const k = (1 / root.zoom) - (1 / root._appliedZoom);
        root._appliedZoom = root.zoom;
        root.viewX -= root.anchorSx * k;
        root.viewY -= root.anchorSy * k;
    }

    /// Aim the next zoom at a screen point: whatever is under (sx, sy) stays
    /// under it, however long the animation takes.
    /// Which screen point the next zoom should hold still.
    function anchorAt(sx, sy) {
        root.anchorSx = sx;
        root.anchorSy = sy;
    }

    /*
     * Point the anchor at a view we want to ARRIVE at.
     *
     * `fitAll` and `fitTo` know the offset they want, but assigning it directly
     * would be overwritten by the next animated frame. Expressing it as an
     * anchor instead means the animation carries the board there — so fitting
     * is a smooth flight rather than a cut.
     */
    /*
     * Fly to a view. The zoom animates and the offset is carried along with it,
     * so fitting is a movement rather than a cut — and can still be interrupted
     * by a pan halfway through.
     */
    function aimAt(targetX, targetY, targetZoom) {
        const z = Math.max(root.minZoom, Math.min(root.maxZoom, targetZoom));
        root.anchorSx = root.width / 2;
        root.anchorSy = root.height / 2;
        root.zoomTarget = z;
        root.zoom = z;
        // The zoom's own delta handles the scale; this is the travel.
        viewGlide.stop();
        viewGlide.to = targetX;
        viewGlideY.to = targetY;
        viewGlide.start();
        viewGlideY.start();
        saveView.restart();
    }

    NumberAnimation {
        id: viewGlide
        target: root
        property: "viewX"
        duration: Appearance.animDur(160)
        easing.type: Easing.OutCubic
    }
    NumberAnimation {
        id: viewGlideY
        target: root
        property: "viewY"
        duration: Appearance.animDur(160)
        easing.type: Easing.OutCubic
    }

    /*
     * MOVE THE VIEW — and the anchor with it.
     *
     * Everything that pans goes through here. The anchor is a board point, so
     * panning changes what it points at; miss that in one place and the next
     * zoom yanks the board back to wherever the last one was aimed. That was
     * five separate call sites, which is four too many to get right by hand.
     */
    /*
     * Move the view. Nothing else to keep in step.
     *
     * This used to have to re-derive the anchor's board point on every pan, or
     * the next zoom would yank the board back to wherever the last one was
     * aimed — and it had to cancel any zoom still running. Now that the zoom
     * contributes a delta rather than an absolute, a pan is just a pan.
     */
    function panBy(dx, dy) {
        root.viewX += dx;
        root.viewY += dy;
        saveView.restart();
    }

    function zoomAt(factor, sx, sy) {
        const after = Math.max(root.minZoom, Math.min(root.maxZoom, root.zoomTarget * factor));
        if (after === root.zoomTarget)
            return;
        root.anchorAt(sx, sy);
        root.zoomTarget = after;
        root.zoom = after;
        saveView.restart();
    }

    // Coalesced: panning writes the view on every frame otherwise.
    // After the delegates exist: `boardChanged_` fires while the Repeater is
    // still building, and a membership test needs the pieces to be there.
    Timer {
        id: settleOnOpen
        interval: 120
        onTriggered: root.reconcileMembership()
    }

    Timer {
        id: saveView
        interval: 400
        onTriggered: Catalog.saveBoardView(root.viewX, root.viewY, root.zoom)
    }

    /// Restore where the board was left, once, when it is opened.
    function _restoreView() {
        for (let i = 0; i < Catalog.boards.length; i++) {
            const b = Catalog.boards[i];
            if (b.name !== Catalog.board)
                continue;
            // Straight to it, with the anchor pointed at the same place, or
            // `onZoomChanged` would immediately pull the view somewhere else.
            const z = b.viewZ > 0 ? b.viewZ : 1;
            root.smoothZoom = false;
            root.anchorSx = root.width / 2;
            root.anchorSy = root.height / 2;
            root.zoomTarget = z;
            root.zoom = z;
            root._appliedZoom = z;
            root.viewX = b.viewX;
            root.viewY = b.viewY;
            root.smoothZoom = true;
            return;
        }
    }

    Connections {
        target: Catalog
        function onBoardChanged_() {
            root._restoreView();
            root.selection = [];
            let top = 1;
            for (let i = 0; i < Catalog.boardItems.length; i++)
                top = Math.max(top, Catalog.boardItems[i].z + 1);
            root.topZ = top;
            /*
             * RESTORE WHERE YOU WERE — UNLESS THAT NO LONGER SHOWS THE WORK.
             *
             * A saved view is a position and a zoom, and neither means anything
             * without the viewport it was saved against. A board left framed in
             * a 664px window reopens in a 1280px one badly cropped, and one
             * left panned off to the side reopens on empty grid — which is
             * indistinguishable from a board that lost its contents.
             *
             * So the saved view is honoured when it still frames most of the
             * board, and otherwise the work is framed instead. The default view
             * (origin, 1:1) never shows anything on a board laid out elsewhere,
             * so it fails this the same way and gets fitted too.
             */
            if (root._visibleFraction() < 0.6)
                root.fitAll();
            // A board can be changed by the other application, or by an older
            // version of this one. Settle the record against the geometry once,
            // here, rather than trusting whatever is in the column.
            settleOnOpen.restart();
        }
    }

    // ── the ground ──────────────────────────────────────────────────────────

    /*
     * SOLID ONLY AS FAR AS ASKED.
     *
     * This was opaque, and it sat inside a window that had been made
     * transparent — so `surfaceFormat.opaque: false` and a clear window colour
     * both worked exactly as intended and were painted over by the canvas
     * itself. The window looked solid black and every setting looked broken.
     * The ground is the one thing that decides how see-through the board is,
     * so it is the one thing that reads the preference.
     */
    Rectangle {
        anchors.fill: parent
        color: Appearance.colors.colLayer0Base
        opacity: Prefs.boardGround
    }

    /*
     * A GRID, SO THE CANVAS HAS A SCALE.
     *
     * An infinite plane with nothing on it gives no sense of how far you have
     * panned or how far in you are zoomed — you drag and nothing appears to
     * move. Drawn in board units so the squares grow and shrink with the zoom,
     * which is what makes the zoom legible.
     */
    /*
     * A GRID, SO THE CANVAS HAS A SCALE — AND IT COSTS NOTHING TO MOVE.
     *
     * An infinite plane with nothing on it gives no sense of how far you have
     * panned or how far in you are zoomed: you drag and nothing appears to
     * move. Drawn in board units so the squares grow and shrink with the zoom,
     * which is what makes the zoom legible.
     *
     * This was a `Canvas`, and it repainted the entire window every time the
     * view changed. That was survivable while zoom was a single jump; the
     * moment zoom became animated it meant a full-window software raster and
     * texture upload on EVERY frame of every zoom — the one thing guaranteed
     * to make a smooth zoom stutter.
     *
     * Rectangles instead. The scene graph batches them into a couple of draw
     * calls and moving them is a transform, so a pan or a zoom costs no raster
     * at all: the lines are laid out once per zoom step and the container just
     * slides.
     */
    Item {
        id: grid
        anchors.fill: parent
        clip: true
        opacity: 0.5 * Prefs.boardGround
        // Below the density where lines stop reading as a grid and start
        // reading as noise.
        visible: grid.step >= 6

        readonly property real step: 80 * root.zoom
        readonly property color line: Appearance.colors.colOutlineVariant
        // One extra of each, so a line is always available to slide in from
        // the edge as the board moves.
        readonly property int columns: grid.step > 0 ? Math.ceil(root.width / grid.step) + 2 : 0
        readonly property int rows: grid.step > 0 ? Math.ceil(root.height / grid.step) + 2 : 0

        Item {
            // The whole grid moves as one item; only this x/y changes on a pan.
            x: grid.step > 0 ? -((root.viewX * root.zoom) % grid.step) : 0
            y: grid.step > 0 ? -((root.viewY * root.zoom) % grid.step) : 0

            Repeater {
                model: grid.columns
                delegate: Rectangle {
                    required property int index
                    x: Math.round(index * grid.step)
                    y: -grid.step
                    width: 1
                    height: root.height + grid.step * 2
                    color: grid.line
                    opacity: 0.25
                }
            }

            Repeater {
                model: grid.rows
                delegate: Rectangle {
                    required property int index
                    x: -grid.step
                    y: Math.round(index * grid.step)
                    width: root.width + grid.step * 2
                    height: 1
                    color: grid.line
                    opacity: 0.25
                }
            }
        }

        // The origin, so "home" is a place and not a guess.
        Item {
            x: root.toScreenX(0)
            y: root.toScreenY(0)

            Rectangle {
                x: -12
                y: 0
                width: 24
                height: 1
                color: grid.line
                opacity: 0.8
            }
            Rectangle {
                x: 0
                y: -12
                width: 1
                height: 24
                color: grid.line
                opacity: 0.8
            }
        }
    }

    // ── the containers ──────────────────────────────────────────────────────

    /// Which container is selected, if any. Separate from `selection`, which
    /// is pictures: they are different things and act differently.
    property int chosenContainer: 0

    /*
     * THE MODEL, HELD STILL.
     *
     * Only the ids, and only reassigned when the SET of them changes. A
     * Repeater given a new array rebuilds every delegate, so refreshing after a
     * drop tore down every picture on the board and loaded them all again —
     * which is what a drag ending in a flash of reloading images actually was.
     * Geometry arrives through `Catalog.boardItemMap`, so a refresh updates
     * values on pieces that are already there.
     */
    property var boardOrder: []
    /// The same treatment for containers — see `boardOrder`.
    property var containerOrder: []

    function _rebuildContainerOrder() {
        const ids = [];
        for (let i = 0; i < Catalog.boardContainers.length; i++)
            ids.push(Catalog.boardContainers[i].id);
        if (ids.join(",") === root.containerOrder.join(","))
            return;
        root.containerOrder = ids;
    }

    function _rebuildOrder() {
        const ids = [];
        for (let i = 0; i < Catalog.boardItems.length; i++)
            ids.push(Catalog.boardItems[i].id);
        // A separator no id can contain.
        if (ids.join("\u0000") === root.boardOrder.join("\u0000"))
            return;
        root.boardOrder = ids;
    }

    property Connections _boardWatch: Connections {
        target: Catalog
        function onBoardItemsChanged() {
            root._rebuildOrder();
        }
        function onBoardContainersChanged() {
            root._rebuildContainerOrder();
        }
    }

    signal containerMenuRequested(var entry, real sceneX, real sceneY)

    function containerAt(id) {
        for (let i = 0; i < containers.count; i++) {
            const c = containers.itemAt(i);
            if (c && c.entry.id === id)
                return c;
        }
        return null;
    }

    /// Move a container and everything currently inside it.
    function moveContainer(id, dx, dy) {
        const box = root.containerAt(id);
        if (box)
            box.nudge(dx, dy);
        for (let i = 0; i < pieces.count; i++) {
            const piece = pieces.itemAt(i);
            if (piece && piece.entry.container === id)
                piece.nudge(dx, dy);
        }
    }

    /*
     * RESIZING DECIDES MEMBERSHIP TOO.
     *
     * Dropping a picture inside an outline made it a member, but stretching the
     * outline OVER a picture did not — so the obvious way to gather three
     * things ("draw the box round them") left a container that looked full and
     * knew it was empty. Every count, every group-move and every ungroup then
     * disagreed with what was plainly on screen.
     *
     * Run wherever geometry settles — a piece dropped, a container moved or
     * resized, a group made, a board opened. It is cheap (a rectangle test per
     * picture) and it only writes the ones that actually changed, so the cost
     * of keeping the record honest is nothing.
     */
    function reconcileMembership() {
        let changed = false;
        for (let i = 0; i < pieces.count; i++) {
            const piece = pieces.itemAt(i);
            if (!piece)
                continue;
            const into = root.containerFor(piece);
            if (into === piece.entry.container)
                continue;
            piece.entry.container = into;
            piece.commit();
            changed = true;
        }
        if (changed)
            Catalog.refreshBoardItems();
    }

    function commitContainer(id) {
        const box = root.containerAt(id);
        if (box)
            box.commit();
        for (let i = 0; i < pieces.count; i++) {
            const piece = pieces.itemAt(i);
            if (piece && piece.entry.container === id)
                piece.commit();
        }
    }

    /*
     * WHICH CONTAINER A PICTURE IS IN — decided by where it ended up.
     *
     * By its CENTRE, not by overlap: a picture half in and half out has to
     * belong to exactly one thing, and the centre is the only answer that never
     * needs a tie-break. Later containers win, so a container drawn on top of
     * another behaves the way the stack looks.
     */
    function containerFor(piece) {
        let found = 0;
        const cx = piece.bx + piece.bw / 2;
        const cy = piece.by + piece.bh / 2;
        for (let i = 0; i < containers.count; i++) {
            const c = containers.itemAt(i);
            if (!c)
                continue;
            if (cx >= c.bx && cx <= c.bx + c.bw && cy >= c.by && cy <= c.by + c.bh)
                found = c.entry.id;
        }
        return found;
    }

    /*
     * Wrap the selected pictures in a new container.
     *
     * The only way to make one, and deliberately: a container drawn empty and
     * then filled is two steps and a mode, where "these belong together" is one
     * gesture on things you have already gathered.
     */
    function groupSelection() {
        if (root.selection.length < 1 || Catalog.board.length === 0)
            return;
        let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
        root.eachSelected(p => {
            minX = Math.min(minX, p.bx);
            minY = Math.min(minY, p.by);
            maxX = Math.max(maxX, p.bx + p.bw);
            maxY = Math.max(maxY, p.by + p.bh);
        });
        // Room for the header, and a margin so the pictures are not flush
        // against the edge of the thing holding them.
        const pad = 24;
        const head = 46;
        Catalog.placeContainer({
            "id": 0,
            "x": minX - pad,
            "y": minY - head,
            "w": (maxX - minX) + pad * 2,
            "h": (maxY - minY) + head + pad,
            "label": "",
            "onMade": function (made) {
                root.eachSelected(p => {
                    p.entry.container = made;
                    p.commit();
                });
                Catalog.refreshBoardItems();
                settleOnOpen.restart();
            }
        });
    }

    /*
     * ONE TRANSFORM, NOT A HUNDRED BINDINGS.
     *
     * Every piece used to work out its own screen rectangle — `x`, `y`, `width`
     * and `height` each a binding on the zoom — so a zoom re-evaluated four
     * bindings per picture per frame and re-laid-out every one of them. The
     * animation was smooth in principle and did an enormous amount of work in
     * practice, and it got worse with every picture on the board.
     *
     * Now the pictures live in BOARD coordinates and never mention the zoom at
     * all: this one item carries the whole view. A frame of zoom is two writes
     * and a scale matrix, and the scene graph transforms the subtree on the GPU
     * — which is the thing it is actually good at. The cost stops depending on
     * how much is on the board.
     */
    Item {
        id: content
            // Positioned in screen pixels, then scaled about its own origin — so a
            // child at board (bx, by) lands at (bx - viewX) * zoom, which is
            // exactly what `toScreenX` says.
            x: -root.viewX * root.zoom
            y: -root.viewY * root.zoom

            transform: Scale {
                origin.x: 0
                origin.y: 0
                xScale: root.zoom
                yScale: root.zoom
            }

        Repeater {
            id: containers
            model: root.containerOrder

            delegate: BoardContainer {
                required property int modelData
                board: root
                // Through the map, so a refresh changes VALUES on an outline
                // that is already on screen rather than replacing it.
                entry: Catalog.boardContainerMap[modelData] || ({
                    "id": modelData, "x": 0, "y": 0, "w": 600, "h": 400, "label": ""
                })
                // Under every picture. A container is a surface things sit on, not
                // a box drawn over them.
                z: -1
                onMenuRequested: (entry, sx, sy) => root.containerMenuRequested(entry, sx, sy)
            }
        }

        // ── the pictures ────────────────────────────────────────────────────────

        Repeater {
            id: pieces
            model: root.boardOrder

            delegate: BoardPiece {
                required property string modelData

                board: root
                // Read through the map: the model is stable, the values are not.
                entry: Catalog.boardItemMap[modelData] || ({
                    "id": modelData, "x": 0, "y": 0, "w": 0, "h": 0,
                    "angle": 0, "hflip": false, "vflip": false, "z": 0,
                    "sharp": false, "container": 0
                })
                opacity: Prefs.boardPieces
                record: Catalog.boardRecord(modelData)

                onPicked: (id, additive) => {
                    if (additive)
                        root.toggleSelected(id);
                    else if (!root.isSelected(id))
                        root.selectOnly(id);
                }
                onOpened: rec => root.activated(rec, 0)
                onMenuRequested: (rec, sx, sy) => root.contextRequested(rec, sx, sy)
                onMovedBy: (dx, dy) => root.moveSelection(dx, dy)
                onCommitted: root.commitSelection()
            }
        }
    }

    /// Shift every selected piece. Called once per drag frame by whichever
    /// piece is under the pointer, so a group moves together.
    function moveSelection(dx, dy) {
        for (let i = 0; i < pieces.count; i++) {
            const piece = pieces.itemAt(i);
            if (piece && root.isSelected(piece.entry.id))
                piece.nudge(dx, dy);
        }
    }

    /// Bring the selection to the front. Persisted on release, unlike RIA's,
    /// so the board reopens stacked the way it was left.
    function raiseSelection() {
        root.eachSelected(p => {
            root.topZ = root.topZ + 1;
            p.raise_(root.topZ);
        });
    }

    function commitSelection() {
        let regrouped = false;
        for (let i = 0; i < pieces.count; i++) {
            const piece = pieces.itemAt(i);
            if (!piece || !root.isSelected(piece.entry.id))
                continue;
            // Dropped inside an outline: it belongs. Dragged out: it does not.
            const into = root.containerFor(piece);
            if (into !== piece.entry.container) {
                piece.entry.container = into;
                regrouped = true;
            }
            piece.commit();
        }
        if (regrouped)
            Catalog.refreshBoardItems();
    }

    function eachSelected(fn) {
        for (let i = 0; i < pieces.count; i++) {
            const piece = pieces.itemAt(i);
            if (piece && root.isSelected(piece.entry.id))
                fn(piece);
        }
    }

    // ── the canvas itself: pan, zoom, marquee ───────────────────────────────

    MouseArea {
        id: canvas
        anchors.fill: parent
        // Behind the pieces, so a press on a picture reaches the picture and a
        // press on empty board reaches this.
        z: -1
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        hoverEnabled: true

        property real lastX: 0
        property real lastY: 0
        property bool panning: false
        property bool marqueeing: false
        property real markX: 0
        property real markY: 0
        property bool moved: false
        /// Whether this gesture came from a finger. Qt delivers touch to a
        /// MouseArea as a synthesised mouse event, and `source` is what says so.
        property bool fromTouch: false

        onPressed: mouse => {
            canvas.lastX = mouse.x;
            canvas.lastY = mouse.y;
            canvas.markX = mouse.x;
            canvas.markY = mouse.y;
            canvas.moved = false;
            canvas.marqueeing = false;
            canvas.fromTouch = mouse.source !== Qt.MouseEventNotSynthesized;

            /*
             * A DRAG ON EMPTY BOARD PANS.
             *
             * It used to marquee, which meant the most natural gesture on an
             * infinite canvas — grab the background and move it — instead drew
             * a selection box, and panning was hidden on the middle button that
             * a touchpad and a finger do not have at all.
             *
             * Selecting a group is the rarer, deliberate act, so it gets the
             * deliberate gesture: double-click and drag, or Shift and drag.
             * Neither is reachable with a finger, which is correct — with a
             * finger the background is for moving the board.
             */
            if (!canvas.fromTouch && (mouse.modifiers & Qt.ShiftModifier)) {
                canvas.marqueeing = true;
                return;
            }
            canvas.panning = true;
        }

        // The second press of a double-click. Turning the gesture over here
        // rather than on the first one is what lets a single drag still pan.
        onDoubleClicked: mouse => {
            if (canvas.fromTouch)
                return;
            canvas.panning = false;
            canvas.marqueeing = true;
            canvas.markX = mouse.x;
            canvas.markY = mouse.y;
        }

        onPositionChanged: mouse => {
            if (Math.abs(mouse.x - canvas.markX) > 3 || Math.abs(mouse.y - canvas.markY) > 3)
                canvas.moved = true;

            if (canvas.marqueeing) {
                marquee.x = Math.min(canvas.markX, mouse.x);
                marquee.y = Math.min(canvas.markY, mouse.y);
                marquee.width = Math.abs(mouse.x - canvas.markX);
                marquee.height = Math.abs(mouse.y - canvas.markY);
                return;
            }
            if (!canvas.panning)
                return;
            root.panBy(-(mouse.x - canvas.lastX) / root.zoom,
                       -(mouse.y - canvas.lastY) / root.zoom);
            canvas.lastX = mouse.x;
            canvas.lastY = mouse.y;
        }

        onReleased: mouse => {
            if (canvas.marqueeing && marquee.width > 3 && marquee.height > 3)
                root.selectWithin(marquee.x, marquee.y, marquee.width, marquee.height,
                                  (mouse.modifiers & Qt.ShiftModifier) !== 0);
            // A CLICK on empty board clears the selection; a DRAG does not.
            // Panning away from your work and finding it deselected is the kind
            // of thing that makes a canvas feel like it is fighting you.
            else if (!canvas.moved && !(mouse.modifiers & Qt.ShiftModifier))
                root.selection = [];

            canvas.panning = false;
            canvas.marqueeing = false;
            marquee.width = 0;
            marquee.height = 0;
        }

        /*
         * A TOUCHPAD SCROLLS. A MOUSE WHEEL ZOOMS.
         *
         * They arrive as the same event and they mean opposite things. A mouse
         * wheel has no pixelDelta and clicks in multiples of 120, and on an
         * infinite canvas the only thing a wheel sensibly does is zoom. A
         * touchpad sends pixelDelta for a two-finger scroll, and two fingers
         * mean PAN everywhere else on the desktop — zooming the board every
         * time you brushed the pad was unusable.
         *
         * Ctrl overrides either way, which is the convention every map and
         * canvas has taught: Ctrl+scroll is zoom.
         */
        onWheel: wheel => {
            wheel.accepted = true;

            /*
             * TELLING A TOUCHPAD FROM A WHEEL, PROPERLY.
             *
             * `pixelDelta` alone is not enough: plenty of touchpads under
             * Wayland report only `angleDelta` for a two-finger scroll, and
             * they were being taken for a mouse — so trying to move around the
             * board zoomed it instead, which is the one thing a canvas must
             * never do to you.
             *
             * A real wheel detents: its angleDelta arrives in whole multiples
             * of 120, one per click. Anything finer than that came from a
             * surface someone is sliding a finger across, whatever it chose to
             * fill in. Ctrl still overrides either way.
             */
            const px = wheel.pixelDelta.x !== 0 || wheel.pixelDelta.y !== 0;
            const detented = wheel.angleDelta.y !== 0
                && wheel.angleDelta.y % 120 === 0
                && wheel.angleDelta.x === 0;
            const fromPad = px || !detented;
            const wantsZoom = (wheel.modifiers & Qt.ControlModifier) || !fromPad;

            if (wantsZoom) {
                const ticks = (fromPad && wheel.pixelDelta.y !== 0)
                    ? wheel.pixelDelta.y
                    : wheel.angleDelta.y;
                if (ticks === 0)
                    return;
                // A pad's pixels are far finer than a wheel's notches, so the
                // step is scaled to the device rather than shared.
                /*
                 * SMALL STEPS.
                 *
                 * 12% a notch is what a file manager uses to step through four
                 * icon sizes; a canvas is not stepping between sizes, it is
                 * being aimed. At 12% you overshoot the framing you wanted and
                 * come back, every time. 6% takes two notches to do what one
                 * did and lands where you meant — and since the steps come off
                 * `zoomTarget`, spinning the wheel still covers ground fast.
                 *
                 * The pad divisor is larger for the same reason, scaled to its
                 * far finer input: a fingertip's worth of travel should be a
                 * small, controllable change, not half the zoom range.
                 */
                const factor = fromPad
                    ? Math.exp(ticks / 700)
                    : (ticks > 0 ? 1.06 : 1 / 1.06);
                root.zoomAt(factor, wheel.x, wheel.y);
                return;
            }

            /*
             * Two fingers: pan, both axes — a pad gives horizontal scroll for
             * free and a canvas should use it.
             *
             * `pixelDelta` when there is one, `angleDelta` otherwise: a pad
             * that reports only degrees still has to move the board, and 1/8 of
             * a degree-unit is about the travel a finger means by it.
             */
            const dx = wheel.pixelDelta.x !== 0 ? wheel.pixelDelta.x : wheel.angleDelta.x / 8;
            const dy = wheel.pixelDelta.y !== 0 ? wheel.pixelDelta.y : wheel.angleDelta.y / 8;
            root.panBy(-dx / root.zoom, -dy / root.zoom);
        }
    }

    /*
     * PINCH TO ZOOM, AND TWO FINGERS TO PAN WHILE PINCHING.
     *
     * Touch never reaches the wheel path at all, so without this a board is
     * unusable with fingers — the canvas would only pan, at 1:1, forever.
     *
     * `minimumPointCount: 2` keeps it clear of one-finger interaction, which
     * Qt already delivers to the MouseArea below as a synthesised mouse: one
     * finger drags a picture or marquees the canvas exactly as a mouse does,
     * and two fingers are the view.
     */
    PinchHandler {
        id: pinch
        target: null
        minimumPointCount: 2
        maximumPointCount: 2

        property real startZoom: 1

        onActiveChanged: {
            if (active) {
                pinch.startZoom = root.zoom;
                pinch.lastCx = pinch.centroid.position.x;
                pinch.lastCy = pinch.centroid.position.y;
                // Fingers are already continuous; animating toward a target
                // that moves every frame just lags them.
                root.smoothZoom = false;
                return;
            }
            root.smoothZoom = true;
            saveView.restart();
        }

        onScaleChanged: {
            if (!pinch.active)
                return;
            const want = pinch.startZoom * pinch.activeScale;
            const next = Math.max(root.minZoom, Math.min(root.maxZoom, want));
            if (next === root.zoom)
                return;
            // About the point between the fingers, for the same reason the
            // wheel zooms about the cursor: zooming about the origin walks
            // what you are looking at off the screen.
            root.anchorAt(pinch.centroid.position.x, pinch.centroid.position.y);
            root.zoomTarget = next;
            root.zoom = next;
        }

        /*
         * Sliding two fingers moves the board, so a pinch and a drag are one
         * gesture rather than two you have to alternate between.
         *
         * Measured against the LAST centroid rather than the press position:
         * the zoom above moves the view under the fingers on the same events,
         * so a delta taken from where the pinch began double-counts everything
         * the zoom already did and the board shoots off.
         */
        property real lastCx: 0
        property real lastCy: 0

        onCentroidChanged: {
            if (!pinch.active) {
                pinch.lastCx = pinch.centroid.position.x;
                pinch.lastCy = pinch.centroid.position.y;
                return;
            }
            root.panBy(-(pinch.centroid.position.x - pinch.lastCx) / root.zoom,
                       -(pinch.centroid.position.y - pinch.lastCy) / root.zoom);
            pinch.lastCx = pinch.centroid.position.x;
            pinch.lastCy = pinch.centroid.position.y;
        }
    }

    Rectangle {
        id: marquee
        visible: width > 0 && height > 0
        z: 900
        color: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.85)
        border.width: 1
        border.color: Appearance.colors.colPrimary
    }

    function selectWithin(sx, sy, sw, sh, additive) {
        // The marquee is drawn in screen pixels and the pieces now live in
        // board units, so one of them has to be converted. Converting the
        // marquee is one rectangle rather than one per picture.
        const bx = root.toBoardX(sx);
        const by = root.toBoardY(sy);
        const bw = sw / root.zoom;
        const bh = sh / root.zoom;
        const found = additive ? root.selection.slice() : [];
        for (let i = 0; i < pieces.count; i++) {
            const piece = pieces.itemAt(i);
            if (!piece)
                continue;
            // Screen-space overlap, not containment: a marquee that only takes
            // what it entirely surrounds cannot select anything larger than the
            // window, which on a zoomed-in board is most of the board.
            if (piece.bx < bx + bw && piece.bx + piece.bw > bx
                && piece.by < by + bh && piece.by + piece.bh > by
                && found.indexOf(piece.entry.id) < 0)
                found.push(piece.entry.id);
        }
        root.selection = found;
    }

    // ── which board ─────────────────────────────────────────────────────────

    /*
     * A board has to be CHOSEN before anything can be put on it.
     *
     * The strip is always there rather than hidden behind a menu: a board is a
     * document, and which document you are editing is not a preference to go
     * hunting for. It is also the only place a board can be made, so an empty
     * app has somewhere obvious to start.
     */
    Rectangle {
        id: bar
        z: 950
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.topMargin: 8
        implicitWidth: Math.min(root.width - 24, barRow.implicitWidth + 20)
        implicitHeight: 46
        radius: Appearance.rounding.full
        // Always solid, whatever the board is set to: this is the control that
        // turns transparency back off, and a control you cannot see is a trap.
        color: Appearance.colors.colSurfaceContainerHighest
        border.width: 1
        border.color: Appearance.colors.colOutlineVariant

        /*
         * ONE CONTROL PER IDEA.
         *
         * This was the board list, two icons, two bare sliders and a permanent
         * text field, all in one row — five separate ideas competing for a strip
         * whose job is to say WHICH BOARD you are on. The sliders had no labels
         * and no visible handle at 100%, so they read as two grey capsules, and
         * the always-open name field was the widest thing in a bar where making
         * a board is the rarest thing you do.
         *
         * Now: the boards, and two buttons that open what they are for.
         */
        RowLayout {
            id: barRow
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 6
            spacing: 4

            MaterialSymbol {
                Layout.alignment: Qt.AlignVCenter
                text: "dashboard"
                iconSize: Appearance.font.pixelSize.large
                color: Appearance.colors.colSubtext
            }

            Repeater {
                model: Catalog.boards

                delegate: PillTab {
                    id: pill
                    required property var modelData
                    Layout.alignment: Qt.AlignVCenter
                    label: `${modelData.name}  ${modelData.items}`
                    active: Catalog.board === modelData.name
                    accent: "primary"
                    onTriggered: Catalog.openBoard(modelData.name)

                    // A board is a document, so it has to be renameable and
                    // removable — and there was nowhere at all to do either.
                    // Right-click on the desktop; long press, for a finger.
                    TapHandler {
                        acceptedButtons: Qt.RightButton
                        gesturePolicy: TapHandler.ReleaseWithinBounds
                        onTapped: boardMenu.openFor(pill.modelData.name, pill)
                    }
                    TapHandler {
                        acceptedDevices: PointerDevice.TouchScreen
                        onLongPressed: boardMenu.openFor(pill.modelData.name, pill)
                    }
                }
            }

            IconButton {
                Layout.alignment: Qt.AlignVCenter
                icon: "add"
                tooltip: "Start a board"
                size: 32
                toggled: naming.visible
                onClicked: {
                    // The ＋ always MAKES one, even if a rename was half-typed.
                    root.renaming = "";
                    root.renamingContainer = 0;
                    newName.text = "";
                    naming.visible = !naming.visible;
                    if (naming.visible)
                        newName.forceActiveFocus();
                }
            }

            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                Layout.preferredWidth: 1
                Layout.preferredHeight: 22
                color: Appearance.colors.colOutlineVariant
            }

            IconButton {
                id: seeThrough
                Layout.alignment: Qt.AlignVCenter
                icon: "opacity"
                tooltip: "How much you can see through it"
                size: 32
                // Lit while the board is not fully solid, so a window you can
                // see through always says which control did it.
                toggled: Prefs.boardGround < 1 || Prefs.boardPieces < 1
                onClicked: fade.visible ? fade.close() : fade.popup()
            }
        }
    }

    /*
     * Naming a board, only while naming a board.
     *
     * A text field that is always open is a text field you keep clicking into
     * by accident, and this one sat in the middle of the strip being the widest
     * thing in it.
     */
    /// Non-empty while the field is renaming a BOARD rather than creating one.
    property string renaming: ""
    /// Non-zero while it is renaming a container instead.
    property int renamingContainer: 0

    function renameContainer(entry) {
        root.renamingContainer = entry.id;
        root.renaming = "";
        newName.text = entry.label;
        naming.visible = true;
        newName.forceActiveFocus();
    }

    Rectangle {
        id: naming
        z: 951
        visible: false
        anchors.top: bar.bottom
        anchors.topMargin: 6
        anchors.horizontalCenter: parent.horizontalCenter
        implicitWidth: 260
        implicitHeight: 52
        radius: Appearance.rounding.small
        color: Appearance.colors.colSurfaceContainerHighest
        border.width: 1
        border.color: Appearance.colors.colOutlineVariant

        MaterialTextField {
            id: newName
            anchors.fill: parent
            anchors.margins: 8
            placeholder: root.renamingContainer > 0 ? "Name this group…"
                : root.renaming.length > 0 ? "Rename the board…"
                : "Name the board…"
            onAccepted: {
                const name = newName.text.trim();
                if (name.length === 0)
                    return;
                if (root.renamingContainer > 0) {
                    const box = root.containerAt(root.renamingContainer);
                    if (box)
                        Catalog.placeContainer({
                            "id": box.entry.id,
                            "x": box.bx,
                            "y": box.by,
                            "w": box.bw,
                            "h": box.bh,
                            "label": name
                        });
                    root.renamingContainer = 0;
                    newName.text = "";
                    naming.visible = false;
                    return;
                }
                if (root.renaming.length > 0)
                    Catalog.renameBoard(root.renaming, name);
                else
                    // Making one and opening it are the same intent: nobody
                    // makes a board in order to not use it.
                    Catalog.createBoard(name);
                root.renaming = "";
                newName.text = "";
                naming.visible = false;
            }
        }

        Keys.onEscapePressed: {
            root.renaming = "";
            root.renamingContainer = 0;
            naming.visible = false;
        }
    }

    /*
     * What can be done TO a board, as opposed to on one.
     *
     * Renaming reuses the same field that makes one, pre-filled — a second text
     * field that looked identical and behaved differently would be a worse
     * answer than one that does both.
     */
    MenuPopup {
        id: boardMenu
        z: 960
        minWidth: 220

        property string subject: ""

        function openFor(name, anchorItem) {
            boardMenu.subject = name;
            const at = anchorItem.mapToItem(root, 0, anchorItem.height + 6);
            boardMenu.x = Math.max(8, Math.min(at.x, root.width - boardMenu.implicitWidth - 8));
            boardMenu.y = at.y;
            boardMenu.open();
        }

        MenuRow {
            text: "Rename…"
            icon: "edit"
            onTriggered: {
                boardMenu.close();
                renaming = boardMenu.subject;
                newName.text = boardMenu.subject;
                naming.visible = true;
                newName.forceActiveFocus();
            }
        }

        MenuRow {
            separator: true
        }

        MenuRow {
            text: `Delete “${boardMenu.subject}”`
            icon: "delete"
            destructive: true
            onTriggered: {
                boardMenu.close();
                Catalog.deleteBoard(boardMenu.subject);
            }
        }
    }

    /*
     * The two transparencies, labelled, behind the one icon that means them.
     *
     * Inline they were two unlabelled capsules whose handles are invisible at
     * 100% — which is where they start. A percentage beside each one is what
     * makes a slider a control rather than a decoration.
     */
    MenuPopup {
        id: fade
        z: 960
        minWidth: 268

        function popup() {
            const at = seeThrough.mapToItem(root, 0, seeThrough.height + 6);
            fade.x = Math.min(Math.max(8, at.x - fade.implicitWidth + seeThrough.width), root.width - fade.implicitWidth - 8);
            fade.y = at.y;
            fade.open();
        }

        FadeRow {
            label: "The board"
            floor: 0
            value: Prefs.boardGround
            onMoved_: v => Prefs.boardGround = v
        }

        FadeRow {
            label: "The pictures"
            // Never fully invisible: a board of pictures you cannot see is
            // indistinguishable from an empty one, and there would be nothing
            // left to click on to bring them back.
            floor: 0.1
            value: Prefs.boardPieces
            onMoved_: v => Prefs.boardPieces = v
        }

        MenuRow {
            separator: true
        }

        MenuRow {
            text: "Make it solid again"
            icon: "layers_clear"
            enabled: Prefs.boardGround < 1 || Prefs.boardPieces < 1
            onTriggered: {
                Prefs.boardGround = 1;
                Prefs.boardPieces = 1;
                fade.close();
            }
        }
    }

    PagePlaceholder {
        anchors.fill: parent
        visible: Catalog.board.length === 0
        icon: "dashboard"
        title: Catalog.boards.length > 0 ? "Pick a board" : "No boards yet"
        description: Catalog.boards.length > 0
            ? "Choose one above, or name a new one. Pictures go on from any tile's menu."
            : "Name one above. A board is pictures arranged next to each other — reference, a "
              + "colour study, a mood board — and it keeps what you put on it even when the "
              + "search that found them is long gone."
    }

    /*
     * DROP FILES ONTO THE BOARD.
     *
     * RIA takes files, folders and image URLs this way and it is the fastest
     * route from "I have this picture" to "it is on my board". Here it goes
     * through the catalogue rather than around it: a dropped file becomes a
     * `file://` row the same way the local source's rows are, so it gets a
     * thumbnail, a dominant colour and a phash, and it can be found again by
     * search afterwards. A board of pictures that exist only on the board would
     * be a second, worse library.
     */
    DropArea {
        anchors.fill: parent
        keys: ["text/uri-list"]

        onEntered: drag => {
            drag.accepted = Catalog.board.length > 0;
        }

        onDropped: drop => {
            if (Catalog.board.length === 0) {
                Toast.error("Open a board first");
                return;
            }
            const urls = drop.urls || [];
            let taken = 0;
            for (let i = 0; i < urls.length; i++) {
                const url = String(urls[i]);
                if (!url.startsWith("file://"))
                    continue;             // a remote URL is a fetch, not a drop
                if (!/\.(png|jpe?g|webp|gif|avif|bmp|svg|mp4|webm|mkv)$/i.test(url))
                    continue;
                Catalog.adoptFile(url, function (item) {
                    root.place(item);
                });
                taken++;
            }
            if (taken === 0)
                Toast.error("Nothing there quarry can read");
            drop.accept();
        }
    }

    // ── keys ────────────────────────────────────────────────────────────────

    focus: root.visible && root.enabled

    Keys.onReleased: event => {
        if (event.key === Qt.Key_R && !event.isAutoRepeat) {
            root.rotateHeld = false;
            event.accepted = true;
        }
    }

    Keys.onPressed: event => {
        const step = event.modifiers & Qt.ShiftModifier ? 200 : 60;
        switch (event.key) {
        case Qt.Key_Delete:
        case Qt.Key_Backspace:
            root.removeSelected();
            break;
        case Qt.Key_A:
            if (event.modifiers & Qt.ControlModifier) {
                const all = [];
                for (let i = 0; i < Catalog.boardItems.length; i++)
                    all.push(Catalog.boardItems[i].id);
                root.selection = all;
                break;
            }
            root.panBy(-step / root.zoom, 0);
            break;
        case Qt.Key_H:
            root.eachSelected(p => p.flip(true));
            break;
        case Qt.Key_R:
            if (event.modifiers & Qt.ControlModifier) {
                // Ctrl+R refreshes, as it does in RIA — for when quarry has
                // added something to this board from the other window.
                Catalog.refreshBoards();
                Catalog.refreshBoardItems();
                break;
            }
            // Held, R turns a drag into a rotation; tapped, it steps 15°.
            root.rotateHeld = true;
            if (!event.isAutoRepeat)
                root.eachSelected(p => p.rotateBy(event.modifiers & Qt.ShiftModifier ? -15 : 15));
            break;
        case Qt.Key_Escape:
            root.selection = [];
            root.chosenContainer = 0;
            break;
        case Qt.Key_G:
            if (event.modifiers & Qt.ControlModifier)
                root.groupSelection();
            break;
        case Qt.Key_V:
            if (event.modifiers & Qt.ControlModifier) {
                root.pasteFromClipboard();
                break;
            }
            root.eachSelected(p => p.flip(false));
            break;
        case Qt.Key_C:
            if (event.modifiers & Qt.ControlModifier)
                root.copySelection();
            break;
        case Qt.Key_W:
            root.panBy(0, -step / root.zoom);
            break;
        case Qt.Key_S:
            root.panBy(0, step / root.zoom);
            break;
        case Qt.Key_D:
            root.panBy(step / root.zoom, 0);
            break;
        case Qt.Key_BracketLeft:
            // Transparency, on the two keys next to each other. Ctrl moves the
            // pictures instead of the ground.
            if (event.modifiers & Qt.ControlModifier)
                Prefs.boardPieces = Math.max(0.1, Prefs.boardPieces - 0.1);
            else
                Prefs.boardGround = Math.max(0, Prefs.boardGround - 0.1);
            break;
        case Qt.Key_BracketRight:
            if (event.modifiers & Qt.ControlModifier)
                Prefs.boardPieces = Math.min(1, Prefs.boardPieces + 0.1);
            else
                Prefs.boardGround = Math.min(1, Prefs.boardGround + 0.1);
            break;
        case Qt.Key_F:
            root.fitAll();
            break;
        case Qt.Key_Space:
            // Back to the origin — RIA's binding, and the only reliable way
            // out of having panned somewhere empty.
            root.aimAt(-root.width / (2 * root.zoom), -root.height / (2 * root.zoom), root.zoom);
            break;
        case Qt.Key_0:
            // 1:1, about the middle of what you are looking at.
            root.zoomAt(1 / root.zoom, root.width / 2, root.height / 2);
            break;
        case Qt.Key_Plus:
        case Qt.Key_Equal:
            root.zoomAt(1.1, root.width / 2, root.height / 2);
            break;
        case Qt.Key_Minus:
            root.zoomAt(1 / 1.1, root.width / 2, root.height / 2);
            break;
        case Qt.Key_Left:
            root.panBy(-step / root.zoom, 0);
            break;
        case Qt.Key_Right:
            root.panBy(step / root.zoom, 0);
            break;
        case Qt.Key_Up:
            root.panBy(0, -step / root.zoom);
            break;
        case Qt.Key_Down:
            root.panBy(0, step / root.zoom);
            break;
        default:
            return;
        }
        event.accepted = true;
    }

    /*
     * Fill the view with one piece.
     *
     * The board's answer to "look at this one closely": there is nowhere to
     * open it TO — a board holds pictures the current query does not, so the
     * detail view has no index for them — and zooming to it is what you want
     * anyway, because the neighbours are still there when you come back out.
     */
    /*
     * FRAME EVERYTHING ON THE BOARD.
     *
     * The failure this exists for: a board whose pieces sit outside the
     * viewport draws as an empty grid, which is indistinguishable from a board
     * that lost its contents. Opening a board you have never positioned runs
     * this, so it always opens showing its work.
     */
    /// How much of the board's bounding box the viewport is showing, 0..1.
    function _visibleFraction() {
        if (Catalog.boardItems.length === 0 || root.width <= 0 || root.height <= 0)
            return 1;                    // nothing to frame; leave the view alone
        let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
        for (let i = 0; i < Catalog.boardItems.length; i++) {
            const it = Catalog.boardItems[i];
            minX = Math.min(minX, it.x);
            minY = Math.min(minY, it.y);
            maxX = Math.max(maxX, it.x + (it.w > 0 ? it.w : 420));
            maxY = Math.max(maxY, it.y + (it.h > 0 ? it.h : 315));
        }
        const viewR = root.viewX + root.width / root.zoom;
        const viewB = root.viewY + root.height / root.zoom;
        const overlapW = Math.max(0, Math.min(maxX, viewR) - Math.max(minX, root.viewX));
        const overlapH = Math.max(0, Math.min(maxY, viewB) - Math.max(minY, root.viewY));
        const area = Math.max(1, (maxX - minX) * (maxY - minY));
        return (overlapW * overlapH) / area;
    }

    function fitAll() {
        if (Catalog.boardItems.length === 0)
            return;
        let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
        for (let i = 0; i < Catalog.boardItems.length; i++) {
            const it = Catalog.boardItems[i];
            const w = it.w > 0 ? it.w : 420;
            const h = it.h > 0 ? it.h : 315;
            minX = Math.min(minX, it.x);
            minY = Math.min(minY, it.y);
            maxX = Math.max(maxX, it.x + w);
            maxY = Math.max(maxY, it.y + h);
        }
        const spanX = Math.max(1, maxX - minX);
        const spanY = Math.max(1, maxY - minY);
        const fit = Math.max(root.minZoom, Math.min(root.maxZoom,
            Math.min(root.width / spanX, root.height / spanY) * 0.9));
        root.aimAt(minX + spanX / 2 - root.width / (2 * fit),
                   minY + spanY / 2 - root.height / (2 * fit), fit);
    }

    function fitTo(rec) {
        if (!rec)
            return;
        for (let i = 0; i < pieces.count; i++) {
            const piece = pieces.itemAt(i);
            if (!piece || !piece.record || piece.record.id !== rec.id)
                continue;
            const margin = 0.88;
            const fit = Math.max(root.minZoom, Math.min(root.maxZoom,
                Math.min(root.width / piece.bw, root.height / piece.bh) * margin));
            root.aimAt(piece.bx + piece.bw / 2 - root.width / (2 * fit),
                       piece.by + piece.bh / 2 - root.height / (2 * fit), fit);
            root.selectOnly(rec.id);
            return;
        }
    }

    /*
     * THE CLIPBOARD, BOTH WAYS.
     *
     * RIA has this and it matters more here than it looks: the way a picture
     * usually arrives is that you already have it — screenshotted, copied out
     * of a browser — and without paste the only route onto a board is a file
     * you have already saved somewhere.
     *
     * Pasting writes the clipboard to a real file first rather than holding an
     * image in memory, because everything downstream — the thumbnailer, the
     * exporter, the board itself — works on paths, and a picture that exists
     * only inside this process would vanish the moment the board reopened.
     */
    function pasteFromClipboard() {
        if (Catalog.board.length === 0) {
            Toast.error("Open a board first");
            return;
        }
        const dir = `${Quickshell.env("HOME")}/.cache/quarry/pasted`;
        const path = `${dir}/paste-${Date.now()}.png`;
        Sys.run(["bash", "-c",
            `mkdir -p ${JSON.stringify(dir)} && wl-paste --type image/png > ${JSON.stringify(path)}`
        ], function (ok) {
            if (!ok) {
                Toast.error("Nothing on the clipboard quarry can read");
                return;
            }
            Catalog.adoptFile("file://" + path, function (item) {
                root.place(item);
            });
        });
    }

    /// Copy the selected picture out, so it can go into whatever you are
    /// drawing in. One picture: a clipboard holds one image.
    function copySelection() {
        if (root.selection.length === 0)
            return;
        const rec = Catalog.boardRecord(root.selection[0]);
        if (!rec) {
            Toast.error("That one has not loaded yet");
            return;
        }
        const path = String(rec.url).replace(/^file:\/\//, "");
        Sys.copyImage(path, "", function (ok) {
            if (ok)
                Toast.show("Copied");
            else
                Toast.error("Could not copy it");
        });
    }

    function removeSelected() {
        const going = root.selection.slice();
        for (let i = 0; i < going.length; i++)
            Catalog.removeFromBoard(going[i]);
        root.selection = [];
        Catalog.refreshBoardItems();
    }

    /*
     * PUT A PICTURE ON THE BOARD.
     *
     * Dropped at the middle of the view rather than at the origin — the origin
     * is usually off screen by the time you are adding a fifth picture, and a
     * picture you cannot see has not been added as far as anyone can tell.
     * Sized to a sensible board width and given the top z.
     */
    function place(item) {
        if (!item || Catalog.board.length === 0)
            return;
        const ratio = (item.w > 0 && item.h > 0) ? item.h / item.w : 0.75;
        const w = 420;
        let top = 0;
        for (let i = 0; i < Catalog.boardItems.length; i++)
            top = Math.max(top, Catalog.boardItems[i].z + 1);

        // Nudged by how many are already there, so adding several in a row
        // fans them out instead of stacking them exactly.
        const spread = (Catalog.boardItems.length % 6) * 28;
        Catalog.placeOnBoard(item.id, {
            "x": root.toBoardX(root.width / 2) - w / 2 + spread,
            "y": root.toBoardY(root.height / 2) - (w * ratio) / 2 + spread,
            "w": w,
            "h": w * ratio,
            "angle": 0,
            "z": top
        });
        Catalog.refreshBoardItems();
    }

    // The harness drives whichever layout is showing; a board does not scroll,
    // so the sweep pans it instead.
    function scrollTest(durationMs, distancePx) {
        sweep.stop();
        root.viewX = 0;
        sweep.from = 0;
        sweep.to = distancePx;
        sweep.duration = durationMs;
        Perf.beginMeasure();
        sweep.start();
    }

    NumberAnimation {
        id: sweep
        target: root
        property: "viewX"
        easing.type: Easing.Linear
        onFinished: {
            Perf.endMeasure();
        }
    }
}
