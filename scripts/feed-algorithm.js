// ==QuarryScript==
// @name        Feed algorithm
// @version     1.0
// @description Quietens what you did not come for — by media, by length, by whether there is a picture at all.
// @author      quarry
// @match       *
// @grant       rows, storage
// @setting     mediaMode | choice | both | What to keep | both,video only,pictures only | Everything, or only one of the two.
// @setting     minSeconds | number | 0 | Shortest video | 0..60 step 1 | Videos under this are quietened. 0 keeps them all.
// @setting     maxSeconds | number | 0 | Longest video | 0..1800 step 30 | Videos over this are quietened. 0 means no limit.
// @setting     skipGifs | switch | false | Quieten GIFs | | Animated pictures, as distinct from videos.
// @setting     hideTextless | switch | false | Quieten rows with no picture | | Rows a source gave no media for — a link or a comment with nothing to look at.
// @setting     dimStrength | number | 85 | How far to fade them | 0..100 step 5 | 100 hides them outright; anything less leaves them visible but quiet.
// ==/QuarryScript==

/*
 * A RULE YOU CAN SEE PAST.
 *
 * Every other filter in quarry answers a question you asked — `kind:avatar` is
 * a thing you typed. This one answers a question nobody asked out loud: of the
 * things that matched, which did you probably mean? That is a GUESS, and a
 * guess must not be allowed to delete anything.
 *
 * So the default is to fade rather than hide. A faded row keeps its place, so
 * the wall still looks like the catalogue rather than like a wall with holes
 * in it, and hovering one brings it back to full — whatever this script
 * believes, the thing under your pointer is the thing you are looking at.
 * Turning the fade up to 100 hides them properly, for when the rule has
 * stopped being a guess.
 *
 * Modelled on the "algorithm" section of a Reddit userscript that does the same
 * job: keep the feed to the kind of thing you are actually there for.
 */
const MODE = quarry.storage.get("mediaMode", "both");
const MIN_SECONDS = Number(quarry.storage.get("minSeconds", 0)) || 0;
const MAX_SECONDS = Number(quarry.storage.get("maxSeconds", 0)) || 0;
const SKIP_GIFS = quarry.storage.get("skipGifs", false) === true;
const HIDE_TEXTLESS = quarry.storage.get("hideTextless", false) === true;
const DIM = Math.max(0, Math.min(100, Number(quarry.storage.get("dimStrength", 85)) || 0)) / 100;

/*
 * "Wanted" is one function so the rule is written once and read once. It
 * returns true for everything by default: a setting left alone must never
 * quieten anything, or installing this script would change the wall before
 * you had told it what you wanted.
 */
function wanted(row) {
    const family = row.family || "";
    const isVideo = family === "video";

    if (MODE === "video only" && !isVideo)
        return false;
    if (MODE === "pictures only" && isVideo)
        return false;

    if (SKIP_GIFS && row.animated === true && !isVideo)
        return false;

    /*
     * A row with no media at all. Not every source gives one — a link
     * aggregator's text post has nothing to show — and on a wall those are the
     * cells that look broken rather than empty.
     */
    if (HIDE_TEXTLESS && !row.url && !row.sample && !row.thumb)
        return false;

    /*
     * LENGTH, ONLY WHERE IT IS KNOWN.
     *
     * `duration` is 0 for everything that is not a video and for videos whose
     * length nobody measured. Comparing that against a minimum would quieten
     * every picture in the catalogue — the same mistake `no-tiny-pictures`
     * made with width, which hid 19,600 rows and read as broken thumbnails.
     */
    const seconds = Number(row.duration) || 0;
    if (isVideo && seconds > 0) {
        if (MIN_SECONDS > 0 && seconds < MIN_SECONDS)
            return false;
        if (MAX_SECONDS > 0 && seconds > MAX_SECONDS)
            return false;
    }

    return true;
}

quarry.on("rows", function (rows) {
    const all = rows || [];
    // Nothing is switched on: hand the page back untouched rather than walking
    // it. This runs on every page that lands.
    if (MODE === "both" && !SKIP_GIFS && !HIDE_TEXTLESS && MIN_SECONDS === 0 && MAX_SECONDS === 0)
        return all;

    const keep = [];
    for (const row of all) {
        if (!row)
            continue;
        if (wanted(row)) {
            // Cleared explicitly: a row can be reused across pages, and a fade
            // left on it from a previous rule would never come off.
            if (row.dim)
                row.dim = 0;
            keep.push(row);
            continue;
        }
        if (DIM >= 1)
            continue;           // dropped, so quarry draws it as hidden
        row.dim = DIM;
        keep.push(row);
    }
    return keep;
});
