import qs.services
import QtQuick

/*
 * Pornhub, through quarryd — never straight from QML.
 *
 * Every page is one `search` call: the daemon builds the site's own webmasters
 * URL from `sources/pornhub.toml`, fetches it behind the per-host limiter (this
 * host answers 403 to back-to-back requests, so the pacing is not optional),
 * files the rows in the catalogue and hands them back in the site's order.
 * Filing them is what gives a row an id, which is what `thumb` and `renditions`
 * need — so posters and qualities are paced by the same daemon rather than by a
 * grid full of XHRs.
 *
 * A CATEGORY IS A PARAMETER, and for a while this file said it was not.
 *
 * `category=` rejects the IDS its own categories endpoint publishes — that part
 * was right, and re-probed 2026-09-29: `category=37` answers HTTP 200 with
 * `{"message": "Category does not exist!"}`. But it takes the NAME. Probed side
 * by side the same day: `search=18-25` returned a lesbian MILF video first,
 * `category=18-25` a college-girl one. Both answer 30 rows, so nothing looked
 * broken — opening a category simply gave you a word search that happened to
 * contain the word, which is why the results never felt like the category.
 *
 * So the category goes down as `category:<name>`, which the DSL pushes to the
 * site's own parameter (see `Capabilities::categories`), and only a typed
 * search stays a word. The daemon checks the name against the manifest's own
 * list first, because an unknown one — or two at once — answers with that same
 * 200-with-an-error, which parses as "no results" rather than as a failure.
 */
QtObject {
    id: root

    /// Each of these is a word in `sources/pornhub.toml`'s `[request.sort]`
    /// table, which turns it into the site's own parameters — including the
    /// two-parameter ones, where an ordering also carries a period.
    readonly property var modeSort: ({
            "featured": "",
            "new": "sort:new",
            "views": "sort:large",
            "week": "sort:week",
            "month": "sort:month",
            "year": "sort:year",
            "rated": "sort:rated",
            "rated_week": "sort:rated_week",
            "rated_month": "sort:rated_month"
        })

    readonly property var modeLabel: ({
            "featured": "Featured",
            "new": "Newest",
            "views": "Most viewed",
            "week": "Most viewed this week",
            "month": "Most viewed this month",
            "year": "Most viewed this year",
            "rated": "Top rated",
            "rated_week": "Top rated this week",
            "rated_month": "Top rated this month"
        })

    // ── what is loaded ───────────────────────────────────────────────────────
    property string mode: "featured"
    property string category: ""
    property string text: ""
    /// The site's first question — straight, gay, transgender, sapphic — which
    /// it answers with a category word rather than a parameter.
    property string orientation: ""

    /*
     * THE GRID READS THE MODEL, NOT THE ARRAY.
     *
     * `rows` is a plain JS array and appending to it means assigning a NEW
     * array — which a view treats as a different model entirely: it throws away
     * every delegate and puts you back at the top. That is the jump: it
     * happened every time a page landed, which while scrolling is every few
     * seconds. A ListModel is appended to, so the view keeps its delegates,
     * keeps its place, and the new rows simply arrive underneath.
     *
     * The array stays for the logic that wants one — what is next, where you
     * are in the feed — and the two are filled in the same breath.
     */
    property var rows: []

    readonly property ListModel model: ListModel {
        id: rowModel
    }
    property int page: 0
    property bool loading: false
    property bool hasMore: true
    /// Why there is nothing, when there is nothing. Empty means "it worked".
    property string error: ""
    /// The daemon's own words for a query the site cannot express.
    property string skipped: ""

    signal landed(int added)

    /// A generation counter: an answer for a query you have left must not
    /// append itself to the one you are looking at.
    property int _generation: 0
    /// How many times in a row a short page has been chased with another.
    property int _chased: 0

    /*
     * WHERE A FEED STARTS.
     *
     * Page one of "featured" is the site's front page, and it is the same front
     * page every time you open the lens — which is what "it always loads the
     * same things" is. The site has hundreds of pages of it, so a browse with
     * no search behind it starts somewhere in the first twenty instead, and
     * pages on from there. A SEARCH always starts at one: when you have asked
     * for something specific, the best matches are the point.
     */
    property int startPage: 1

    function _pickStart() {
        if ((root.text || "").trim().length > 0)
            return 1;
        return 1 + Math.floor(Math.random() * 20);
    }

    /// Start over — a different ordering, category or search is a different feed.
    function reset(mode, category, text) {
        root._generation++;
        root.mode = mode === undefined ? root.mode : mode;
        root.category = category === undefined ? root.category : category;
        root.text = text === undefined ? root.text : text;
        root.rows = [];
        rowModel.clear();
        root.startPage = root._pickStart();
        root.page = root.startPage - 1;
        root._chased = 0;
        root.hasMore = true;
        root.error = "";
        root.skipped = "";
        root.loading = false;
        root.more();
    }

    /*
     * The query as the daemon's DSL: the words, the category, then the ordering.
     *
     * The category is a PREDICATE, not a word — see the note at the top. Typing
     * while a category is open still searches inside it, because the two are
     * ANDed like every other pair of clauses, which is the behaviour this
     * function has always promised and now actually delivers.
     *
     * Quoted, because a category can be two words ("big tits") and an unquoted
     * space would end the predicate and start a search term.
     */
    function query() {
        const words = [root.orientation, (root.text || "").trim()].filter(part => part && part.length > 0).join(" ");
        const category = root.category && root.category.length > 0 ? `category:"${root.category}"` : "";
        const sort = root.modeSort[root.mode] || "";
        return [words, category, sort].filter(part => part.length > 0).join(" ");
    }

    /// Somewhere else in the same feed — the button that says "not these".
    function shuffle() {
        root._generation++;
        root.rows = [];
        rowModel.clear();
        root.hasMore = true;
        root.error = "";
        root.skipped = "";
        root.loading = false;
        root.startPage = 1 + Math.floor(Math.random() * 40);
        root.page = root.startPage - 1;
        root.more();
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
            "source": "pornhub",
            "q": root.query(),
            "page": next
        }, function (err, payload) {
            if (generation !== root._generation)
                return;             // a different feed is on screen now
            root.loading = false;
            if (err || !payload) {
                root.error = String(err || "no answer from quarryd");
                return;
            }
            /*
             * The site said it cannot do this. Said out loud rather than drawn
             * as an empty grid — the two look identical and mean opposite
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

            /*
             * The catalogue drops rows it already holds, so a page can answer
             * with fewer than it fetched — and two pages of a live feed overlap
             * whenever something new is posted while you are reading. Dedupe by
             * id here as well, or the same poster appears twice in one column.
             */
            const seen = {};
            for (let i = 0; i < root.rows.length; i++)
                seen[root.rows[i].id] = true;
            const fresh = [];
            for (const item of (payload.items || []))
                if (item && item.id && !seen[item.id]) {
                    seen[item.id] = true;
                    fresh.push(item);
                }
            if (fresh.length > 0) {
                root.rows = root.rows.concat(fresh);
                for (const row of fresh)
                    rowModel.append({
                        "row": row
                    });
            }
            // A page that was entirely rows we already had is not the end of the
            // feed. A page that fetched nothing at all is.
            if (fresh.length === 0 && (payload.fetched || 0) === 0)
                root.hasMore = false;
            root.landed(fresh.length);

            /*
             * A THIN PAGE IS NOT A SCREEN.
             *
             * The daemon leaves out rows it has written off, so thirty fetched
             * can arrive as fifteen — and on the first page that is a grid with
             * gaps at the bottom and nothing scrolling yet to ask for more. So
             * a short page asks for the next one itself, up to a few times,
             * which is what a person would do anyway.
             */
            if (root.hasMore && fresh.length < 18 && root._chased < 3) {
                root._chased++;
                Qt.callLater(root.more);
            } else if (fresh.length >= 18) {
                root._chased = 0;
            }
        }, 45000);
    }

    // ── one video ────────────────────────────────────────────────────────────
    /*
     * What it actually plays, from the daemon.
     *
     * The row IS a poster — this site publishes the still and keeps the stream
     * on the page — so `renditions` is what resolves a page to real files. It
     * only answers for a row the catalogue holds, which every row here is:
     * `search` filed them on the way past.
     */
    function renditions(item, onDone) {
        if (!item || !Client.connected) {
            onDone([], "not connected");
            return;
        }
        Client.call("renditions", {
            "id": item.id,
            // A live feed shows rows the catalogue did not keep — it drops the
            // ones it already holds under another id — and those used to be
            // told "no such item" about a video plainly on the screen. The page
            // is enough to resolve one, so it goes along too.
            "pageUrl": String(item.page_url || item.url || "")
        }, function (err, payload) {
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
