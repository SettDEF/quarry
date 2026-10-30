// ==QuarryScript==
// @name        4chan filter
// @version     1.0
// @description Hides threads and posts whose text matches a word, a name or a tripcode — the one feature everybody installs 4chan X for.
// @author      quarry
// @match       lens:fourchan
// @grant       rows, menu, storage, toast
// ==/QuarryScript==

/*
 * THE LIST LIVES IN THE SCRIPT, NOT IN A SETTINGS SCREEN.
 *
 * Editing the file IS the settings screen: save it and quarry reloads within
 * two seconds. That is the whole bargain of a userscript — no UI to build, no
 * preference to migrate, and the thing you are configuring is right next to
 * the reason it exists.
 *
 * A pattern is matched against the subject, the comment, the poster's name and
 * their tripcode, all lowercased. A leading `!` matches a tripcode exactly,
 * which is how you mute one person rather than one word.
 */
const HIDE = [
    "gpu",                 // plain words: matched anywhere in subject or comment
    "/g/ humor",
    "!!trip",              // a tripcode, matched exactly
];

function text(row) {
    const strip = html => String(html || "").replace(/<[^>]*>/g, " ").replace(/&\w+;/g, " ");
    return `${strip(row.sub)} ${strip(row.com)} ${row.name || ""}`.toLowerCase();
}

let muted = quarry.storage.get("muted", 0);

quarry.on("rows", function (rows, context) {
    const kept = rows.filter(function (row) {
        const hay = text(row);
        const trip = String(row.trip || "").toLowerCase();
        return !HIDE.some(p => p.startsWith("!") ? trip === p.toLowerCase() : hay.indexOf(p.toLowerCase()) >= 0);
    });
    const dropped = rows.length - kept.length;
    if (dropped > 0) {
        muted += dropped;
        quarry.storage.set("muted", muted);
    }
    return kept;
});

// How much it has actually done — a filter nobody can count is a filter
// nobody trusts.
quarry.menu("Filter: how much has it hidden?", function () {
    quarry.toast(`${muted} threads and posts hidden since this script was written`);
}, "filter_alt");
