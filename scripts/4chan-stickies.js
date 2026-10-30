// ==QuarryScript==
// @name        4chan: no stickies, no ghosts
// @version     1.0
// @description Drops the pinned threads and the ones that have fallen off the bottom.
// @author      quarry
// @match       lens:fourchan
// @grant       rows
// ==/QuarryScript==

/*
 * Two rows nobody reads twice: the sticky that has been at the top of the
 * board for three years, and a thread that is about to be pruned. The board
 * marks both — `sticky`, and a reply count at the page limit — so this is
 * four lines rather than a heuristic.
 */
quarry.on("rows", function (rows, context) {
    if (context.screen !== "catalogue")
        return rows;
    return rows.filter(t => !t.sticky && !t.closed);
});
