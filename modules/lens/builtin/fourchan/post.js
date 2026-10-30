.pragma library

/*
 * 4chan comment markup → what Qt's rich text can draw.
 *
 * `com` is a small, fixed set of tags — <br>, <span class="quote"> for
 * greentext, <a class="quotelink"> for a reply reference, <s> for a spoiler,
 * <pre class="prettyprint"> for code, and <wbr> as a soft break. Everything
 * else is entity-escaped by the site, so this is a translation, not a sanitiser
 * for arbitrary HTML — and nothing here ever loads a remote resource.
 */

/// Quote references (>>123) a post makes, so backlinks can be built.
function quotedBy(com) {
    const out = [];
    const re = /class="quotelink"[^>]*>&gt;&gt;(\d+)</g;
    let m;
    while ((m = re.exec(com || "")) !== null)
        out.push(parseInt(m[1], 10));
    return out;
}

/// no → [nos that replied to it].
function backlinks(posts) {
    const map = {};
    for (let i = 0; i < posts.length; i++) {
        const refs = quotedBy(posts[i].com);
        for (let j = 0; j < refs.length; j++) {
            if (!map[refs[j]])
                map[refs[j]] = [];
            if (map[refs[j]].indexOf(posts[i].no) < 0)
                map[refs[j]].push(posts[i].no);
        }
    }
    return map;
}

/*
 * Rich text for one comment.
 *
 * `colors` carries the palette in, so the same translation serves a skin using
 * the app's roles and a skin using the site's own cream-and-maroon.
 * Quotelinks become `post:<no>` hrefs — the skin decides what that does.
 */
function toRich(com, colors, spoilersShown) {
    let s = String(com || "");

    s = s.replace(/<wbr\s*\/?>/gi, "");
    s = s.replace(/<a[^>]*class="quotelink"[^>]*href="#p(\d+)"[^>]*>(.*?)<\/a>/gi, `<a href="post:$1" style="color:${colors.link}">$2</a>`);
    // Cross-board links go nowhere useful inside the reader; keep the text.
    s = s.replace(/<a[^>]*class="quotelink"[^>]*>(.*?)<\/a>/gi, `<span style="color:${colors.link}">$1</span>`);
    s = s.replace(/<span class="quote">(.*?)<\/span>/gi, `<span style="color:${colors.quote}">$1</span>`);
    s = s.replace(/<span class="deadlink">(.*?)<\/span>/gi, `<span style="color:${colors.dim}">$1</span>`);
    s = s.replace(/<pre[^>]*>([\s\S]*?)<\/pre>/gi, `<span style="font-family:monospace;color:${colors.code}">$1</span>`);
    // A spoiler is blacked out by painting it on itself — Qt rich text has no
    // click target inside a run, so revealing is a switch on the whole thread.
    if (spoilersShown)
        s = s.replace(/<s>([\s\S]*?)<\/s>/gi, `<span style="color:${colors.spoiler}">$1</span>`);
    else
        s = s.replace(/<s>([\s\S]*?)<\/s>/gi, `<span style="background-color:${colors.text};color:${colors.text}">$1</span>`);
    // Anything left that is not one of ours, dropped rather than drawn.
    s = s.replace(/<(?!\/?(br|span|a|b|i|u)\b)[^>]*>/gi, "");
    return s;
}

/// Entity-decoded plain text, for filtering and for a one-line preview.
function plain(com) {
    return String(com || "")
        .replace(/<br\s*\/?>/gi, " ")
        .replace(/<[^>]+>/g, "")
        .replace(/&gt;/g, ">")
        .replace(/&lt;/g, "<")
        .replace(/&quot;/g, '"')
        .replace(/&#0?39;/g, "'")
        .replace(/&amp;/g, "&")
        .replace(/\s+/g, " ")
        .trim();
}

/// 1234567 → "1.2 MB"; the site reports bytes.
function size(bytes) {
    const n = Number(bytes) || 0;
    if (n >= 1048576)
        return (n / 1048576).toFixed(1) + " MB";
    if (n >= 1024)
        return Math.round(n / 1024) + " kB";
    return n + " B";
}

/// Unix seconds → "3h ago".
function age(unix) {
    const secs = Math.max(0, Math.floor(Date.now() / 1000) - (Number(unix) || 0));
    if (secs < 60)
        return "just now";
    if (secs < 3600)
        return Math.floor(secs / 60) + "m ago";
    if (secs < 86400)
        return Math.floor(secs / 3600) + "h ago";
    return Math.floor(secs / 86400) + "d ago";
}

/// A QML color as "#rrggbb" — rich text needs CSS, and a color's own
/// toString() hands back "#aarrggbb" whenever it carries alpha.
function hex(c) {
    const part = v => Math.round(Math.max(0, Math.min(1, v)) * 255).toString(16).padStart(2, "0");
    return "#" + part(c.r) + part(c.g) + part(c.b);
}
