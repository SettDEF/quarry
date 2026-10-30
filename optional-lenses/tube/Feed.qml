import qs.services
import QtQuick

/*
 * The tube sites, through quarryd — never straight from QML.
 *
 * Every page is one `search` call: the daemon builds the site's own search URL
 * from the manifest, fetches it behind the per-host limiter, files the rows in
 * the catalogue and hands them back in the site's order. That is what gives a
 * row an id, which is what `thumb` and `renditions` need — so posters and
 * qualities are paced by the same daemon rather than by a wall of XHRs.
 *
 * The daemon also answers `skipped` when a site cannot express what was asked.
 * It is surfaced rather than swallowed: an empty view that says nothing is the
 * thing this is meant to avoid.
 */
QtObject {
    id: root

    /*
     * The sites this lens covers, and what each one calls its orderings.
     *
     * All three are keyless JSON APIs with a real search — verified live before
     * this lens was written. The `sort` values are the query DSL's words, which
     * each manifest's `[request.sort]` table turns into the site's own.
     */
    readonly property var sites: [
        {
            "id": "pornhub",
            "label": "Pornhub",
            "modes": ["featured", "new", "views"]
        },
        {
            "id": "eporner",
            "label": "EPORNER",
            "modes": ["featured", "new", "views"]
        },
        {
            "id": "redtube",
            "label": "RedTube",
            "modes": ["featured", "new", "views"]
        }
    ]

    /// The DSL sort each browse mode asks for. "featured" asks for nothing, so
    /// the manifest's `default` is what the site considers its front page.
    readonly property var modeSort: ({
            "featured": "",
            "new": "sort:new",
            "views": "sort:large"
        })

    readonly property var modeLabel: ({
            "featured": "Featured",
            "new": "Newest",
            "views": "Most viewed"
        })

    // ── what is loaded ───────────────────────────────────────────────────────
    property string site: "pornhub"
    property string mode: "featured"
    property string text: ""

    property var rows: []
    property int page: 0
    property bool loading: false
    property bool hasMore: true
    /// Why there is nothing, when there is nothing. Empty means "it worked".
    property string error: ""
    /// The daemon's own words for a site that could not answer this query.
    property string skipped: ""

    signal landed(int added)

    /// A generation counter: an answer for a site or query you have left must
    /// not append itself to the one you are looking at.
    property int _generation: 0

    function siteLabel(id) {
        for (let i = 0; i < root.sites.length; i++)
            if (root.sites[i].id === id)
                return root.sites[i].label;
        return id;
    }

    /// Start over: a different site, ordering or search is a different feed.
    function reset(site, mode, text) {
        root._generation++;
        root.site = site || root.site;
        root.mode = mode || root.mode;
        root.text = text === undefined ? root.text : text;
        root.rows = [];
        root.page = 0;
        root.hasMore = true;
        root.error = "";
        root.skipped = "";
        root.loading = false;
        root.more();
    }

    /// The query as the daemon's DSL: what was typed, plus the ordering.
    function _query() {
        const words = (root.text || "").trim();
        const sort = root.modeSort[root.mode] || "";
        return [words, sort].filter(part => part.length > 0).join(" ");
    }

    function more() {
        if (root.loading || !root.hasMore)
            return;
        if (!Client.connected) {
            root.error = "Can't reach quarryd — start it and this fills in";
            return;
        }
        root.loading = true;
        const generation = root._generation;
        const next = root.page + 1;

        Client.call("search", {
            "source": root.site,
            "q": root._query(),
            "page": next
        }, function (err, payload) {
            if (generation !== root._generation)
                return;         // a different feed is on screen now
            root.loading = false;
            if (err || !payload) {
                root.error = String(err || "no answer from quarryd");
                return;
            }
            /*
             * The site said it cannot do this. Said out loud rather than drawn
             * as an empty wall — the two look identical and mean opposite
             * things.
             */
            if (payload.skipped && String(payload.skipped).length > 0) {
                root.skipped = String(payload.skipped);
                root.hasMore = false;
                return;
            }
            root.error = "";
            root.skipped = "";
            root.page = next;
            root.hasMore = payload.hasMore !== false;

            // The catalogue drops rows it already holds, so a page can answer
            // with fewer than it fetched; dedupe by id here too, because two
            // pages of a live feed overlap when new videos are posted.
            const seen = {};
            for (let i = 0; i < root.rows.length; i++)
                seen[root.rows[i].id] = true;
            const fresh = [];
            for (const item of (payload.items || []))
                if (item && item.id && !seen[item.id]) {
                    seen[item.id] = true;
                    fresh.push(item);
                }
            if (fresh.length > 0)
                root.rows = root.rows.concat(fresh);
            // A page that was entirely rows we already had is not the end of
            // the feed — but several in a row is, and the site has stopped
            // saying anything new.
            if (fresh.length === 0 && (payload.fetched || 0) === 0)
                root.hasMore = false;
            root.landed(fresh.length);
        }, 45000);
    }

    // ── one video ────────────────────────────────────────────────────────────
    /*
     * The qualities, from the daemon.
     *
     * These sites publish a poster and keep the stream on the page, so the row
     * itself is a JPEG — `renditions` is what resolves the page to real files.
     * It only answers for a row the catalogue holds, which every row here is:
     * `search` filed them on the way past.
     */
    function renditions(item, onDone) {
        if (!item || !Client.connected) {
            onDone([], "not connected");
            return;
        }
        Client.call("renditions", { "id": item.id }, function (err, payload) {
            if (err || !payload) {
                onDone([], String(err || "nothing to play"));
                return;
            }
            const list = (payload.renditions || []).filter(r => r && r.url);
            // The daemon says why when it found nothing — a page that changed
            // its player, a host that refused. Better than "no video".
            onDone(list, list.length > 0 ? "" : String(payload.error || "no playable file on that page"));
        }, 60000);
    }
}
