import QtQuick

/**
 * Browser-like scrolling for a Flickable/ListView/GridView.
 *
 *  - touchpad: the content follows the fingers 1:1, and on lift keeps
 *    gliding at the fingers' speed, slowing down (Linux compositors send no
 *    momentum phase, so Qt lists otherwise stop dead)
 *  - mouse wheel: each notch glides ~100 px with an ease-out; fast spins add
 *    up into one smooth motion instead of stepping. High-resolution and
 *    free-spinning wheels scroll in proportion.
 *  - at either end the scroll goes on to the list around it, as before; when
 *    there is none, the list STRETCHES from that edge and springs back, as on
 *    Android 12+ (a touchpad pulls it with resistance, a notch or a fling
 *    that hits the end gives it a short pulse)
 *
 * It works through a WheelHandler on the list itself: handlers see wheel
 * events before the list does (an item layered beside the list never does —
 * the list takes the event first). Nested lists: the inner one is asked
 * first, as it should be.
 *
 * The stretch is a Scale on the list's contentItem, nothing else: positions,
 * models and delegates are never touched, and at rest the scale is exactly 1.
 *
 * Plain QtQuick, nothing of ours: the same file sits in the shell and in
 * every app's ui/ folder. Declare it inside a list (`Momentum {}`), or let
 * MomentumInjector put one on every list of a window.
 */
Item {
    id: m
    objectName: "momentum"
    property Flickable flickable: null
    property real notch: 100           // px per wheel notch (Chrome: 100)
    property int wheelMs: 260          // glide time of a notch
    property real gain: 1.0            // finger speed → glide speed
    property real minVelocity: 120     // px/s; slower lifts just stop
    property real maxVelocity: 7000
    property bool stretch: true        // the edge stretch; false = stop dead at the ends
    property real maxStretch: 0.07     // the most it stretches, as a fraction
    width: 0; height: 0
    visible: false

    /// true while it moves the list: callers switch off their own contentY
    /// animation meanwhile (two animators fight)
    readonly property bool active: endTimer.running || wheelY.running || wheelX.running || (m.flickable?.flicking ?? false)

    // declared inside a list: a Flickable puts it in its contentItem, a
    // ListView/GridView may keep it as its own child, and either can happen
    // after onCompleted — so look whenever the parent changes
    function findList() {
        if (m.flickable) return;
        const p = m.parent;
        if (!p) return;
        if (typeof p.flick === "function" && p.contentItem !== undefined) { m.flickable = p; return; }
        const pp = p.parent;
        if (pp && typeof pp.flick === "function" && pp.contentItem === p) m.flickable = pp;
    }
    Component.onCompleted: { m.findList(); m.attach(); }
    onParentChanged: m.findList()
    onFlickableChanged: m.attach()
    property Flickable _attached: null
    function attach() {
        const f = m.flickable;
        if (!f || f === m._attached) return;
        m._attached = f;
        f.maximumFlickVelocity = Math.max(f.maximumFlickVelocity, m.maxVelocity);
        if (!m.stretch) return;
        // Qt's own overshoot would bounce a fling a second, different way
        f.boundsBehavior = Flickable.StopAtBounds;
        const t = [];
        for (let i = 0; i < f.contentItem.transform.length; i++) t.push(f.contentItem.transform[i]);
        t.push(stretchScale);
        f.contentItem.transform = t;
    }

    function bounds(f) {
        return { minY: f.originY, maxY: f.originY + Math.max(0, f.contentHeight - f.height),
                 minX: f.originX, maxX: f.originX + Math.max(0, f.contentWidth - f.width) };
    }
    /// can the list move this way (positive = towards the start)?
    function canMove(f, dx, dy) {
        const b = m.bounds(f);
        const own = f === m.flickable;
        const y = own && wheelY.running ? m.goalY : f.contentY, x = own && wheelX.running ? m.goalX : f.contentX;
        return (dy > 0 && y > b.minY + 0.5) || (dy < 0 && y < b.maxY - 0.5)
            || (dx > 0 && x > b.minX + 0.5) || (dx < 0 && x < b.maxX - 0.5);
    }
    /// does a list around this one still have room this way? Then the scroll is its.
    function outerCanMove(dx, dy) {
        for (let p = m.flickable ? m.flickable.parent : null; p; p = p.parent) {
            if (typeof p.flick === "function" && p.contentItem !== undefined && p.interactive !== false && m.canMove(p, dx, dy))
                return true;
        }
        return false;
    }
    readonly property bool vertical: m.flickable ? m.flickable.flickableDirection !== Flickable.HorizontalFlick
                                                    && (m.flickable.flickableDirection !== Flickable.AutoFlickDirection || m.flickable.contentHeight > m.flickable.height)
                                                 : true
    readonly property bool horizontal: m.flickable ? m.flickable.flickableDirection !== Flickable.VerticalFlick
                                                      && (m.flickable.flickableDirection !== Flickable.AutoFlickDirection || m.flickable.contentWidth > m.flickable.width)
                                                   : false
    /// only a list that actually scrolls stretches (as on Android)
    readonly property bool scrollsY: !!m.flickable && m.vertical && m.flickable.contentHeight > m.flickable.height + 1
    readonly property bool scrollsX: !!m.flickable && m.horizontal && m.flickable.contentWidth > m.flickable.width + 1

    // ── the stretch ──
    // overY/overX: how far past the end it was pushed, in px (positive = past
    // the start). The visible stretch eases towards maxStretch, so pushing
    // harder pulls less and less, like a rubber band.
    property real overY: 0
    property real overX: 0
    readonly property real pullY: Math.sign(m.overY) * m.maxStretch * (1 - Math.exp(-Math.abs(m.overY) / 260))
    readonly property real pullX: Math.sign(m.overX) * m.maxStretch * (1 - Math.exp(-Math.abs(m.overX) / 260))
    Scale {
        id: stretchScale
        // from the edge being pulled: the top (or left) edge of what is on screen,
        // or its bottom (right) — in contentItem coordinates
        origin.y: m.flickable ? (m.overY >= 0 ? m.flickable.contentY : m.flickable.contentY + m.flickable.height) : 0
        origin.x: m.flickable ? (m.overX >= 0 ? m.flickable.contentX : m.flickable.contentX + m.flickable.width) : 0
        yScale: 1 + Math.abs(m.pullY)
        xScale: 1 + Math.abs(m.pullX)
    }
    ParallelAnimation {
        id: springBack
        NumberAnimation { target: m; property: "overY"; to: 0; duration: 420; easing.type: Easing.OutCubic }
        NumberAnimation { target: m; property: "overX"; to: 0; duration: 420; easing.type: Easing.OutCubic }
    }
    // a pulse holds a moment at its peak, then springs back
    Timer { id: pulseHold; interval: 70; onTriggered: springBack.restart() }
    function pulse(dx, dy) {
        springBack.stop();
        const cap = 600;
        if (dy !== 0) m.overY = Math.max(-cap, Math.min(cap, m.overY + dy));
        if (dx !== 0) m.overX = Math.max(-cap, Math.min(cap, m.overX + dx));
        pulseHold.restart();
    }
    /// fingers pushing against the end: pulled while they push, back on lift
    function pull(dx, dy) {
        springBack.stop(); pulseHold.stop();
        if (dy !== 0) m.overY += dy;
        if (dx !== 0) m.overX += dx;
    }
    function settle() { if (m.overY !== 0 || m.overX !== 0) springBack.restart(); }

    // a fling that runs into the end stretches by its speed
    property real lastVy: 0
    property real lastVx: 0
    Connections {
        target: m.stretch ? m.flickable : null
        function onVerticalVelocityChanged() { if (m.flickable.verticalVelocity !== 0) m.lastVy = m.flickable.verticalVelocity; }
        function onHorizontalVelocityChanged() { if (m.flickable.horizontalVelocity !== 0) m.lastVx = m.flickable.horizontalVelocity; }
        function onAtYBeginningChanged() { if (m.flickable.atYBeginning && m.flickable.flicking && m.scrollsY && m.lastVy < -200) m.pulse(0, Math.min(500, -m.lastVy * 0.08)); }
        function onAtYEndChanged() { if (m.flickable.atYEnd && m.flickable.flicking && m.scrollsY && m.lastVy > 200) m.pulse(0, -Math.min(500, m.lastVy * 0.08)); }
        function onAtXBeginningChanged() { if (m.flickable.atXBeginning && m.flickable.flicking && m.scrollsX && m.lastVx < -200) m.pulse(Math.min(500, -m.lastVx * 0.08), 0); }
        function onAtXEndChanged() { if (m.flickable.atXEnd && m.flickable.flicking && m.scrollsX && m.lastVx > 200) m.pulse(-Math.min(500, m.lastVx * 0.08), 0); }
    }

    // ── mouse wheel: glide to a goal that each notch moves on ──
    property real goalY: 0
    property real goalX: 0
    // what a notch asked for beyond the end: becomes a pulse when the glide gets there
    property real spillY: 0
    property real spillX: 0
    NumberAnimation {
        id: wheelY; target: m.flickable; property: "contentY"; duration: m.wheelMs; easing.type: Easing.OutCubic
        onFinished: if (m.spillY !== 0) { m.pulse(0, m.spillY); m.spillY = 0; }
    }
    NumberAnimation {
        id: wheelX; target: m.flickable; property: "contentX"; duration: m.wheelMs; easing.type: Easing.OutCubic
        onFinished: if (m.spillX !== 0) { m.pulse(m.spillX, 0); m.spillX = 0; }
    }

    // ── touchpad: follow, then fling ──
    property var samples: []           // [t, dx, dy]
    function release() {
        endTimer.stop();
        if (m.overY !== 0 || m.overX !== 0) { m.samples = []; m.settle(); return; }
        const f = m.flickable, now = Date.now();
        const s = m.samples.filter(e => now - e[0] < 90);
        m.samples = [];
        // fingers that stopped before lifting meant "stop here"
        if (!f || s.length < 2 || now - s[s.length - 1][0] > 50) return;
        const span = Math.max(16, s[s.length - 1][0] - s[0][0] + 8);
        let dx = 0, dy = 0;
        for (const e of s) { dx += e[1]; dy += e[2]; }
        const vx = m.horizontal ? dx / span * 1000 * m.gain : 0;
        const vy = m.vertical ? dy / span * 1000 * m.gain : 0;
        if (Math.hypot(vx, vy) >= m.minVelocity) f.flick(vx, vy);
    }
    Timer { id: endTimer; interval: 70; onTriggered: m.release() }   // no end phase came

    WheelHandler {
        parent: m.flickable
        target: null
        enabled: !!m.flickable && m.flickable.interactive
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: (w) => {
            const f = m.flickable;
            const touch = w.pixelDelta.x !== 0 || w.pixelDelta.y !== 0 || w.phase !== Qt.NoScrollPhase;
            if (touch) {
                if (w.phase === Qt.ScrollEnd) { m.release(); w.accepted = true; return; }
                const dx = m.horizontal ? w.pixelDelta.x : 0, dy = m.vertical ? w.pixelDelta.y : 0;
                if (dx === 0 && dy === 0) { w.accepted = (w.phase === Qt.ScrollUpdate && m.samples.length > 0); return; }
                // pulled past the end and now going back: undo the pull first
                if ((m.overY !== 0 && dy !== 0 && Math.sign(dy) !== Math.sign(m.overY))
                        || (m.overX !== 0 && dx !== 0 && Math.sign(dx) !== Math.sign(m.overX))) {
                    springBack.stop();
                    if (m.overY !== 0) m.overY = Math.sign(m.overY) === Math.sign(m.overY + dy) ? m.overY + dy : 0;
                    if (m.overX !== 0) m.overX = Math.sign(m.overX) === Math.sign(m.overX + dx) ? m.overX + dx : 0;
                    endTimer.restart(); w.accepted = true; return;
                }
                if (!m.canMove(f, dx, dy)) {
                    m.samples = [];
                    // the outer list's turn — or, with none, our stretch
                    if (!m.stretch || m.outerCanMove(dx, dy) || !(dy !== 0 ? m.scrollsY : m.scrollsX)) { w.accepted = false; return; }
                    if (f.flicking) f.cancelFlick();
                    m.pull(dx, dy);
                    endTimer.restart(); w.accepted = true; return;
                }
                if (f.flicking) f.cancelFlick();
                wheelY.stop(); wheelX.stop();
                const b = m.bounds(f);
                if (dy !== 0) f.contentY = Math.max(b.minY, Math.min(b.maxY, f.contentY - dy));
                if (dx !== 0) f.contentX = Math.max(b.minX, Math.min(b.maxX, f.contentX - dx));
                const now = Date.now();
                m.samples = m.samples.filter(e => now - e[0] < 90).concat([[now, dx, dy]]);
                endTimer.restart();
                w.accepted = true;
                return;
            }
            // a wheel: notches (120 per click; hi-res wheels send fractions)
            let ny = w.angleDelta.y / 120, nx = w.angleDelta.x / 120;
            // a vertical wheel over a sideways-only list scrolls it sideways
            if (!m.vertical && m.horizontal && nx === 0) { nx = ny; ny = 0; }
            if (!m.vertical) ny = 0;
            if (!m.horizontal) nx = 0;
            if (ny === 0 && nx === 0) { w.accepted = false; return; }
            if (!m.canMove(f, nx, ny)) {
                if (!m.stretch || m.outerCanMove(nx, ny) || !(ny !== 0 ? m.scrollsY : m.scrollsX)) { w.accepted = false; return; }
                m.pulse(nx * m.notch * 0.9, ny * m.notch * 0.9);
                w.accepted = true; return;
            }
            if (f.flicking) f.cancelFlick();
            const b = m.bounds(f);
            if (ny !== 0) {
                const want = (wheelY.running ? m.goalY : f.contentY) - ny * m.notch;
                m.goalY = Math.max(b.minY, Math.min(b.maxY, want));
                m.spillY = m.stretch && m.scrollsY ? (m.goalY - want) * 0.9 : 0;
                wheelY.stop(); wheelY.from = f.contentY; wheelY.to = m.goalY; wheelY.start();
            }
            if (nx !== 0) {
                const want = (wheelX.running ? m.goalX : f.contentX) - nx * m.notch;
                m.goalX = Math.max(b.minX, Math.min(b.maxX, want));
                m.spillX = m.stretch && m.scrollsX ? (m.goalX - want) * 0.9 : 0;
                wheelX.stop(); wheelX.from = f.contentX; wheelX.to = m.goalX; wheelX.start();
            }
            w.accepted = true;
        }
    }
}
