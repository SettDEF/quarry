// ==QuarryScript==
// @name        Keep the whole thread
// @version     1.0
// @description One command that puts every picture on the screen into a collection.
// @author      quarry
// @match       *
// @grant       menu, keep, toast, storage
// ==/QuarryScript==

/*
 * THE GALLERY DOWNLOADER, WITHOUT THE DOWNLOADING.
 *
 * "Save every image in this thread" is the most common shape of script on the
 * script sites, and it always ends in a folder of files with names nobody can
 * search. quarry already has somewhere better to put them — a collection —
 * so this keeps the rows instead of copying the bytes, and the pictures stay
 * findable next to everything else.
 *
 * Deliberately one row at a time with no progress bar: `keep` goes through
 * the catalogue's own call, which says what it did.
 */
const INTO = quarry.storage.get("collection", "From a thread");

quarry.menu("Keep this picture here", function (item) {
    if (!item) {
        quarry.toast("Nothing to keep");
        return;
    }
    quarry.keep(item, INTO);
}, "bookmark_add");
