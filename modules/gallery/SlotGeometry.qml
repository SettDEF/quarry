import QtQuick

/*
 * Masonry geometry, kept out of the view on purpose.
 *
 * Rodded's wall creates one Item per post so the layout stays stable while the
 * expensive part comes and goes. That is right for a feed of 200; this catalog
 * is meant to hold 100k, and 100k QObjects cost more than every image on screen
 * put together.
 *
 * So the geometry lives here as three flat arrays — x, y, height, indexed by
 * item — plus one ascending index list per column. Nothing is instantiated. The
 * view asks `windowFor(top, bottom)` for a contiguous index range and draws that
 * with a fixed pool of tiles.
 */
QtObject {
    id: root

    /*
     * Laid out from ratios, not records: the view never holds a catalog's worth
     * of objects (measured at ~6.8 KB each), and a ratio is all masonry needs.
     */
    property var ratios: []
    property int count: 0
    property int columns: 4
    property real columnWidth: 300
    property real gap: 6

    property real totalHeight: 0
    property var xs: []
    property var ys: []
    property var hs: []
    property var colIndex: []        // colIndex[c] = [item indices, ascending y]

    // Placement state, kept so a page of new items costs O(added) instead of
    // O(everything): if the count only grew, the prefix is already laid out.
    property var _heights: []
    property int _placed: 0
    // How many slots actually have a position. Views must not read xs/ys past
    // this, and the count alone does not imply placement.
    readonly property alias placed: root._placed

    /*
     * Bumped on every placement.
     *
     * `colIndex` is appended to in place — that is what makes an incremental
     * page cost O(added) — but a mutated `var` property notifies nobody, so a
     * view binding to `colIndex.length` never learns that rows exist. The wall
     * built no tiles at all and showed an empty grid. This counter is the
     * notification.
     */
    property int revision: 0

    // Last placement cost, so the perf harness can read it over IPC instead of
    // someone having to watch a window.
    property real lastPlaceMs: 0
    property int lastPlaceCount: 0

    signal rebuilt

    /// Clamped aspect per row, computed once per result and reused by every
    /// rescale. Rebuilt when the ratios array or its length changes.
    property var _aspects: null
    property var _aspectsFor: null
    function _aspectCache() {
        const ratios = root.ratios;
        const n = root._placed;
        if (root._aspects && root._aspectsFor === ratios && root._aspects.length >= n)
            return root._aspects;
        const out = new Float64Array(n);
        for (let i = 0; i < n; i++) {
            const r = ratios[i] > 0 ? ratios[i] : 1.0;
            const a = 1.0 / r;
            out[i] = a < 0.38 ? 0.38 : (a > 2.8 ? 2.8 : a);
        }
        root._aspects = out;
        root._aspectsFor = ratios;
        return out;
    }

    function _aspect(i) {
        // Clamp: a 1:20 novelty image would otherwise own a whole column.
        const r = root.ratios[i] > 0 ? root.ratios[i] : 1.0;
        return Math.max(0.38, Math.min(2.8, 1.0 / r));
    }

    function rebuild() {
        const cols = Math.max(1, root.columns);
        if (root.columnWidth <= 0)
            return;

        /*
         * Empty and grown by push, never `new Array(n)` or `length = n`.
         * A pre-sized array is a hole-filled one, and a holey array is read
         * through a slower path for the rest of its life — measured here as
         * windowFor going from 6 µs to 15 µs at 100k, which is the difference
         * between free and noticeable once it runs per scroll step.
         */
        /*
         * The three geometry arrays are NOT emptied.
         *
         * Assigning [] publishes a zero-length array to every binding that
         * reads them, which is the same hole `colIndex` had: a cell's height
         * evaluates to 0 mid-rebuild. `_place` overwrites each slot in place
         * and the tail is trimmed at the end, and an in-place write notifies
         * nobody — which is exactly what a rebuild wants.
         */
        root._heights = [];
        /*
         * Built aside and published ONCE, at the end.
         *
         * Assigning an empty colIndex here told the wall, for the length of a
         * rebuild, that every column had no rows: each column ListView dropped
         * its model to zero, destroyed its delegates and clamped its own
         * contentY to the top — which is the "it put me back at the top" every
         * appended page produced.
         */
        const built = [];
        for (let c = 0; c < cols; c++) {
            root._heights.push(0);
            built.push([]);
        }
        root._placed = 0;
        root._place(0, built);
    }

    /*
     * Place items [from, items.length) into the columns as they stand.
     *
     * This is the whole of the layout: deal each item to the column that is
     * currently shortest, so the bottoms stay level, and record its exact x, y
     * and height. Called with from = 0 it is a full rebuild; called with the
     * previous count it is an append, and an append is what paging does.
     */
    /// `into` is the column index to fill: a rebuild passes its own, so nothing
    /// ever sees a half-built one.
    function _place(from, into) {
        const started = Date.now();
        const n = root.count;
        const cols = root._heights.length;
        const w = root.columnWidth;
        if (cols === 0 || w <= 0)
            return;

        const xs = root.xs;
        const ys = root.ys;
        const hs = root.hs;
        const heights = root._heights;
        const colIdx = into || root.colIndex;

        for (let i = from; i < n; i++) {
            let shortest = 0;
            for (let c = 1; c < cols; c++)
                if (heights[c] < heights[shortest])
                    shortest = c;

            const h = Math.round(w * root._aspect(i));
            const x = shortest * (w + root.gap);
            const y = heights[shortest];
            if (i < xs.length) {
                xs[i] = x;
                ys[i] = y;
                hs[i] = h;
            } else {
                xs.push(x);
                ys.push(y);
                hs.push(h);
            }
            colIdx[shortest].push(i);
            heights[shortest] += h + root.gap;
        }

        let tallest = 0;
        for (let c = 0; c < cols; c++)
            tallest = Math.max(tallest, heights[c]);

        if (into) {
            root.colIndex = into;
            // Anything the old layout had past the new end is not geometry any
            // more. Truncating in place notifies nobody, like the writes above.
            xs.length = n;
            ys.length = n;
            hs.length = n;
        }
        root._placed = n;
        root.lastPlaceMs = Date.now() - started;
        root.lastPlaceCount = n - from;
        root.revision++;
        root.totalHeight = tallest;
        root.rebuilt();
    }

    /*
     * Growth check. Paging only ever appends, so a larger count with the same
     * ratio array identity means the prefix is untouched and only the tail needs
     * placing. A new query replaces the array, and that is a real rebuild.
     */
    property var _ratiosRef: null

    function _refresh() {
        if (root.ratios === root._ratiosRef && root.count > root._placed) {
            root._place(root._placed);
            return;
        }
        root._ratiosRef = root.ratios;
        root.rebuild();
    }

    /*
     * The visible index range.
     *
     * Per column, binary-search the first slot whose bottom is past `top`, then
     * walk while the top is above `bottom`. Items are dealt in order, so the
     * union across columns is very nearly contiguous — taking min..max costs a
     * little overdraw at the edges and buys the view a fixed-size tile pool that
     * never instantiates anything while scrolling.
     */
    function windowFor(top, bottom) {
        const cols = root.colIndex.length;
        if (cols === 0)
            return { "first": 0, "last": -1 };

        let first = Number.MAX_SAFE_INTEGER;
        let last = -1;

        for (let c = 0; c < cols; c++) {
            const list = root.colIndex[c];
            if (list.length === 0)
                continue;

            let lo = 0;
            let hi = list.length - 1;
            let start = list.length;
            while (lo <= hi) {
                const mid = (lo + hi) >> 1;
                const i = list[mid];
                if (root.ys[i] + root.hs[i] >= top) {
                    start = mid;
                    hi = mid - 1;
                } else {
                    lo = mid + 1;
                }
            }

            for (let k = start; k < list.length; k++) {
                const i = list[k];
                if (root.ys[i] > bottom)
                    break;
                if (i < first)
                    first = i;
                if (i > last)
                    last = i;
            }
        }

        if (last < 0)
            return { "first": 0, "last": -1 };
        return { "first": first, "last": last };
    }

    /*
     * A WIDTH CHANGE IS A RESCALE, NOT A REBUILD.
     *
     * Which column a picture is in was decided by comparing column heights,
     * and every height scales with the column width — so a new width does not
     * change the assignment, only the numbers. Re-running the whole masonry
     * for 130,000 rows on every width change (opening the sidebar, resizing
     * the window) cost a tenth of a second, and it ran TWICE when the column
     * count changed in the same step. Now:
     *
     *   - a new column count, or new rows from a new query: a real rebuild
     *   - a new width with the same columns: positions recomputed in place,
     *     column by column, keeping every assignment (and every live tile)
     *   - several of these in one event-loop turn: done once
     *
     * The constant gap means a rescaled wall is not bit-identical to a fresh
     * one; the columns can differ in length by a few gaps, which nothing can
     * see, and the next query rebuilds it exactly.
     */
    property bool _needRebuild: false
    property bool _needRescale: false

    function _schedule(rebuild) {
        if (rebuild)
            root._needRebuild = true;
        else
            root._needRescale = true;
        Qt.callLater(root._flush);
    }

    function _flush() {
        const rebuild = root._needRebuild;
        const rescale = root._needRescale;
        root._needRebuild = false;
        root._needRescale = false;
        if (rebuild)
            root.rebuild();
        else if (rescale)
            root._rescale();
    }

    function _rescale() {
        // An append dropped because the width was momentarily 0 (a sidebar
        // animating through it) is otherwise stranded: nothing but a count or
        // ratios change would place those rows again.
        if (root.count > root._placed && root.columnWidth > 0 && root._heights.length > 0) {
            root._place(root._placed);
            return;
        }
        const cols = root.colIndex.length;
        if (cols === 0 || cols !== Math.max(1, root.columns) || root._placed === 0) {
            root.rebuild();
            return;
        }
        const w = root.columnWidth;
        if (w <= 0)
            return;
        const started = Date.now();
        const ys = root.ys;
        const hs = root.hs;
        const heights = root._heights;
        const gap = root.gap;
        // Every lookup hoisted out of the loop: this runs over every row, and
        // a property read or a function call per row is most of its cost.
        const aspects = root._aspectCache();
        const colIndex = root.colIndex;
        let tallest = 0;
        for (let c = 0; c < cols; c++) {
            const list = colIndex[c];
            const n = list.length;
            let y = 0;
            for (let k = 0; k < n; k++) {
                const i = list[k];
                const h = Math.round(w * aspects[i]);
                ys[i] = y;
                hs[i] = h;
                y += h + gap;
            }
            heights[c] = y;
            if (y > tallest)
                tallest = y;
        }
        root.lastPlaceMs = Date.now() - started;
        root.lastPlaceCount = root._placed;
        root.totalHeight = tallest;
        root.revision++;
        root.rebuilt();
    }

    onRatiosChanged: root._refresh()
    onCountChanged: root._refresh()
    onColumnsChanged: root._schedule(true)
    onColumnWidthChanged: root._schedule(false)
}
