/*
 * HOW MANY VIDEOS ARE IN EACH CATEGORY.
 *
 * The webmasters API publishes the category list and NOTHING else — no count,
 * no cover, no ordering — and a plain HTTP fetch of the categories page gets
 * HTML without the numbers, because the tiles are filled in by the page's own
 * JavaScript after it loads. The site draws them for a browser; quarry now
 * has one (see browser/main.cpp --dump), so this asks the page rather than
 * guessing or leaving the counts blank.
 *
 * Each tile is one link whose text reads "<Name> <count> Videos". Nothing
 * here depends on a class name: classes are minified and change with every
 * deploy, while the shape of the sentence is what the page is FOR.
 */
(function () {
    const rows = {};
    const links = document.querySelectorAll("a[href*='/video?c='], a[href*='/categories/']");
    for (const a of links) {
        const text = (a.textContent || "").replace(/\s+/g, " ").trim();
        const m = text.match(/^(.+?)\s+([\d.,]+)\s*Videos$/i);
        if (!m)
            continue;
        const name = m[1].trim();
        const videos = parseInt(m[2].replace(/[.,]/g, ""), 10);
        if (name.length === 0 || !isFinite(videos))
            continue;
        // The same category appears in the grid and in the menu; the larger
        // reading is the grid's, and they agree anyway.
        if (!rows[name] || rows[name].videos < videos)
            rows[name] = { name: name, videos: videos, href: a.getAttribute("href") || "" };
    }
    return JSON.stringify(Object.keys(rows).map(k => rows[k]).sort((a, b) => b.videos - a.videos));
})()
