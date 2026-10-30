// ==QuarryScript==
// @name        4chan: busiest first
// @version     1.0
// @description Reorders a board by reply count, and drops the threads nobody answered.
// @author      quarry
// @match       lens:fourchan
// @grant       rows, menu, storage, toast
// ==/QuarryScript==

/*
 * A `rows` HOOK CAN REORDER, NOT ONLY REMOVE.
 *
 * What comes back is what is shown, in the order it comes back — so sorting
 * is the same hook as filtering, which is worth knowing before writing a
 * second script to do it.
 *
 * A board's own order is bump order: whatever was posted in last is first,
 * which puts a thread with two replies above one with two hundred. Sorting by
 * replies is what you actually want when you open a board to read it rather
 * than to follow it.
 */
let quiet = quarry.storage.get("quiet", 3);   // fewer replies than this is noise

quarry.on("rows", function (rows, context) {
    if (context.screen !== "catalogue")
        return rows;
    const busy = rows.filter(t => Number(t.replies || 0) >= quiet || t.sticky);
    // Stickies stay on top, the way the board draws them; everything else by
    // how much is going on in it.
    return busy.slice().sort(function (a, b) {
        if (!!a.sticky !== !!b.sticky)
            return a.sticky ? -1 : 1;
        return Number(b.replies || 0) - Number(a.replies || 0);
    });
});

quarry.menu("Quiet threads: raise the bar", function () {
    quiet = quiet >= 20 ? 0 : quiet + 5;
    quarry.storage.set("quiet", quiet);
    quarry.toast(quiet === 0 ? "Showing every thread again" : `Hiding threads under ${quiet} replies`);
}, "sort");
