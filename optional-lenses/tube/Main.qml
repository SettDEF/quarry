import QtQuick
import qs.modules.lens
import qs.services

/*
 * THE TUBE LENS — three video sites as themselves, not as a wall of rows.
 *
 * Each site keeps its own place: which ordering you were reading, what you
 * searched for, how far down you had got. Switching sites is switching places,
 * not reloading one feed with a different filter — that is the whole reason
 * this is a lens rather than three `source:` chips in the gallery.
 *
 * Everything goes through quarryd (see Feed.qml): the site's real search, its
 * real orderings, real qualities from `renditions`. Nothing is scraped here,
 * and nothing is guessed — a site that cannot answer something says so in the
 * daemon's own words.
 *
 * This file is the STATE. The skins under skins/ read it and draw; neither of
 * them owns anything that must survive, which is what lets you change skin
 * mid-video and land on the same one.
 */
Lens {
    id: root

    property string screen: "browse"
    property string site: "pornhub"
    property string mode: "featured"
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
     * WHERE YOU WERE ON EACH SITE.
     *
     * Kept per site, so going to EPORNER and back does not lose the search you
     * had typed on Pornhub. Only the small things — the feed itself is refetched,
     * because a front page you left ten minutes ago is not the front page.
     */
    property var _places: ({
    })
    /*
     * THE FILE THE SOURCE NAMED — which is not the one to hand a player.
     *
     * These are signed, short-lived URLs on someone else's CDN, and most of
     * them only answer a request carrying the right Referer. Qt's player sends
     * none, so handing it this directly gets a black rectangle and no error:
     * the pornhub lens learned that and routes through quarryd, and this one
     * was still playing the raw URL. HLS is worse again — a master playlist is
     * a list of more URLs, each needing the same treatment, which only the
     * proxy can rewrite.
     */
    readonly property string chosenUrl: root.qualities.length > 0 && root.quality < root.qualities.length ? String(root.qualities[root.quality].url || "") : ""
    /// What the player is actually given: quarryd's local proxy for the above.
    property string streamUrl: ""
    property string streamError: ""
    readonly property string playingUrl: root.streamUrl

    onChosenUrlChanged: root._resolveStream()

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
            /*
             * The page it came from, which is what the proxy sends as the
             * Referer. Most of these CDNs serve nothing without it, and a lens
             * row is usually NOT in the catalogue — so the daemon has no other
             * way to know where the file was found. The pornhub lens passes it;
             * leaving it out here is the difference between a video and a
             * black rectangle.
             */
            "pageUrl": root.pageUrl(root.watching)
        }, function(err, payload) {
            // Moved on while the daemon was thinking.
            if (!root.watching || root.watching.id !== asked || root.chosenUrl !== wanted)
                return ;

            if (err || !payload || !payload.url) {
                root.streamError = String(err || "the daemon could not open that file");
                return ;
            }
            root.streamUrl = String(payload.url);
        });
    }
    property Feed _feed

    _feed: Feed {
        id: feed

        site: root.site
        mode: root.mode
    }

    function _remember() {
        const places = {
        };
        for (const key in root._places) places[key] = root._places[key]
        places[root.site] = {
            "mode": root.mode,
            "text": root.searchText
        };
        root._places = places;
    }

    // ── what the feed is showing ─────────────────────────────────────────────
    function chooseSite(id) {
        if (id === root.site && root.screen === "browse")
            return ;

        root._remember();
        root.stopWatching();
        root.site = id;
        // Back to where you were on this site, or its front page.
        const place = root._places[id] || {
        };
        root.mode = place.mode || "featured";
        root.searchText = place.text || "";
        feed.reset(root.site, root.mode, root.searchText);
    }

    function chooseMode(mode) {
        root.stopWatching();
        if (mode === root.mode && root.screen === "browse")
            return ;

        root.mode = mode;
        feed.reset(root.site, root.mode, root.searchText);
    }

    /// The site's own search. Empty text goes back to the ordering you were on.
    function search(text) {
        root.stopWatching();
        root.searchText = (text || "").trim();
        feed.reset(root.site, root.mode, root.searchText);
        if (root.searchText.length > 1)
            Catalog.remember("search", root.searchText, "");

    }

    // See `reconnected` on Lens: the feed is fetched through quarryd, so a
    // connection that returns is the moment to ask again.
    onReconnected: {
        if (root.rows.length === 0)
            root.loadMore();

    }

    function loadMore() {
        feed.more();
    }

    // ── one video ────────────────────────────────────────────────────────────
    //
    //     * Opening a row asks the daemon what it actually plays.
    //     *
    //     * The row IS a poster — these sites publish the still and keep the stream
    //     * on the page — so there is nothing to play until `renditions` has resolved
    //     * it. The highest quality is chosen, because that is what a player with a
    //     * quality list is for, and the rest stay pickable.
    //
    function watch(item) {
        if (!item)
            return ;

        root.watching = item;
        root.screen = "watch";
        root.qualities = [];
        root.quality = 0;
        root.watchError = "";
        root.streamUrl = "";
        root.streamError = "";
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
        });
        Catalog.remember("open", item.title || "", item.id);
    }

    function chooseQuality(index) {
        if (index >= 0 && index < root.qualities.length)
            root.quality = index;

    }

    function stopWatching() {
        if (root.screen !== "watch")
            return ;

        root.screen = "browse";
        root.watching = null;
        root.qualities = [];
        root.watchError = "";
        root.streamUrl = "";
        root.streamError = "";
        root.resolving = false;
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
                // Running off the end asks for more rather than stopping.
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

    screenTitle: root.screen === "watch" && root.watching ? (root.watching.title || "Video") : `${feed.siteLabel(root.site)} · ${feed.modeLabel[root.mode] || root.mode}`
    /// The page on the real site for wherever you are — the host offers it as
    /// "Open the real site here" for every lens that knows one.
    siteUrl: {
        if (root.screen === "watch" && root.watching) {
            const page = root.pageUrl(root.watching);
            if (page.length > 0)
                return page;

        }
        return root.site === "eporner" ? "https://www.eporner.com/" : root.site === "redtube" ? "https://www.redtube.com/" : "https://www.pornhub.com/video";
    }
    /// "browse" · "watch"
    //
    //     * THE FOUR SHAPES, FROM THE BASE TYPE.
    //     *
    //     * The feed was a fixed 300px grid. The app's layout button means "how is
    //     * this laid out" everywhere else in quarry, so it means it here: naming
    //     * the shapes is all a lens has to do — Lens owns the choosing, the
    //     * memory and the setter.
    //
    layouts: root.pictureLayouts
    layoutContext: "tube"
    // ── navigation ───────────────────────────────────────────────────────────
    //
    //     * The rail becomes this lens's own while it is open: the sites, then the
    //     * orderings inside the one you are on. A site you are not on does not show
    //     * its orderings — five rows you cannot act on is not navigation.
    //
    navItems: {
        const rows = [];
        if (root.screen === "watch" && root.watching)
            rows.push({
                "id": "__watch",
                "label": root.watching.title || "Video",
                "sublabel": feed.siteLabel(root.site),
                "icon": "play_circle",
                "active": true
            });

        for (const site of feed.sites) {
            const here = site.id === root.site;
            rows.push({
                "id": "site:" + site.id,
                "label": site.label,
                "sublabel": here ? (root.searchText.length > 0 ? `“${root.searchText}”` : "browsing") : "",
                "icon": "smart_display",
                "count": here && root.rows.length > 0 ? String(root.rows.length) : "",
                "active": here && root.screen === "browse"
            });
            if (!here)
                continue;

            for (const mode of site.modes) rows.push({
                "id": "mode:" + mode,
                "label": feed.modeLabel[mode] || mode,
                "icon": mode === "new" ? "schedule" : mode === "views" ? "trending_up" : "star",
                "indent": true,
                "active": root.screen === "browse" && root.mode === mode
            })
        }
        return rows;
    }
    onNavPicked: (id) => {
        if (id === "__watch")
            return ;

        if (id.indexOf("site:") === 0) {
            root.chooseSite(id.slice(5));
            return ;
        }
        if (id.indexOf("mode:") === 0)
            root.chooseMode(id.slice(5));

    }
    onBackRequested: {
        if (root.screen === "watch") {
            root.stopWatching();
            return ;
        }
        // A search is somewhere you went; clearing it is a step back.
        if (root.searchText.length > 0)
            root.search("");

    }
    canGoBack: root.screen === "watch" || root.searchText.length > 0
    // ── the header's overflow ────────────────────────────────────────────────
    menuItems: [{
        "label": "Open on the site",
        "icon": "open_in_new",
        "hint": feed.siteLabel(root.site),
        "action": () => {
            const url = root.pageUrl(root.watching);
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
    }]
    onOpened: {
        const place = root._places[root.site] || {
        };
        root.mode = place.mode || root.mode;
        feed.reset(root.site, root.mode, root.searchText);
    }
    onClosedDown: {
        root._remember();
        root.stopWatching();
    }
}
