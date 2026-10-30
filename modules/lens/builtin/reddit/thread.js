.pragma library

/*
 * A COMMENT TREE, FLATTENED.
 *
 * Nested ListViews inside a Flickable break scrolling and destroy delegate
 * recycling, so the tree becomes one list and depth becomes an indent. That
 * also makes collapsing cheap: a collapsed subtree simply does not produce
 * rows, rather than existing off-screen with its images still decoded.
 *
 * Every row carries its own depth and id, so the view is a plain ListView over
 * a plain array — the thing QML is actually good at.
 */

/// Reddit wraps everything: { kind: "t1", data: {...} }. This is the unwrap,
/// with the two kinds a thread contains kept apart.
function children(listing) {
    if (!listing || !listing.data || !listing.data.children)
        return [];
    return listing.data.children;
}

function post(payload) {
    const first = Array.isArray(payload) ? payload[0] : null;
    const rows = children(first);
    return rows.length > 0 ? rows[0].data : null;
}

/// Flatten the comment half of a thread answer.
///   collapsed: { [id]: true } — ids whose replies are hidden
///   loaded:    { [id]: [...] } — subtrees fetched for a "more" stub
function rows(payload, collapsed, loaded) {
    const second = Array.isArray(payload) && payload.length > 1 ? payload[1] : null;
    const out = [];
    walk(children(second), 0, out, collapsed || {}, loaded || {});
    return out;
}

function walk(nodes, depth, out, collapsed, loaded) {
    for (const node of nodes) {
        if (!node || !node.data)
            continue;

        if (node.kind === "more") {
            /*
             * Reddit truncates deep or long threads and leaves a stub saying
             * how much is missing. A stub that has been fetched is replaced by
             * what came back, in place, so the chain reads continuously.
             */
            const fetched = loaded[node.data.id];
            if (fetched && fetched.length > 0) {
                walk(fetched, depth, out, collapsed, loaded);
                continue;
            }
            out.push({
                "id": node.data.id || `more-${depth}-${out.length}`,
                "kind": "more",
                "depth": depth,
                "count": node.data.count || 0,
                "parentId": node.data.parent_id || "",
                "children": node.data.children || []
            });
            continue;
        }

        if (node.kind !== "t1")
            continue;

        const data = node.data;
        const id = data.id;
        const hidden = collapsed[id] === true;
        const replies = data.replies && data.replies.data ? children(data.replies) : [];

        out.push({
            "id": id,
            "kind": "comment",
            "depth": depth,
            "author": data.author || "[deleted]",
            "body": unescapeEntities(data.body || ""),
            "score": typeof data.score === "number" ? data.score : 0,
            "scoreHidden": data.score_hidden === true,
            "created": data.created_utc || 0,
            "edited": data.edited ? true : false,
            "op": data.is_submitter === true,
            "distinguished": data.distinguished || "",
            "stickied": data.stickied === true,
            "collapsed": hidden,
            // A parent with nothing under it must not offer a collapse arrow
            // that does nothing when pressed.
            "replies": replies.length
        });

        if (!hidden && replies.length > 0)
            walk(replies, depth + 1, out, collapsed, loaded);
    }
}

/// The subtree reddit answers at a comment's own permalink, ready to splice in
/// where the stub was.
function subtreeChildren(payload) {
    const second = Array.isArray(payload) && payload.length > 1 ? payload[1] : null;
    return children(second);
}

/// "4h", "3d", "just now" — a duration people read rather than a timestamp.
function ago(unixSeconds, nowMs) {
    if (!(unixSeconds > 0))
        return "";
    const seconds = Math.max(0, Math.floor((nowMs || Date.now()) / 1000 - unixSeconds));
    if (seconds < 60)
        return "just now";
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60)
        return `${minutes}m`;
    const hours = Math.floor(minutes / 60);
    if (hours < 24)
        return `${hours}h`;
    const days = Math.floor(hours / 24);
    if (days < 30)
        return `${days}d`;
    const months = Math.floor(days / 30);
    return months < 12 ? `${months}mo` : `${Math.floor(months / 12)}y`;
}

/// 12345 → "12.3k". A score is read at a glance, not audited.
function count(n) {
    const value = Number(n) || 0;
    if (Math.abs(value) < 1000)
        return String(value);
    if (Math.abs(value) < 1000000)
        return `${(value / 1000).toFixed(value % 1000 === 0 ? 0 : 1)}k`;
    return `${(value / 1000000).toFixed(1)}M`;
}

/*
 * REDDIT ESCAPES THE TEXT IT PUTS IN ITS JSON.
 *
 * `&` arrives as `&amp;`, so a preview URL's query comes through mangled — and
 * a preview URL is SIGNED, so the mangled copy fails the signature and reddit
 * answers 403. That is why the post view drew an empty dark frame and looked
 * like a layout fault. Main.qml and Wall.qml each unescape their own copy;
 * this file, which the post screen reads, never did.
 *
 * Comment bodies need the rest of the entities: a comment containing `<`, `>`
 * or a quotation mark otherwise renders as the literal `&lt;`. `&amp;` is
 * undone LAST, so `&amp;lt;` does not become a `<`.
 */
function unescapeEntities(text) {
    return String(text || "").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, "\"").replace(/&#39;/g, "'").replace(/&amp;/g, "&");
}

/// The picture a post is, if it is one. Reddit hands over several shapes and
/// only some of them are an image anybody wants to look at.
function imageUrl(post) {
    if (!post)
        return "";
    const preview = post.preview && post.preview.images && post.preview.images.length > 0 ? post.preview.images[0] : null;
    if (preview && preview.source && preview.source.url)
        return unescapeEntities(preview.source.url);
    const url = String(post.url_overridden_by_dest || post.url || "");
    return /\.(jpe?g|png|gif|webp)(\?|$)/i.test(url) ? unescapeEntities(url) : "";
}

/*
 * THE MOVING PICTURE A POST IS, IF IT IS ONE.
 *
 * Reddit serves video as DASH with the audio in a separate stream, so
 * `fallback_url` plays silently — `hls_url` is the one that carries sound, and
 * Qt's FFmpeg backend reads it. A "gif" post is neither: it is an mp4 hiding in
 * the preview's `variants`, which is why that is checked last rather than not
 * at all.
 */
function videoUrl(post) {
    if (!post)
        return "";
    const media = post.secure_media || post.media || null;
    const video = (media && media.reddit_video) || (post.preview && post.preview.reddit_video_preview) || null;
    if (video)
        return unescapeEntities(video.hls_url || video.fallback_url || "");
    const image = post.preview && post.preview.images && post.preview.images.length > 0 ? post.preview.images[0] : null;
    const mp4 = image && image.variants && image.variants.mp4 ? image.variants.mp4.source : null;
    if (mp4 && mp4.url)
        return unescapeEntities(mp4.url);
    const direct = String(post.url_overridden_by_dest || post.url || "");
    return /\.(mp4|webm)(\?|$)/i.test(direct) ? unescapeEntities(direct) : "";
}

/// A post's own shape, measured by reddit — video first, since a video post's
/// preview is a still of a different size.
function ratioOf(post) {
    if (!post)
        return 0.66;
    const media = post.secure_media || post.media || null;
    const video = (media && media.reddit_video) || (post.preview && post.preview.reddit_video_preview) || null;
    if (video && video.width > 0 && video.height > 0)
        return video.height / video.width;
    const image = post.preview && post.preview.images && post.preview.images.length > 0 ? post.preview.images[0] : null;
    const src = image ? image.source : null;
    return (src && src.width > 0 && src.height > 0) ? src.height / src.width : 0.66;
}

/// The small one, for a list. Reddit's own `thumbnail` is a word like "self"
/// or "nsfw" as often as it is a URL.
function thumbUrl(post) {
    if (!post)
        return "";
    const thumb = String(post.thumbnail || "");
    if (thumb.indexOf("http") === 0)
        return thumb;
    const preview = post.preview && post.preview.images && post.preview.images.length > 0 ? post.preview.images[0] : null;
    if (preview && preview.resolutions && preview.resolutions.length > 0)
        return unescapeEntities(preview.resolutions[0].url);
    return imageUrl(post);
}

/// Every picture of a gallery post, in order (largest version each); [] when
/// the post is not a gallery. Reddit keeps them in media_metadata, keyed by
/// the ids gallery_data lists — the order lives only in gallery_data.
function galleryUrls(post) {
    if (!post || !post.is_gallery || !post.media_metadata || !post.gallery_data)
        return [];
    const out = [];
    for (const item of (post.gallery_data.items || [])) {
        const entry = post.media_metadata[item.media_id];
        const src = entry && entry.s ? (entry.s.u || entry.s.gif || "") : "";
        if (src)
            out.push(unescapeEntities(src));
    }
    return out;
}
