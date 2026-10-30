import QtQuick
import Quickshell.Io
import qs.modules.lens
import qs.services

/*
 * THE PORNHUB LENS — one site, all of it.
 *
 * The Tube lens covers three video sites shallowly: three orderings each and a
 * search box. That is the right shape for "these are also video sites"; it is
 * the wrong shape for the one you actually browse, where the site's own table
 * of contents — thirty-six categories — is how anybody finds anything. Here the
 * categories ARE the navigation: they fill the rail, they are chips over the
 * grid, and a search runs inside whichever one is open.
 *
 * Everything goes through quarryd (see Feed.qml). Nothing is scraped here and
 * nothing is guessed: the orderings are the API's own, the categories are the
 * manifest's, and the qualities come from the video's page rather than from a
 * pattern somebody hoped would hold.
 *
 * This file is the STATE. The skins under skins/ read it and draw. Neither of
 * them owns anything that has to survive, which is what lets you change skin
 * mid-video and land on the same second of the same clip.
 */
Lens {
    // A page that answered something unparseable is not worth a
    // toast: the screen simply stays as it was, without counts.
    //     * THE CATEGORIES SCREEN, IN THE SHAPE THE SITE'S OWN MENU HAS.
    //     *
    //     * Its menu is orientation down the side, a wall of category cards with a
    //     * picture on each, and a row of the filters people actually type. Two of
    //     * those three are free: the list is the site's, and the filters are words.
    //     *
    //     * The pictures are NOT free — `/categories` publishes an id and a name and
    //     * nothing else, and fetching a poster for each of 243 would be 243
    //     * requests at one a second. So a card shows a picture quarry already holds
    //     * for that word, which fills in as you browse and is honest when it does
    //     * not: a named tile rather than a fake thumbnail.
    //     * A PICTURE FOR EACH CATEGORY, FETCHED ONLY WHEN IT IS LOOKED AT.
    //     *
    //     * The API publishes a name and nothing else, so a wall of 243 cards has no
    //     * pictures unless something goes and gets them. Fetching all 243 up front
    //     * is four minutes of requests for decoration; fetching none leaves a wall
    //     * of grey boxes. So a card asks for its own cover WHEN IT IS ON SCREEN —
    //     * one search, one row, cached for the session — and at most two are in
    //     * flight at a time so the grid never becomes a burst against a host that
    //     * answers 403 to bursts.
    // ── one video ────────────────────────────────────────────────────────────
    //     * Opening a row asks the daemon what it actually plays.
    //     *
    //     * There is nothing to play until `renditions` has resolved the page, so the
    //     * poster stays up and says which of the two it is doing — resolving, or
    //     * failed, in the daemon's words. The best quality is chosen because that is
    //     * what a quality list is for; the rest stay one click away.
    // The page, for the Referer these hosts insist on — and so a row
    // the catalogue dropped can still be played.
    // ── navigation ───────────────────────────────────────────────────────────
    //     * The rail becomes the site's contents page while this lens is open: the
    //     * three orderings, then every category. A category the site does not have
    //     * cannot appear here, because this list IS the site's.

    id: root

    property string screen: "browse"
    /*
     * THE SITE'S OWN ORDERINGS, INCLUDING ITS PERIODS.
     *
     * "Most viewed" on Pornhub is really `ordering=mostviewed` plus a `period`,
     * and the site offers the same for its rating. The manifest expresses both
     * as one sort word each, so the lens can offer them as a menu rather than
     * as three chips that cover a third of what the site does.
     */
    property string mode: "featured"
    readonly property var modes: [{
        "id": "featured",
        "label": "Featured",
        "icon": "local_fire_department",
        "group": ""
    }, {
        "id": "new",
        "label": "Newest",
        "icon": "schedule",
        "group": ""
    }, {
        "id": "views",
        "label": "Most viewed · all time",
        "icon": "trending_up",
        "group": "Most viewed"
    }, {
        "id": "week",
        "label": "This week",
        "icon": "trending_up",
        "group": "Most viewed"
    }, {
        "id": "month",
        "label": "This month",
        "icon": "trending_up",
        "group": "Most viewed"
    }, {
        "id": "year",
        "label": "This year",
        "icon": "trending_up",
        "group": "Most viewed"
    }, {
        "id": "rated",
        "label": "Top rated · all time",
        "icon": "star",
        "group": "Top rated"
    }, {
        "id": "rated_week",
        "label": "This week",
        "icon": "star",
        "group": "Top rated"
    }, {
        "id": "rated_month",
        "label": "This month",
        "icon": "star",
        "group": "Top rated"
    }]
    /// One of the site's categories, or empty for everything.
    property string category: ""
    property string searchText: ""
    /// The row being watched, and what the daemon resolved it to.
    property var watching: null
    property var qualities: []
    property int quality: 0
    property bool resolving: false
    property string watchError: ""
    readonly property var feedRef: feed
    readonly property var rows: feed.rows
    readonly property bool loading: feed.loading
    readonly property string errorText: feed.error
    readonly property string skippedText: feed.skipped
    /*
     * THE SITE'S OWN CATEGORIES, FROM THE SITE'S OWN MANIFEST.
     *
     * `sources/pornhub.toml` lists them as sections and the daemon hands them
     * over with everything else it knows about a source, so there is no second
     * list here to drift out of date: adding a category to the manifest puts it
     * in this rail.
     */
    readonly property var categories: {
        // The site's own list when it has answered, the manifest's copy until
        // then — the API has hundreds and the manifest has the three dozen
        // worth shipping, so this fills out rather than starting empty.
        if (root.apiCategories.length > 0)
            return root.apiCategories;

        const out = [];
        for (const section of (Catalog.facetSections || [])) if (section && section.source === "pornhub" && section.group === "Categories") {
            out.push(String(section.label || ""));
        }
        return out.filter((label) => {
            return label.length > 0;
        });
    }
    /*
     * THE LEFT-HAND SIDE OF THE SITE, WHICH IS NOT JUST CATEGORIES.
     *
     * Pornhub's own navigation is categories AND performers, and the webmasters
     * API publishes both: `/categories` with ids, `/stars` with every performer
     * it knows. Fetched through the daemon (the host 403s on back-to-back
     * requests), kept for the session, and used for the rail, the menus and the
     * performer screen.
     */
    property var apiCategories: []
    /// [{ name, thumb, videos, gender }] — the site publishes a picture and a
    /// video count for every performer, which is what its own menu shows and
    /// what makes a list of 23,000 names usable at all.
    property var stars: []
    property bool starsLoading: false
    property string starFilter: ""
    /// "" · "female" · "male" · "trans": the site's own split, as far as its
    /// API expresses it.
    property string starGender: ""
    readonly property var starsShown: {
        const needle = root.starFilter.trim().toLowerCase();
        const gender = root.starGender;
        const out = [];
        for (const star of root.stars) {
            if (gender.length > 0 && String(star.gender || "") !== gender)
                continue;

            if (needle.length > 0 && String(star.name || "").toLowerCase().indexOf(needle) < 0)
                continue;

            out.push(star);
            if (out.length >= 300)
                break;

        }
        return out;
    }
    /*
     * THE ORIENTATIONS THE SITE PUTS ABOVE ITS CATEGORIES.
     *
     * Its own menu opens with Straight / Gay / Transgender / Sapphic, and its
     * search has no parameter for any of them — the site expresses them as
     * categories. So that is what they are here: a word that goes into the
     * search, sitting above the rest because it is the first choice the site
     * asks you to make.
     */
    readonly property var orientations: [{
        "id": "",
        "label": "Straight",
        "icon": "favorite"
    }, {
        "id": "gay",
        "label": "Gay",
        "icon": "male"
    }, {
        "id": "transgender",
        "label": "Transgender",
        "icon": "transgender"
    }, {
        "id": "lesbian",
        "label": "Sapphic",
        "icon": "female"
    }]
    property string orientation: ""
    /*
     * HOW MANY VIDEOS ARE IN EACH CATEGORY — ASKED OF THE PAGE, NOT THE API.
     *
     * The webmasters API publishes a name and an id and nothing else, so the
     * categories screen showed 243 words with no sense of which of them is
     * the whole site and which is a corner of it. The site's own menu shows a
     * count under every one; it draws them with JavaScript, which is why no
     * amount of fetching the HTML ever found them.
     *
     * quarry ships a browser engine now, so the page is asked directly — one
     * headless load, once per session, and nothing on screen waits for it:
     * the names are already there and the numbers arrive underneath them.
     */
    property var categoryCounts: ({
    })
    property bool countsLoading: false
    property int countsRevision: 0
    property Process _counter
    property var covers: ({
    })
    property var _coverAsked: ({
    })
    property int _coversInFlight: 0
    property var _coverQueue: []
    /// The filters the site lists under its performers — plain search words,
    /// which is all they are on its side too.
    readonly property var popularFilters: ["fake tits", "natural tits", "small tits", "huge tits", "red heads", "blondes", "brunettes", "piercings", "tattooed", "asian", "arab", "latin", "black", "indian", "white", "18+ teens", "milfs", "mature"]
    /// Where you are, in words: "Most viewed · anal", "Featured".
    readonly property string placeLabel: {
        const bits = [feed.modeLabel[root.mode] || root.mode];
        if (root.searchText.length > 0)
            bits.push(`“${root.searchText}”`);
        else if (root.category.length > 0)
            bits.push(root.category);
        return bits.join(" · ");
    }
    /*
     * WATCH IT IN A WINDOW OF ITS OWN.
     *
     * The lens fills the app's content area, which is the right size for
     * choosing and the wrong size for watching. The app already has a window
     * for media — the viewer's own — so a video can simply open there, on a
     * second screen if that is where you put it, while the grid stays where it
     * was. The choice is remembered in the lens's own settings, so it is made
     * once rather than every time.
     */
    readonly property bool ownWindow: root.settings && root.settings.ownWindow === true
    /*
     * WHAT THE VIDEO'S OWN PAGE SAYS.
     *
     * A catalogue row is a poster, a title and a link — it cannot carry who is
     * in it, what it is filed under, how many people have watched it. The
     * webmasters API answers all of that for one id, so opening a video asks,
     * and the watch screen has performers you can press, categories you can
     * open, and the numbers the site shows under its own player.
     */
    property var detail: null
    property bool detailLoading: false
    readonly property var detailStars: {
        const rows = root.detail && root.detail.pornstars ? root.detail.pornstars : [];
        return rows.map((row) => {
            return String(row.pornstar_name || row.pornstar || "");
        }).filter((name) => {
            return name.length > 0;
        });
    }
    readonly property var detailCategories: {
        const rows = root.detail && root.detail.categories ? root.detail.categories : [];
        return rows.map((row) => {
            return String(row.category || "");
        }).filter((name) => {
            return name.length > 0;
        });
    }
    readonly property var detailTags: {
        const rows = root.detail && root.detail.tags ? root.detail.tags : [];
        return rows.map((row) => {
            return String(row.tag_name || "");
        }).filter((name) => {
            return name.length > 0 && !/^\d+$/.test(name);
        });
    }
    /*
     * WHAT THE PLAYER IS ACTUALLY GIVEN — AND IT IS NOT THE SITE'S URL.
     *
     * The qualities resolve to token-signed HLS playlists on phncdn, and every
     * segment of one needs the page's Referer, which a media player cannot
     * send: point QtMultimedia straight at them and you get a black rectangle,
     * a timeline stuck at 0:00, and no error — which is exactly what this
     * looked like. The daemon has ffmpeg and the headers, so the url goes to it
     * and it hands back a local one to play. Identical to what the app's own
     * viewer does with these sites.
     */
    property string streamUrl: ""
    property string streamError: ""
    readonly property string chosenUrl: root.qualities.length > 0 && root.quality < root.qualities.length ? String(root.qualities[root.quality].url || "") : ""
    readonly property string playingUrl: root.streamUrl
    property Feed _feed

    function modeLabel(id) {
        for (const mode of root.modes) if (mode.id === id) {
            return mode.group.length > 0 ? `${mode.group} · ${mode.label.replace(/^This /, "this ")}` : mode.label;
        }
        return id;
    }

    function chooseOrientation(id) {
        root.orientation = id || "";
        feed.reset(root.mode, root.category, root.searchText);
    }

    /// The site's own count for a category, or 0 when it has not answered.
    function countFor(name) {
        root.countsRevision;
        const n = root.categoryCounts[String(name || "")];
        return n === undefined ? 0 : n;
    }

    /*
     * quarryd came back — see `reconnected` on Lens. Everything this lens
     * shows was fetched through the daemon, so a connection that returns means
     * the empty screen behind the message can now be filled.
     */
    onReconnected: {
        root.loadLists();
        root.loadCounts();
        /*
         * From the START, not from where the feed thinks it got to.
         *
         * A feed that failed to load still advanced its page counter, so
         * asking for "more" after a reconnect asked for page 14 of a feed with
         * nothing in it — measured: `more · hasMore true page 13` with 0 rows.
         * Nothing to continue from means begin again.
         */
        if (root.rows.length === 0)
            feed.reset(root.mode, root.category, root.searchText);

    }

    function loadCounts() {
        if (root.countsLoading || Object.keys(root.categoryCounts).length > 0)
            return ;

        root.countsLoading = true;
        counter.command = ["quarry-browser", "--dump", "https://www.pornhub.com/categories", "--js", `${root.lensDir}/web/category-counts.js`, "--settle", "4000", "--timeout", "60000"];
        counter.running = true;
    }

    function loadLists() {
        if (root.apiCategories.length === 0)
            Client.call("pornhub", {
            "path": "categories"
        }, function(err, payload) {
            if (err || !payload || !payload.json)
                return ;

            // the manifest's list is already showing
            const rows = payload.json.categories || [];
            root.apiCategories = rows.map((row) => {
                return String(row.category || "");
            }).filter((name) => {
                return name.length > 0;
            });
        }, 30000);

        if (root.stars.length === 0 && !root.starsLoading) {
            root.starsLoading = true;
            // `stars_detailed` rather than `stars`: the same list, plus the
            // picture, the video count and the gender. A name on its own is a
            // row nobody can choose from.
            Client.call("pornhub", {
                "path": "stars_detailed"
            }, function(err, payload) {
                root.starsLoading = false;
                if (err || !payload || !payload.json)
                    return ;

                const rows = payload.json.stars || [];
                const out = [];
                for (const row of rows) {
                    const star = row.star || row;
                    const name = String(star.star_name || "").trim().replace(/^,\s*/, "");
                    if (name.length === 0)
                        continue;

                    out.push({
                        "name": name,
                        "thumb": String(star.star_thumb || ""),
                        "videos": Number(star.videos_count_all || 0),
                        "gender": String(star.gender || ""),
                        "page": String(star.star_url || "")
                    });
                }
                // Busiest first: the site's own menu is ordered by who people
                // actually look for, and alphabetical starts with a screenful
                // of names that are just numbers.
                out.sort((a, b) => {
                    return b.videos - a.videos;
                });
                root.stars = out;
            }, 45000);
        }
    }

    /// A performer is a search for their name — the API has no per-star feed,
    /// and their name is how the site's own search finds them anyway.
    function openStar(name) {
        const who = typeof name === "string" ? name : (name && name.name ? name.name : "");
        if (!who || who.length === 0)
            return ;

        name = who;
        root.screen = "browse";
        root.category = "";
        root.searchText = String(name);
        feed.reset(root.mode, "", root.searchText);
    }

    /*
     * The cover this word already has, or "" — A PURE READ.
     *
     * It used to queue the fetch itself, which read well and was wrong: the skin
     * calls this from an Image's `source` binding, so the binding had a side
     * effect and QML reported a binding loop on every category cell. Asking is
     * `requestCover`, and the skin calls it when a cell appears — which is where
     * "this card is on screen" is actually known.
     */
    function coverFor(category) {
        const key = String(category || "");
        if (key.length === 0)
            return "";

        const held = root.covers[key];
        return held === undefined ? "" : held;
    }

    /// Fetch this word's cover once, if it has not been asked for already.
    function requestCover(category) {
        const key = String(category || "");
        if (key.length === 0 || root.covers[key] !== undefined || root._coverAsked[key])
            return ;

        root._coverAsked[key] = true;
        root._coverQueue.push(key);
        root._pumpCovers();
    }

    function _pumpCovers() {
        if (root._coversInFlight >= 2 || root._coverQueue.length === 0 || !Client.connected)
            return ;

        const key = root._coverQueue.shift();
        root._coversInFlight++;
        Client.call("search", {
            "source": "pornhub",
            "q": key,
            "page": 1
        }, function(err, payload) {
            root._coversInFlight--;
            const rows = (payload && payload.items) || [];
            const covers = Object.assign({
            }, root.covers);
            // "" is remembered too: a category the site has nothing for must
            // not be asked again on every scroll past it.
            covers[key] = rows.length > 0 ? String(rows[0].thumb_local ? "file://" + rows[0].thumb_local : rows[0].url || "") : "";
            root.covers = covers;
            root._pumpCovers();
        }, 30000);
    }

    function showCategories() {
        root.stopWatching();
        root.screen = "categories";
        root.loadCounts();
        root.loadLists();
    }

    function showStars() {
        root.stopWatching();
        root.screen = "stars";
        root.loadLists();
    }

    // ── browsing ─────────────────────────────────────────────────────────────
    function chooseMode(mode) {
        root.stopWatching();
        root.mode = mode;
        feed.reset(root.mode, root.category, root.searchText);
    }

    function chooseCategory(name) {
        root.stopWatching();
        root.category = name || "";
        // A category is a place, not a filter on the words you typed: opening
        // one from a search would otherwise hand you the intersection of two
        // things you did not ask to combine.
        root.searchText = "";
        feed.reset(root.mode, root.category, root.searchText);
    }

    /// The site's own search. Runs inside the open category, if there is one.
    function search(text) {
        root.stopWatching();
        root.searchText = (text || "").trim();
        feed.reset(root.mode, root.category, root.searchText);
        if (root.searchText.length > 1)
            Catalog.remember("search", root.searchText, "");

    }

    function loadMore() {
        feed.more();
    }

    /// Another handful of the same thing, from somewhere else in the feed.
    function shuffle() {
        root.stopWatching();
        feed.shuffle();
    }

    function watch(item) {
        if (!item)
            return ;

        // The setting is what decides where it opens, every time, without a
        // second button to remember to press.
        if (root.ownWindow) {
            root.openInWindow(item);
            return ;
        }
        root.watching = item;
        root.screen = "watch";
        root.qualities = [];
        root.quality = 0;
        root.watchError = "";
        root.resolving = true;
        const asked = item.id;
        feed.renditions(item, function(list, error) {
            if (!root.watching || root.watching.id !== asked)
                return ;

            // opened something else while this resolved
            root.resolving = false;
            root.qualities = list;
            root.watchError = error;
            root.quality = 0;
            root._resolveStream();
        });
        Catalog.remember("open", item.title || "", item.id);
        root.loadDetail(item);
    }

    function setOwnWindow(on) {
        root.saveSettings(Object.assign({
        }, root.settings, {
            "ownWindow": on === true
        }));
    }

    function openInWindow(item) {
        const row = item || root.watching;
        if (!row) {
            Toast.error("Open one first");
            return ;
        }
        if (!Shell.mediaWindow) {
            Toast.error("The media window is not up yet");
            return ;
        }
        // The row is in the catalogue — `search` filed it — so the app's own
        // viewer can play it with everything it brings: the scrubber, the
        // frame grab, the quality menu, the keyboard.
        Shell.mediaWindow.showAt(-1, row);
        Catalog.remember("open", row.title || "", row.id);
    }

    /// The nth row of what is on screen — what a keyboard or a terminal can
    /// reach, where a skin has a poster to click.
    function watchAt(index) {
        const at = Number(index);
        if (!(at >= 0) || at >= root.rows.length)
            return ;

        root.watch(root.rows[at]);
    }

    function loadDetail(item) {
        root.detail = null;
        if (!item || !Client.connected)
            return ;

        const id = String(item.id || "").replace(/^pornhub:/, "");
        const site = String(item.page_url || item.url || "").match(/viewkey=([A-Za-z0-9]+)/);
        const viewkey = site ? site[1] : id;
        if (viewkey.length === 0)
            return ;

        root.detailLoading = true;
        const asked = item.id;
        Client.call("pornhub", {
            "path": `video_by_id?id=${encodeURIComponent(viewkey)}`
        }, function(err, payload) {
            root.detailLoading = false;
            if (!root.watching || root.watching.id !== asked)
                return ;

            if (err || !payload || !payload.json || !payload.json.video)
                return ;

            // not fatal: the player is the point
            root.detail = payload.json.video;
        }, 30000);
    }

    function chooseQuality(index) {
        if (index >= 0 && index < root.qualities.length)
            root.quality = index;

    }

    function _resolveStream() {
        root.streamUrl = "";
        root.streamError = "";
        const url = root.chosenUrl;
        if (url.length === 0 || !root.watching)
            return ;

        if (!Client.connected) {
            root.streamError = "Can't reach quarryd — it is what fetches the video";
            return ;
        }
        const asked = root.watching.id;
        const wanted = url;
        Client.call("stream", {
            "id": asked,
            "url": url,
            "pageUrl": root.pageUrl(root.watching)
        }, function(err, payload) {
            if (!root.watching || root.watching.id !== asked || root.chosenUrl !== wanted)
                return ;

            // moved on while the daemon was thinking
            if (err || !payload || !payload.url) {
                root.streamError = String(err || "the daemon could not open that file");
                return ;
            }
            root.streamUrl = String(payload.url);
        });
    }

    function stopWatching() {
        if (root.screen !== "watch")
            return ;

        root.screen = "browse";
        root.watching = null;
        root.streamUrl = "";
        root.streamError = "";
        root.qualities = [];
        root.watchError = "";
        root.resolving = false;
    }

    /// What follows this one in the feed — the "up next" strip reads it, and so
    /// does the skip button, so both agree about what "next" means.
    function neighbours(count) {
        const out = [];
        if (!root.watching)
            return out;

        const list = root.rows;
        let at = -1;
        for (let i = 0; i < list.length; i++) if (list[i].id === root.watching.id) {
            at = i;
            break;
        }
        if (at < 0)
            return out;

        for (let i = at + 1; i < list.length && out.length < (count || 12); i++) out.push(list[i])
        // Running low on what comes next is the moment to ask for more, not
        // when the strip has already run out under the pointer.
        if (out.length < (count || 12))
            root.loadMore();

        return out;
    }

    /// Step through the feed without going back to it.
    function watchNeighbour(step) {
        if (!root.watching)
            return ;

        const list = root.rows;
        for (let i = 0; i < list.length; i++) {
            if (list[i].id !== root.watching.id)
                continue;

            const next = i + step;
            if (next < 0 || next >= list.length) {
                if (step > 0)
                    root.loadMore();

                return ;
            }
            root.watch(list[next]);
            return ;
        }
    }

    /// The page this row came from, for "open on the site".
    function pageUrl(item) {
        return item ? String(item.page_url || item.url || "") : "";
    }

    /// "browse" · "watch" · "stars"
    //
    //     * THE FOUR SHAPES, FROM THE BASE TYPE.
    //     *
    //     * The feed was a fixed 300px grid. The app's layout button means "how is
    //     * this laid out" everywhere else in quarry, so it means it here: naming
    //     * the shapes is all a lens has to do — Lens owns the choosing, the
    //     * memory and the setter.
    //
    layouts: root.pictureLayouts
    layoutContext: "pornhub"
    screenTitle: root.screen === "watch" && root.watching ? (root.watching.title || "Video") : root.placeLabel
    /*
     * WHERE YOU ARE, ON THE SITE ITSELF.
     *
     * The API carries the video and nothing around it — no comments, no
     * pornstar page, no playlist. So the lens keeps a URL for wherever you are
     * standing, and "Open the real site here" lands on the same video, the same
     * category, the same search, in the app's own browser.
     */
    siteUrl: {
        if (root.screen === "watch" && root.watching) {
            const page = root.pageUrl(root.watching);
            if (page.length > 0)
                return page;

        }
        const words = [root.category, root.searchText].filter((part) => {
            return part && part.length > 0;
        }).join(" ");
        if (words.length > 0)
            return `https://www.pornhub.com/video/search?search=${encodeURIComponent(words)}`;

        return root.mode === "new" ? "https://www.pornhub.com/video?o=cm" : root.mode === "views" ? "https://www.pornhub.com/video?o=mv" : "https://www.pornhub.com/video";
    }
    navItems: {
        const items = [];
        if (root.screen === "watch" && root.watching)
            items.push({
            "id": "__watch",
            "label": root.watching.title || "Video",
            "sublabel": "Watching",
            "icon": "play_circle",
            "active": true
        });

        for (const mode of ["featured", "new", "views"]) items.push({
            "id": `sort:${mode}`,
            "label": feed.modeLabel[mode] || mode,
            "icon": mode === "new" ? "schedule" : mode === "views" ? "trending_up" : "local_fire_department",
            "active": root.screen === "browse" && root.mode === mode && root.category.length === 0
        })
        items.push({
            "id": "categories",
            "label": "Categories",
            "icon": "grid_view",
            "sublabel": root.categories.length > 0 ? `${root.categories.length} of them` : "",
            "active": root.screen === "categories"
        });
        items.push({
            "id": "stars",
            "label": "Pornstars",
            "icon": "person_search",
            "sublabel": root.stars.length > 0 ? `${root.stars.length} known` : "",
            "active": root.screen === "stars"
        });
        items.push({
            "id": "cat:",
            "label": "Everything",
            "icon": "apps",
            "active": false,
            "sublabel": root.categories.length > 0 ? `${root.categories.length} categories` : ""
        });
        for (const name of root.categories) items.push({
            "id": `cat:${name}`,
            "label": name,
            "icon": "label",
            "active": root.screen === "browse" && root.category === name
        })
        return items;
    }
    onNavPicked: (id) => {
        if (id === "__watch")
            return ;

        if (id === "stars") {
            root.showStars();
            return ;
        }
        if (id === "categories") {
            root.showCategories();
            return ;
        }
        if (id.indexOf("sort:") === 0) {
            root.chooseMode(id.slice(5));
            return ;
        }
        if (id.indexOf("cat:") === 0)
            root.chooseCategory(id.slice(4));

    }
    canGoBack: root.screen !== "browse" || root.category.length > 0 || root.searchText.length > 0
    onBackRequested: {
        if (root.screen === "watch") {
            root.stopWatching();
            return ;
        }
        if (root.searchText.length > 0) {
            root.search("");
            return ;
        }
        root.chooseCategory("");
    }
    onChosenUrlChanged: root._resolveStream()
    // ── the header's overflow ────────────────────────────────────────────────
    menuItems: [{
        "label": "Watch in its own window",
        "icon": "open_in_new",
        "hint": root.ownWindow ? "on" : "off",
        "checked": root.ownWindow,
        "action": () => {
            root.setOwnWindow(!root.ownWindow);
            if (root.ownWindow && root.watching)
                root.openInWindow(root.watching);

        }
    }, {
        "label": "Show me different ones",
        "icon": "shuffle",
        "hint": "same ordering, elsewhere in it",
        "action": () => {
            return root.shuffle();
        }
    }, {
        "label": "Open on the site",
        "icon": "open_in_new",
        "hint": "pornhub.com",
        "action": () => {
            const url = root.pageUrl(root.watching || (root.rows.length > 0 ? root.rows[0] : null));
            if (url.length > 0)
                Sys.open(url);
            else
                Toast.error("No page to open");
        }
    }, {
        "label": "Copy the link",
        "icon": "link",
        "action": () => {
            const url = root.pageUrl(root.watching);
            if (url.length === 0) {
                Toast.error("No link to copy");
                return ;
            }
            Sys.copyText(url, (ok) => {
                return ok ? Toast.show("Link copied") : Toast.error("Could not copy — " + Sys.lastError);
            });
        }
    }, {
        "label": "Keep this one",
        "icon": "bookmark_add",
        "hint": "into a collection",
        "action": () => {
            if (!root.watching) {
                Toast.error("Open one first");
                return ;
            }
            // The row is already in the catalogue — `search` filed it on the
            // way past — so this adds a membership rather than a copy.
            Catalog.keep(root.watching, "keepers", true);
            Toast.show(`Kept · ${root.watching.title || "video"}`);
        }
    }]
    onOpened: {
        // The categories come from the daemon's answer about its sources; ask
        // for it if nothing has yet, or the rail opens empty on a cold start.
        if ((Catalog.facetSections || []).length === 0)
            Catalog.refreshFacets();

        root.loadLists();
        feed.reset(root.mode, root.category, root.searchText);
    }
    onClosedDown: root.stopWatching()

    _counter: Process {
        id: counter

        onExited: (code, status) => {
            root.countsLoading = false;
        }

        stdout: StdioCollector {
            onStreamFinished: {
                root.countsLoading = false;
                const text = String(this.text || "").trim();
                if (text.length === 0)
                    return ;

                try {
                    const rows = JSON.parse(text);
                    const next = {
                    };
                    for (const row of rows) next[String(row.name)] = Number(row.videos || 0)
                    root.categoryCounts = next;
                    root.countsRevision++;
                } catch (e) {
                }
            }
        }

    }

    _feed: Feed {
        id: feed

        mode: root.mode
        category: root.category
        orientation: root.orientation
    }

}
