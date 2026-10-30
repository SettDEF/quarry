// ==QuarryScript==
// @name        No tiny pictures
// @version     1.0
// @description Hides anything under a minimum width, wherever it came from.
// @author      quarry
// @match       *
// @grant       rows, storage
// @setting     minWidth | number | 400 | Smallest picture to show | 100..2000 step 50 | Anything narrower is hidden. Pictures whose size the source never stated are always shown.
// ==/QuarryScript==

/*
 * The smallest useful script, and the one to copy when writing your own: one
 * hook, one condition, no state. What it returns is what stays — everything
 * else keeps its cell and draws a stub, so you can see what was hidden and
 * click through it anyway.
 *
 * "I DO NOT KNOW" IS NOT "SMALL", AND THE DIFFERENCE IS 19,600 ROWS.
 *
 * A row's width is 0 when the source never said how big the picture is. Half
 * the catalogue's sources do not: an SVG has no pixel size at all, and iTunes,
 * emoji.gg, lorcana, archive.org and apod simply do not publish one. Comparing
 * that 0 against a minimum hid every one of them — 11,886 vectors and 7,694
 * other rows here, about a quarter of everything — each keeping its cell and
 * drawing the hidden-by-a-filter stub.
 *
 * That reads as thumbnails being broken rather than as a filter doing what it
 * was told, and it is worse than it looks: a hidden row is never even ASKED
 * for, so nothing fails, no counter moves, and every diagnostic in the app
 * reports a clean bill of health over a wall of empty cells.
 *
 * So the rule applies only where there is a number to apply it to. A picture
 * whose size nobody stated is shown, and you can judge it with your eyes.
 */
// Declared as a setting (see the header), so the number can be changed without
// editing this file. The default is the same 400 it always was.
const MIN_WIDTH = quarry.storage.get("minWidth", 400);

quarry.on("rows", rows => (rows || []).filter(row => {
    /*
     * A HOLE IN THE PAGE IS NOT A ROW.
     *
     * A page can arrive with a gap in it, and reading `.w` off null throws —
     * which the host catches and reports as "no-tiny-pictures: rows hook:
     * TypeError", so the whole filter is skipped and a toast covers the wall.
     * The previous version had the same hole; it simply never met one.
     */
    if (!row)
        return false;

    const w = row.w || row.width || 0;
    // Unknown, not small — see above. This is also every vector, which has no
    // intrinsic size and is drawn at whatever size it is asked for.
    if (w === 0)
        return true;
    return w >= MIN_WIDTH;
}));
