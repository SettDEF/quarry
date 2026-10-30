// ==QuarryScript==
// @name        Hide what I have already seen
// @version     1.0
// @description Remembers everything you open and keeps it out of the way next time.
// @author      quarry
// @match       *
// @grant       rows, menu, storage, toast
// ==/QuarryScript==

/*
 * THE MOST-INSTALLED IDEA ON THE ADULT SCRIPT SITES, WHICH IS NOT AN ACCIDENT.
 *
 * Every gallery you browse twice has the same problem: the second visit looks
 * exactly like the first, and the twenty things you already opened are still
 * taking up the top of the screen. The fix needs two moments — the one where
 * you open something, and the one where rows arrive — and quarry gives a
 * script both.
 *
 * Stored by id, capped, because a set that grows for ever in a settings file
 * is a settings file that eventually takes a second to parse.
 */
const LIMIT = 5000;
let seen = quarry.storage.get("seen", {});
let hiding = quarry.storage.get("hiding", true);

quarry.on("item.open", function (payload) {
    const item = payload.item;
    if (!item || !item.id)
        return;
    seen[item.id] = 1;
    const ids = Object.keys(seen);
    if (ids.length > LIMIT) {
        // Oldest-first is not knowable from a plain object, so the cheapest
        // honest thing is to drop the front of the list rather than pretend.
        for (const id of ids.slice(0, ids.length - LIMIT))
            delete seen[id];
    }
    quarry.storage.set("seen", seen);
});

quarry.on("rows", function (rows) {
    if (!hiding)
        return rows;
    return rows.filter(row => !seen[row.id]);
});

quarry.menu("Seen: hide or show them", function () {
    hiding = !hiding;
    quarry.storage.set("hiding", hiding);
    quarry.toast(hiding ? `Hiding ${Object.keys(seen).length} you have opened` : "Showing everything again");
}, "history");

quarry.menu("Seen: forget everything", function () {
    seen = {};
    quarry.storage.set("seen", seen);
    quarry.toast("Forgotten — everything is new again");
}, "delete_history");
