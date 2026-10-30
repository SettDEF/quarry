import QtQuick
import "../modules/gallery"

/*
 * Geometry harness — runs headless, so measuring never needs a screen:
 *
 *   QT_QPA_PLATFORM=offscreen QT_ASSUME_STDERR_HAS_CONSOLE=1 \
 *     qml6 -I <repo>/modules tools/perf-geometry.qml
 *
 * It measures the two operations the wall does per scroll step at catalog
 * scale: the masonry rebuild (O(n), on a resize) and windowFor (per step).
 */
Item {
    id: harness

    property var sizes: [1000, 10000, 100000, 137000]

    function makeItems(n) {
        const out = new Array(n);
        // Deterministic pseudo-random aspects — same shape distribution every
        // run, so two runs are comparable.
        let seed = 12345;
        for (let i = 0; i < n; i++) {
            seed = (seed * 1103515245 + 12345) & 0x7fffffff;
            const r = 0.4 + (seed % 1000) / 1000 * 2.2;
            out[i] = {
                "ratio": r
            };
        }
        return out;
    }

    Component.onCompleted: {
        console.log("n\trebuild(ms)\twindowFor(µs, avg of 2000)\tappend2k(ms)\ttotalHeight(px)");
        for (const n of harness.sizes) {
            const items = harness.makeItems(n);

            const t0 = Date.now();
            geom.columns = 5;
            geom.columnWidth = 330;
            geom.items = items;          // triggers rebuild()
            const rebuild = Date.now() - t0;

            // Sample windowFor across the whole scroll range.
            const height = geom.totalHeight;
            const t1 = Date.now();
            const iterations = 2000;
            for (let k = 0; k < iterations; k++) {
                const top = (k / iterations) * height;
                geom.windowFor(top - 900, top + 1800);
            }
            const perCall = (Date.now() - t1) * 1000 / iterations;

            // Append a page onto what is already placed: same prefix objects,
            // so this must take the incremental path.
            const grown = items.slice();
            for (let k = 0; k < 2000; k++)
                grown.push({
                    "ratio": 1.0 + (k % 7) / 10
                });
            const t2 = Date.now();
            geom.items = grown;
            const append = Date.now() - t2;

            console.log(`${n}\t${rebuild}\t\t${perCall.toFixed(1)}\t\t\t${append}\t\t${Math.round(height)}`);
        }
        Qt.exit(0);
    }

    SlotGeometry {
        id: geom
        gap: 6
    }
}
