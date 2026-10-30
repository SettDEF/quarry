// ==QuarryScript==
// @name        4chan thread watcher
// @version     1.0
// @description Marks threads you want to come back to, and tells you when one has new replies.
// @author      quarry
// @match       lens:fourchan
// @grant       rows, menu, storage, toast
// ==/QuarryScript==

/*
 * THE OTHER HALF OF WHY PEOPLE INSTALL 4chan X.
 *
 * A board moves; a thread you cared about is three pages down an hour later.
 * The watcher remembers the ones you marked and, because the catalogue hands
 * every row its reply count, can say which of them have moved since you last
 * looked — without asking the site anything extra.
 *
 * Nothing here needs network access: the count is already in the row. That is
 * the argument for the `rows` hook being the main event rather than a fetch
 * API — most of what a filter script wants to know has already arrived.
 */
let watched = quarry.storage.get("threads", {});   // no -> replies when last seen

quarry.on("rows", function (rows, context) {
    if (context.screen !== "catalogue")
        return rows;
    let news = 0;
    for (const row of rows) {
        const seen = watched[String(row.no)];
        if (seen === undefined)
            continue;
        const now = Number(row.replies || 0);
        if (now > seen)
            news++;
    }
    if (news > 0)
        quarry.toast(`${news} watched thread${news === 1 ? " has" : "s have"} new replies`);
    return rows;    // a watcher hides nothing
});

quarry.menu("Watch this thread", function (item) {
    if (!item || item.no === undefined) {
        quarry.toast("Open a thread first");
        return;
    }
    watched[String(item.no)] = Number(item.replies || 0);
    quarry.storage.set("threads", watched);
    quarry.toast(`Watching ${item.no} — ${Object.keys(watched).length} in all`);
}, "visibility");

quarry.menu("Stop watching everything", function () {
    watched = {};
    quarry.storage.set("threads", watched);
    quarry.toast("The watch list is empty");
}, "visibility_off");
