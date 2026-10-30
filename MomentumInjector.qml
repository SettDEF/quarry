import QtQuick

/**
 * Gives every Flickable/ListView/GridView in a window browser-like scrolling
 * (Momentum.qml) without touching the pages: it walks the item tree and
 * attaches a Momentum to each list that has none.
 *
 * Cheap on purpose — a walk that runs while you scroll is itself a stutter:
 *  - it never walks into a list's rows (delegates hold no lists worth having,
 *    and a wall of tiles is thousands of items)
 *  - it never runs while anything moves; it looks again every 4 s while the
 *    window is active, so pages opened later are found
 *  - a list that already has its own smooth scroller (a SmoothWheel, or a
 *    Momentum declared by hand) is left to it: two scrollers fight
 *
 *   MomentumInjector { root: someItemThatHoldsTheWholeUi }
 */
Item {
    id: inj
    property Item root: null
    property bool enabled: true
    property int lists: 0
    readonly property var momentum: Qt.createComponent("Momentum.qml")
    property var known: []          // lists seen, to tell "is anything moving?"

    function isFlickable(o) {
        return o && typeof o.flick === "function" && o.contentItem !== undefined && o.flickableDirection !== undefined;
    }
    /// a ListView / GridView / Repeater-backed list: its rows are not walked
    function isRowList(o) { return o.model !== undefined && o.delegate !== undefined; }
    /// already scrolled by something: our Momentum, or a sibling/child that
    /// names it as its `flickable` (SmoothWheel and friends)
    function handled(f) {
        for (const c of f.children) if (c.objectName === "momentum" || c.flickable === f) return true;
        for (const c of f.contentItem.children) if (c.flickable === f) return true;
        const p = f.parent;
        if (p) for (const c of p.children) if (c !== f && c.flickable === f) return true;
        return false;
    }
    function moving() {
        for (const f of inj.known) if (f && (f.moving || f.flicking)) return true;
        return false;
    }
    function scan() {
        if (!inj.enabled || !inj.root || inj.momentum.status !== Component.Ready || inj.moving()) return;
        let added = 0;
        const stack = [inj.root];
        const seen = [];
        let n = 0;
        while (stack.length && n < 6000) {
            const it = stack.pop(); n++;
            let skipRows = false;
            if (inj.isFlickable(it)) {
                seen.push(it);
                if (it.interactive !== false && !inj.handled(it)) { inj.momentum.createObject(it, { flickable: it }); added++; }
                skipRows = inj.isRowList(it);
            }
            for (const c of it.children) {
                if (skipRows && c === it.contentItem) continue;
                stack.push(c);
            }
        }
        inj.known = seen;
        if (added) { inj.lists += added; console.info(`[momentum] +${added} lists (${inj.lists} in this window)`); }
    }
    // once at start (an unfocused window still gets its lists), then now and
    // then while the window is in use
    Component.onCompleted: Qt.callLater(inj.scan)
    Timer { interval: 800; running: inj.enabled; onTriggered: inj.scan() }
    Timer {
        interval: 4000; repeat: true
        running: inj.enabled && !!inj.root && (inj.Window.active ?? true)
        onTriggered: inj.scan()
    }
}
