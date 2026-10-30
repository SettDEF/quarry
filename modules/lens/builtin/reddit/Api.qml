import qs.services
import QtQuick

/*
 * REDDIT, THROUGH QUARRYD — because there is no other way in any more.
 *
 * Every unauthenticated path has answered 403 since 2024: `www.reddit.com`'s
 * `.json` routes, `api.reddit.com`, and `old.reddit.com` which bounces to a
 * login page. Verified again from this machine while this lens was written. So
 * a lens cannot fetch reddit for itself, and it should not want to: the OAuth
 * credential belongs in the daemon, next to the token cache the user's own
 * scripts already share, and not in QML where a screen could log it.
 *
 * This is therefore a thin caller over one RPC (`reddit`, GET-only, the OAuth
 * host only). What stays here is the manners that are this lens's business: one
 * request in flight per URL, and answers kept so going back to a listing you
 * just left costs nothing.
 */
QtObject {
    id: root

    /// The daemon paces its own requests; this is the gap between the ones
    /// THIS lens starts, so scrolling a long thread cannot queue fifty.
    readonly property int minGapMs: 700
    /// For fetching a picture with curl — the API calls go through the daemon,
    /// which sends the credential's own.
    readonly property string userAgent: "quarry-lens/1.0 (desktop reader)"

    property bool busy: false
    property int inFlight: 0

    // url -> parsed json
    property var _cache: ({})
    property var _queue: []
    property double _lastStart: 0

    signal failed(string url, string message)

    /*
     * `onDone(data, error)` — exactly one of the two is real. A URL already
     * queued is not queued twice; every caller waiting on it is answered from
     * the one response.
     */
    function get(path, onDone) {
        for (let i = 0; i < root._queue.length; i++)
            if (root._queue[i].path === path) {
                root._queue[i].callbacks.push(onDone);
                return;
            }
        const queue = root._queue.slice();
        queue.push({
            "path": path,
            "callbacks": [onDone]
        });
        root._queue = queue;
        root.busy = true;
        root._maybeStart();
    }

    /// Straight from memory, for painting a screen you are going back to before
    /// the refresh lands. Null when it has never been fetched.
    function cached(path) {
        const hit = root._cache[path];
        return hit === undefined ? null : hit;
    }

    function _maybeStart() {
        if (root._queue.length === 0) {
            root.busy = root.inFlight > 0;
            return;
        }
        const now = Date.now();
        const wait = Math.max(0, root.minGapMs - (now - root._lastStart));
        if (wait > 0) {
            gap.interval = wait;
            gap.restart();
            return;
        }
        const queue = root._queue.slice();
        const job = queue.shift();
        root._queue = queue;
        root._lastStart = now;
        root._send(job);
        root._maybeStart();
    }

    property Timer _gap: Timer {
        id: gap
        repeat: false
        onTriggered: root._maybeStart()
    }

    function _send(job) {
        root.inFlight++;
        if (!Client.connected) {
            root.inFlight--;
            for (const callback of job.callbacks)
                callback(null, "Can't reach quarryd — start it and this fills in");
            root.busy = root.inFlight > 0 || root._queue.length > 0;
            return;
        }
        Client.call("reddit", {
            "path": job.path
        }, function (err, payload) {
            root.inFlight--;
            let data = null;
            let error = "";
            if (err || !payload)
                error = String(err || "no answer from quarryd");
            else {
                data = payload.json;
                const keep = {};
                for (const key in root._cache)
                    keep[key] = root._cache[key];
                keep[job.path] = data;
                root._cache = keep;
            }
            if (error.length > 0)
                root.failed(job.path, error);
            for (const callback of job.callbacks)
                callback(data, error);
            root.busy = root.inFlight > 0 || root._queue.length > 0;
            root._maybeStart();
        }, 30000);
    }

    // ── the calls this lens makes ────────────────────────────────────────────
    /// A community's listing. `after` pages it; empty starts over.
    function listing(sub, sort, after, onDone) {
        const where = sub && sub.length > 0 ? `/r/${encodeURIComponent(sub)}` : "";
        const page = after && after.length > 0 ? `&after=${encodeURIComponent(after)}` : "";
        root.get(`${where}/${sort || "hot"}?limit=50&raw_json=1${page}`, onDone);
    }

    /*
     * SOMEBODY'S OWN PAGE.
     *
     * `/user/<name>/submitted` is what they posted, which is the half of a
     * profile this lens can draw — the comments half needs a different row
     * shape. Reddit answers it with the same listing envelope as a community,
     * so everything downstream of `more()` is unchanged.
     */
    function userListing(name, sort, after, onDone) {
        const page = after && after.length > 0 ? `&after=${encodeURIComponent(after)}` : "";
        root.get(`/user/${encodeURIComponent(name)}/submitted?limit=50&raw_json=1&sort=${encodeURIComponent(sort === "hot" ? "new" : sort || "new")}${page}`, onDone);
    }

    /// What reddit calls popular — the front page of communities, for a reader
    /// with no account and therefore no subscriptions.
    function communities(onDone) {
        root.get("/subreddits/popular?limit=100&raw_json=1", onDone);
    }

    /// A post and its comments: reddit answers both in one array.
    function comments(postId, sort, onDone) {
        root.get(`/comments/${encodeURIComponent(postId)}?raw_json=1&limit=200&sort=${encodeURIComponent(sort || "confidence")}`, onDone);
    }

    /*
     * The rest of a chain that reddit truncated.
     *
     * `/api/morechildren` would fetch a batch of them in one go, and the daemon
     * does hold a token that could call it. This asks at the comment's own
     * permalink instead: one request for one chain, which is what a person who
     * pressed one stub is waiting for, and it needs no POST body full of ids
     * that reddit silently truncates at a hundred.
     */
    function subtree(postId, commentId, sort, onDone) {
        root.get(`/comments/${encodeURIComponent(postId)}/_/${encodeURIComponent(commentId)}?raw_json=1&limit=200&context=0&sort=${encodeURIComponent(sort || "confidence")}`, onDone);
    }

    /*
     * SEARCH, the site's own: posts everywhere, or inside one community
     * (restrict_sr), in reddit's orderings and time windows. Answers in the
     * listing envelope, so the feed and every layout draw it unchanged.
     */
    function searchPosts(text, sub, sort, time, after, onDone) {
        const where = sub && sub.length > 0 ? `/r/${encodeURIComponent(sub)}/search` : "/search";
        const page = after && after.length > 0 ? `&after=${encodeURIComponent(after)}` : "";
        const here = sub && sub.length > 0 ? "&restrict_sr=1" : "";
        root.get(`${where}?q=${encodeURIComponent(text)}${here}&sort=${encodeURIComponent(sort || "relevance")}&t=${encodeURIComponent(time || "all")}&limit=50&raw_json=1&type=link${page}`, onDone);
    }

    /// Communities whose name or description matches.
    function searchSubs(text, onDone) {
        root.get(`/subreddits/search?q=${encodeURIComponent(text)}&limit=12&raw_json=1`, onDone);
    }
}
