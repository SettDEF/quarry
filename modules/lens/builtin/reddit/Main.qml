import QtQuick
import qs.modules.common
import qs.modules.lens
import qs.services
import "thread.js" as Thread

/*
 * THE REDDIT LENS — the half a picture engine cannot show you.
 *
 * quarry already fetches reddit as a SOURCE: rows of pictures, filed in the
 * catalogue, sorted next to everything else. What a row can never carry is the
 * thing people actually go to reddit for — what was said underneath. So this
 * lens is a reader: communities, their listings in the site's own orderings,
 * and a post with its comment tree, threaded and collapsible, with truncated
 * chains fetched on demand.
 *
 * Read-only, through quarryd (see Api.qml). Not account-free, because reddit
 * has not been since 2024: every unauthenticated path answers 403, so the
 * daemon signs these requests with the app credential it already keeps for the
 * reddit SOURCE, and this lens never sees it. Nothing here posts, votes or
 * subscribes — a reader that can act on your behalf is a different program with
 * different consequences.
 *
 * This file is the STATE. The skins draw it and hold nothing that must survive.
 */
Lens {
    // ── what is loaded ───────────────────────────────────────────────────────
    //     * THE SAME FOUR LAYOUTS THE GALLERY HAS.
    //     *
    //     * A subreddit is two things at once: a conversation, which wants a column
    //     * of cards, and a pile of pictures, which wants a wall. The column was the
    //     * only option, so r/wallpapers — 195 pictures a page now that galleries
    //     * are read — was a scroll of one-at-a-time.
    //     *
    //     * Ids, labels and icons are the gallery's own, deliberately: a person who
    //     * has learned what "Contact sheet" means in quarry must not have to learn
    //     * a second vocabulary inside a lens. Same decision as Morse's media wall.
    // ── the header's overflow ────────────────────────────────────────────────
    //     * THE LAYOUT SWITCHER LIVES IN THE MENU.
    //     *
    //     * Not a row of icons in the header: the header is already carrying a back
    //     * button, a title, a "go to r/…" field and the site link, and a fifth
    //     * control there would be the one that gets pressed by accident. The menu
    //     * is where quarry keeps its per-screen choices everywhere else.
    // ── navigation ───────────────────────────────────────────────────────────
    /// The communities a reader without an account has: a few that everybody
    /// knows, plus whatever they have been to. Kept in the lens's own settings,
    /// which the registry persists.
    //     * THE SUBREDDITS ARE YOURS TO CHOOSE.
    //     *
    //     * This used to be a visit history with seven hardcoded names welded on:
    //     * everywhere you went appeared in the rail whether or not you wanted it
    //     * there, and r/earthporn could not be removed however little you cared
    //     * about it. A list you cannot edit is not your list.
    //     *
    //     * Now: `settings.subs` is what YOU pinned, in your order, and the seven
    //     * are only a starting point for somebody who has never pinned anything.
    //     * `subsChosen` is the flag that tells those apart — without it, "I removed
    //     * them all" and "I have not started" look identical and the defaults come
    //     * back every launch.
    // The community's own icon where it has one — see `fetchIcon`.

    id: root

    /// "communities" · "feed" · "post"
    property string screen: "feed"
    property string sub: "all"
    property string sort: "hot"
    property string commentSort: "confidence"
    /// the one video allowed sound (a RedditVideo token); "" = all muted
    property string soundToken: ""

    // ── autoscroll (skins/AutoScroll.qml) ──
    property bool autoscroll: false
    property real autoSpeed: 70               // px/s
    property double dwellUntil: 0             // a video in the middle holds it until then
    // opening a post (the media view) or the theater stops it
    onScreenChanged: if (root.screen !== "feed") root.autoscroll = false
    onLayoutChanged: if (root.layout === "theater") root.autoscroll = false

    // ── search: results replace the feed, so every layout draws them ──
    property string query: ""                 // "" = not searching
    property string searchSort: "relevance"   // relevance · top · new · comments
    property string searchTime: "all"         // hour · day · week · month · year · all
    property string searchSub: ""             // "" = all of reddit, else only this community
    property var foundSubs: []                // communities matching the query
    readonly property var searchSortLabel: ({ relevance: "Relevance", top: "Top", "new": "New", comments: "Most comments" })
    readonly property var searchTimeLabel: ({ hour: "Hour", day: "Today", week: "Week", month: "Month", year: "Year", all: "All time" })
    /// which feed a reply belongs to — a reply for an older one is dropped
    function feedKey() { return root.query.length > 0 ? `search:${root.query}:${root.searchSub}:${root.searchSort}:${root.searchTime}` : `${root.sub}/${root.sort}`; }

    /// Search posts (everywhere, or `here` in the community on screen) and the
    /// communities whose names match.
    function search(text, here) {
        const q = String(text || "").trim();
        if (q.length === 0) { root.clearSearch(); return; }
        root.closePost();
        root.query = q;
        root.searchSub = here && root.sub !== "all" && !root.isProfile() ? root.sub : "";
        root.screen = "feed";
        root.foundSubs = [];
        api.searchSubs(q, function(data, error) {
            if (root.query !== q) return;
            root.foundSubs = error ? [] : Thread.children(data).map((c) => c.data).filter((d) => !!d && !!d.display_name);
        });
        root.reload();
    }
    function chooseSearch(sort, time) {
        if (sort) root.searchSort = sort;
        if (time) root.searchTime = time;
        root.reload();
    }
    function clearSearch() {
        if (root.query.length === 0) return;
        root.query = ""; root.searchSub = ""; root.foundSubs = [];
        root.reload();
    }
    readonly property var sortLabel: ({
        "hot": "Hot",
        "new": "New",
        "top": "Top",
        "rising": "Rising"
    })
    readonly property var commentSortLabel: ({
        "confidence": "Best",
        "top": "Top",
        "new": "New",
        "controversial": "Controversial",
        "old": "Oldest"
    })
    readonly property bool showsWall: root.layout.length > 0 && root.layout !== "posts" && root.layout !== "cards" && root.layout !== "theater"
    property var posts: []
    /*
     * THE POSTS THAT ARE PICTURES.
     *
     * A wall of cards that say "no image" is not a wall. Reddit marks the
     * media itself — a gallery, a video, or a preview — so this asks the post
     * rather than guessing from the URL, which is the mistake the daemon's
     * parser made until today.
     */
    /*
     * THE ADULT SWITCH IS A PROMISE, AND A LENS HAS TO KEEP IT TOO.
     *
     * `over_18` was read here for one purpose: `Prefs.blurNsfw`, which draws a
     * blur over the thumbnail AND LIFTS IT ON HOVER. That is a content warning,
     * not a setting — with "show adult content" off, the posts were still
     * fetched, still listed, still counted, and one pointer movement away from
     * being shown in full.
     *
     * The catalogue has answered this properly since the daemon started
     * appending `nsfw:false` to every query (see catalog.rs), so quarry as a
     * whole made a promise that this lens quietly broke. Now the rows never
     * enter the model: nothing to blur, nothing to hover, nothing to count.
     *
     * Applied where the API's rows become posts and communities, so every view
     * downstream — the listing, `pictures`, a thread, the rail's counts —
     * inherits it rather than each having to remember.
     */
    function allowed(row) {
        if (Prefs.showNsfw)
            return true;

        // Reddit spells it `over_18` on a post and `over18` on a subreddit.
        return row.over_18 !== true && row.over18 !== true;
    }

    /*
     * Everything already fetched is dropped the moment the switch goes off, so
     * turning it off while looking at an adult listing clears the screen rather
     * than leaving what is on it until the next fetch.
     */
    property Connections _adultSwitch: Connections {
        target: Prefs

        function onShowNsfwChanged() {
            if (Prefs.showNsfw)
                return ;

            root.posts = root.posts.filter(root.allowed);
            root.communities = root.communities.filter(root.allowed);
            if (root.post && !root.allowed(root.post))
                root.closePost();

        }
    }

    readonly property var pictures: root.posts.filter((p) => {
        if (!p)
            return false;

        if (p.is_gallery && p.media_metadata)
            return true;

        if (p.preview && p.preview.images && p.preview.images.length > 0)
            return true;

        const url = String(p.url_overridden_by_dest || p.url || "");
        return /\.(jpe?g|png|webp|gif)(\?|$)/i.test(url);
    })
    property string after: ""
    property bool loading: false
    property bool hasMore: true
    property string errorText: ""
    property var communities: []
    property bool communitiesLoading: false
    /// The open post, its comment rows, and the two bits of state the tree
    /// needs: what has been collapsed, and what has been fetched for a stub.
    property var post: null
    property var commentRows: []
    property bool commentsLoading: false
    property string commentsError: ""
    property var collapsed: ({
    })
    property var loadedMore: ({
    })
    property var _threadPayload: null
    /// Which "more" stub is being fetched, so the row can say so.
    property string loadingStub: ""
    readonly property var defaultSubs: ["all", "popular", "pics", "wallpapers", "earthporn", "art"]
    readonly property var pinned: {
        if (root.settings && root.settings.subsChosen === true)
            return (root.settings.subs || []).map((s) => {
            return String(s);
        });

        return root.defaultSubs;
    }
    /*
     * WHERE YOU HAVE BEEN, KEPT APART FROM WHAT YOU CHOSE.
     *
     * Opening a subreddit should not silently add it to your list — but it
     * should be easy to get back to. So visits land here, five deep, below
     * your own list and clearly under their own heading.
     */
    readonly property var recent: {
        const seen = root.settings && root.settings.recent ? root.settings.recent : [];
        return seen.map((s) => {
            return String(s);
        }).filter((s) => {
            return root.pinned.indexOf(s) < 0;
        }).slice(0, 5);
    }
    /// Community icons, fetched once each and kept — a rail of identical tags
    /// is a rail you read instead of recognise. Same argument as Morse's
    /// chat photographs.
    property var subIcons: ({
    })
    /*
     * Take the picture into the catalogue, the way the 4chan lens does: fetch
     * it to a file, then hand the file to the daemon, which files it, hashes it
     * and makes it exportable like anything else quarry holds.
     */
    property int busyCount: 0
    property Api _api
    readonly property var layoutMenu: root.layouts.map((l) => {
        return ({
            "label": l.label,
            "icon": l.icon,
            "hint": l.hint,
            "checked": root.layout === l.id,
            "trigger": () => {
                return root.setLayout(l.id);
            }
        });
    })

    /*
     * ONE REQUEST PER SUBREDDIT, EVER.
     *
     * `about.json` carries the community's icon. Asked for once per name and
     * kept in the lens's settings, because the rail draws these on every
     * repaint and reddit's budget is one request a second for everything this
     * lens does — a rail that re-fetched would spend the whole allowance on
     * decoration.
     */
    function fetchIcon(name) {
        const id = String(name || "").toLowerCase();
        // "u/somebody" is a person: /r/u%2Fsomebody/about.json is a 404 and
        // then a permanently empty icon slot for a row that has an avatar.
        if (id.length === 0 || id === "all" || id === "popular" || id.indexOf("u/") === 0)
            return ;

        if (root.subIcons[id] !== undefined)
            return ;

        // Marked before the answer arrives, so twelve rail rows asking at once
        // make one request rather than twelve.
        const pending = Object.assign({
        }, root.subIcons);
        pending[id] = "";
        root.subIcons = pending;
        api.get(`/r/${id}/about.json`, function(data, error) {
            if (error || !data || !data.data)
                return ;

            const about = data.data;
            const raw = String(about.community_icon || about.icon_img || "");
            if (raw.length === 0)
                return ;

            const next = Object.assign({
            }, root.subIcons);
            // reddit escapes these in JSON, the same way it escapes previews.
            next[id] = raw.replace(/&amp;/g, "&");
            root.subIcons = next;
        });
    }

    /// The address of what is on screen, in the clipboard. The overflow row
    /// does this too; the post screen has a button for it now, because that is
    /// where anybody actually wants it.
    function copyLink() {
        Sys.copyText(root.siteUrl, (ok) => {
            return ok ? Toast.show("Link copied") : Toast.error("Could not copy — " + Sys.lastError);
        });
    }

    function isPinned(name) {
        return root.pinned.indexOf(String(name || "").toLowerCase()) >= 0;
    }

    function pinSub(name) {
        const id = String(name || "").toLowerCase().replace(/^\/?r\//, "").trim();
        if (id.length === 0)
            return ;

        const next = root.pinned.filter((s) => {
            return s !== id;
        });
        next.unshift(id);
        root._saveSubs(next);
        Toast.show(`r/${id} pinned`);
    }

    function unpinSub(name) {
        const id = String(name || "").toLowerCase();
        root._saveSubs(root.pinned.filter((s) => {
            return s !== id;
        }));
        Toast.show(`r/${id} removed from your list`);
    }

    function _saveSubs(list) {
        root.saveSettings(Object.assign({
        }, root.settings, {
            "subs": list.slice(0, 40),
            "subsChosen": true
        }));
    }

    /// Drop one name out of "Recently opened" without pinning or visiting it.
    function forget(sub) {
        const name = String(sub || "").toLowerCase();
        const seen = (root.settings && root.settings.recent ? root.settings.recent : []).filter((s) => {
            return s !== name;
        });
        root.saveSettings(Object.assign({
        }, root.settings, {
            "recent": seen
        }));
        Toast.show(`r/${name} forgotten`);
    }

    /*
     * THE RAIL'S RIGHT-CLICK, FOR THIS LENS.
     *
     * Only the community rows have anything to offer: pin or unpin, forget a
     * visit, open it on the site. Sorts and the browse links answer with
     * nothing, so right-clicking those does not pop an empty box.
     */
    function navMenu(id) {
        const key = String(id || "");
        if (key.indexOf("sub:") !== 0)
            return [];

        const name = key.slice(4);
        const pinned = root.isPinned(name);
        const rows = [{
            "label": `Open r/${name}`,
            "icon": "open_in_new",
            "action": () => {
                return root.openSub(name);
            }
        }, {
            "label": pinned ? "Remove from your list" : "Pin to your list",
            "icon": pinned ? "bookmark_remove" : "bookmark_add",
            "action": () => {
                return pinned ? root.unpinSub(name) : root.pinSub(name);
            }
        }];
        if (!pinned && root.recent.indexOf(name) >= 0)
            rows.push({
                "label": "Forget this one",
                "icon": "delete",
                "hint": "recently opened",
                "destructive": true,
                "action": () => {
                    return root.forget(name);
                }
            });

        rows.push({
            "label": "Open on reddit",
            "icon": "public",
            "action": () => {
                return root.openExternally(`https://www.reddit.com/r/${name}`);
            }
        });
        return rows;
    }

    function remember(sub) {
        const name = String(sub || "").toLowerCase();
        if (name.length === 0)
            return ;

        const seen = (root.settings && root.settings.recent ? root.settings.recent : []).filter((s) => {
            return s !== name;
        });
        seen.unshift(name);
        // Eight is a history, not a rail: your own list is the one you chose,
        // and the rest is what the site's community directory is for.
        root.saveSettings(Object.assign({
        }, root.settings, {
            "recent": seen.slice(0, 8)
        }));
        root.fetchIcon(name);
    }

    // ── the listing ──────────────────────────────────────────────────────────
    function openSub(name) {
        root.closePost();
        root.query = ""; root.searchSub = ""; root.foundSubs = [];
        root.sub = String(name || "all").toLowerCase();
        root.screen = "feed";
        root.remember(root.sub);
        root.reload();
    }

    /*
     * SOMEBODY'S PAGE, AS A LISTING.
     *
     * A profile is a listing of what they posted, so it IS `sub` — held as
     * "u/<name>" so one property still says where you are, one `reload()`
     * still fetches it, and the rail, the history and "open the real site
     * here" all keep working without a second screen to maintain.
     */
    function openUser(name) {
        const who = String(name || "").replace(/^u\//, "");
        if (who.length === 0 || who === "[deleted]")
            return ;

        root.closePost();
        root.query = ""; root.searchSub = ""; root.foundSubs = [];
        root.sub = `u/${who}`;
        root.screen = "feed";
        root.remember(root.sub);
        root.reload();
    }

    /// Whether `sub` is somebody's page rather than a community.
    function isProfile() {
        return root.sub.indexOf("u/") === 0;
    }

    function chooseSort(sort) {
        root.closePost();
        root.sort = sort;
        root.screen = "feed";
        root.reload();
    }

    function reload() {
        root.posts = [];
        root.after = "";
        root.hasMore = true;
        root.errorText = "";
        root.more();
    }

    function more() {
        if (root.loading || !root.hasMore)
            return ;

        root.loading = true;
        const asked = root.feedKey();
        const ask = root.query.length > 0 ? function(done) {
            return api.searchPosts(root.query, root.searchSub, root.searchSort, root.searchTime, root.after, done);
        } : root.isProfile() ? function(done) {
            return api.userListing(root.sub.slice(2), root.sort, root.after, done);
        } : function(done) {
            return api.listing(root.sub, root.sort, root.after, done);
        };
        ask(function(data, error) {
            if (asked !== root.feedKey())
                return ;

            // a different listing is on screen now
            root.loading = false;
            if (error && error.length > 0) {
                root.errorText = error;
                root.hasMore = false;
                return ;
            }
            root.errorText = "";
            const rows = Thread.children(data).map((child) => {
                return child.data;
            }).filter((row) => {
                return !!row && root.allowed(row);
            });
            const seen = {
            };
            for (const existing of root.posts) seen[existing.id] = true
            const fresh = rows.filter((row) => {
                return row.id && !seen[row.id];
            });
            root.posts = root.posts.concat(fresh);
            root.after = data && data.data && data.data.after ? String(data.data.after) : "";
            root.hasMore = root.after.length > 0;
        });
    }

    function showCommunities() {
        root.closePost();
        root.screen = "communities";
        if (root.communities.length > 0 || root.communitiesLoading)
            return ;

        root.communitiesLoading = true;
        api.communities(function(data, error) {
            root.communitiesLoading = false;
            if (error && error.length > 0) {
                root.errorText = error;
                return ;
            }
            root.communities = Thread.children(data).map((child) => {
                return child.data;
            }).filter((row) => {
                return !!row && root.allowed(row);
            });
        });
    }

    // ── one post, and what was said under it ─────────────────────────────────
    function openPost(item) {
        if (!item)
            return ;

        root.post = item;
        root.screen = "post";
        root.commentRows = [];
        root.collapsed = ({
        });
        root.loadedMore = ({
        });
        root._threadPayload = null;
        root.commentsError = "";
        root.commentsLoading = true;
        Catalog.remember("open", item.title || "", `reddit:${item.id}`);
        const asked = item.id;
        api.comments(item.id, root.commentSort, function(data, error) {
            if (!root.post || root.post.id !== asked)
                return ;

            // opened something else while this landed
            root.commentsLoading = false;
            if (error && error.length > 0) {
                root.commentsError = error;
                return ;
            }
            root._threadPayload = data;
            // Reddit answers the post again alongside its comments, and that
            // copy has the selftext and the counts the listing left out.
            const full = Thread.post(data);
            if (full)
                root.post = full;

            root._rebuild();
        });
    }

    /// The nth post of what is on screen — what a keyboard or a terminal can
    /// reach, where a skin has a row to click.
    function openPostAt(index) {
        const at = Number(index);
        if (!(at >= 0) || at >= root.posts.length)
            return ;

        root.openPost(root.posts[at]);
    }

    function chooseCommentSort(sort) {
        root.commentSort = sort;
        if (root.post)
            root.openPost(root.post);

    }

    function closePost() {
        if (root.screen !== "post")
            return ;

        root.screen = "feed";
        root.post = null;
        root.commentRows = [];
        root._threadPayload = null;
        root.commentsError = "";
        root.commentsLoading = false;
    }

    function _rebuild() {
        root.commentRows = root._threadPayload ? Thread.rows(root._threadPayload, root.collapsed, root.loadedMore) : [];
    }

    /// Fold a chain away, or open it again. The rows simply stop existing,
    /// which is what makes a long thread cheap to read.
    function toggleCollapse(id) {
        const next = Object.assign({
        }, root.collapsed);
        if (next[id])
            delete next[id];
        else
            next[id] = true;
        root.collapsed = next;
        root._rebuild();
    }

    /*
     * The rest of a chain reddit truncated.
     *
     * The batch endpoint for this needs an account. The same replies are public
     * at the comment's own permalink, so a stub fetches itself — one request
     * for a thing you pressed once, which is the right trade.
     */
    function loadMore(row) {
        if (!row || !root.post || root.loadingStub.length > 0)
            return ;

        const childId = (row.children && row.children.length > 0) ? String(row.children[0]) : String(row.parentId || "").replace(/^t1_/, "");
        if (childId.length === 0) {
            Toast.error("Reddit did not say what is under there");
            return ;
        }
        root.loadingStub = row.id;
        api.subtree(root.post.id, childId, root.commentSort, function(data, error) {
            root.loadingStub = "";
            if (error && error.length > 0) {
                Toast.error(error);
                return ;
            }
            const more = Object.assign({
            }, root.loadedMore);
            more[row.id] = Thread.subtreeChildren(data);
            root.loadedMore = more;
            root._rebuild();
        });
    }

    // ── pictures ─────────────────────────────────────────────────────────────
    /// The post's picture, if it has one worth opening.
    function imageOf(item) {
        return Thread.imageUrl(item);
    }

    function takePicture(item) {
        const url = Thread.imageUrl(item);
        if (url.length === 0) {
            Toast.error("That post is not a picture");
            return ;
        }
        const dir = `${Quickshell.env("HOME")}/.cache/quarry/reddit`;
        const name = `${item.subreddit || "reddit"}-${item.id}`.replace(/[^A-Za-z0-9_.-]/g, "_");
        const ext = (url.match(/\.(jpe?g|png|gif|webp)(\?|$)/i) || [])[1] || "jpg";
        const dest = `${dir}/${name}.${ext}`;
        const q = JSON.stringify;
        root.busyCount++;
        Sys.run(["bash", "-c", `mkdir -p ${q(dir)} && curl -sfL --max-time 120 -A ${q(api.userAgent)} -o ${q(dest + ".part")} ${q(url)} && mv -f ${q(dest + ".part")} ${q(dest)}`], function(ok) {
            if (!ok) {
                root.busyCount--;
                Toast.error("Could not fetch that picture");
                return ;
            }
            Client.call("adopt", {
                "path": "file://" + dest,
                "nsfw": item.over_18 === true,
                "tags": ["reddit", String(item.subreddit || "").toLowerCase()],
                "page_url": `https://www.reddit.com${item.permalink || ""}`
            }, function(err, payload) {
                root.busyCount--;
                if (err || !payload || !payload.item) {
                    Toast.error("quarry would not take it — " + String(err || "no item"));
                    return ;
                }
                Toast.show(`Kept · ${item.title || "picture"}`);
                Catalog.reload();
            });
        });
    }

    /*
     * THE SHAPES THIS LENS DRAWS, AND WHAT THEY ARE REMEMBERED AGAINST.
     *
     * Everything else — which one is current, its cell size, the setter, the
     * per-context memory — is inherited from Lens, so the app's layout button
     * drives this lens without it implementing anything. "Posts" is reddit's
     * own fifth shape: a subreddit is a conversation as well as a pile of
     * pictures, and the cards are how you read the conversation.
     */
    layouts: [{
        "id": "cards",
        "label": "Cards",
        "icon": "view_day",
        "hint": "full posts, pictures and videos in the card",
        "cell": 0
    }, {
        "id": "theater",
        "label": "Theater",
        "icon": "slideshow",
        "hint": "one picture or video at a time, full size",
        "cell": 0
    }, {
        "id": "posts",
        "label": "Posts",
        "icon": "view_agenda",
        "hint": "cards, with titles and scores",
        "cell": 0
    }].concat(root.pictureLayouts)
    /// Per subreddit: r/wallpapers wants a wall, r/AskReddit wants the cards,
    /// and nobody should have to say so twice.
    layoutContext: root.sub.toLowerCase()
    screenTitle: root.screen === "post" && root.post ? (root.post.title || "Post") : root.screen === "feed" && root.query.length > 0 ? `“${root.query}”${root.searchSub ? ` in r/${root.searchSub}` : ""} · ${root.searchSortLabel[root.searchSort]}` : root.screen === "feed" ? `${root.isProfile() ? root.sub : `r/${root.sub}`} · ${root.sortLabel[root.sort] || root.sort}` : "Reddit"
    /*
     * WHERE YOU ARE ON THE SITE ITSELF.
     *
     * Everything this lens does not do — voting, replying, the sidebar, the
     * wiki — is one row away in the app's own browser, on the same page.
     */
    siteUrl: {
        if (root.screen === "post" && root.post && root.post.permalink)
            return `https://www.reddit.com${root.post.permalink}`;

        if (root.screen === "communities")
            return "https://www.reddit.com/subreddits/popular";

        if (root.isProfile())
            return `https://www.reddit.com/user/${root.sub.slice(2)}`;

        return `https://www.reddit.com/r/${root.sub}/${root.sort}`;
    }
    navItems: {
        const items = [];
        if (root.screen === "post" && root.post)
            items.push({
            "id": "__post",
            "label": root.post.title || "Post",
            "sublabel": `r/${root.post.subreddit || root.sub}`,
            "icon": "chat_bubble",
            "active": true
        });

        /*
         * THREE GROUPS, EACH UNDER ITS OWN HEADING.
         *
         * Twenty pills in a row with no structure is a list you read from the
         * top every time. The rail supports captions now (see NavRail), so
         * this says what each group IS: how the current subreddit is sorted,
         * the subreddits you chose, and the ones you happened to open.
         */
        items.push({
            "caption": true,
            // `sub` holds "u/<name>" for somebody's page — see openUser — and
            // "r/u/somebody" is not a place.
            "label": root.isProfile() ? root.sub : `r/${root.sub}`,
            "sublabel": root.posts.length > 0 ? `${root.posts.length} posts` : ""
        });
        for (const name of ["hot", "new", "top", "rising"]) items.push({
            "id": `sort:${name}`,
            "label": root.sortLabel[name] || name,
            "icon": name === "new" ? "schedule" : name === "top" ? "trending_up" : name === "rising" ? "arrow_upward" : "local_fire_department",
            "active": root.screen === "feed" && root.sort === name
        })
        items.push({
            "caption": true,
            "label": "Your subreddits",
            "sublabel": root.pinned.length > 0 ? String(root.pinned.length) : "none yet"
        });
        for (const name of root.pinned) items.push({
            "id": `sub:${name}`,
            "label": String(name).indexOf("u/") === 0 ? name : `r/${name}`,
            "picture": root.subIcons[name] || "",
            "icon": String(name).indexOf("u/") === 0 ? "person" : "tag",
            "active": root.screen === "feed" && root.sub === name
        })
        items.push({
            "id": "pin",
            "label": root.isPinned(root.sub) ? `Remove ${root.isProfile() ? root.sub : `r/${root.sub}`}` : `Pin ${root.isProfile() ? root.sub : `r/${root.sub}`}`,
            "icon": root.isPinned(root.sub) ? "bookmark_remove" : "bookmark_add",
            "active": false
        });
        if (root.recent.length > 0) {
            items.push({
                "caption": true,
                "label": "Recently opened"
            });
            for (const name of root.recent) items.push({
                "id": `sub:${name}`,
                "label": String(name).indexOf("u/") === 0 ? name : `r/${name}`,
                "picture": root.subIcons[name] || "",
                "icon": String(name).indexOf("u/") === 0 ? "person" : "history",
                "active": root.screen === "feed" && root.sub === name
            })
        }
        items.push({
            "caption": true,
            "label": "Browse"
        });
        items.push({
            "id": "browse",
            "label": "All communities",
            "icon": "explore",
            "active": root.screen === "communities"
        });
        return items;
    }
    onNavPicked: (id) => {
        if (id === "__post")
            return ;

        if (id === "browse") {
            root.showCommunities();
            return ;
        }
        // The pin row toggles: what it says is what it will do, so pressing it
        // twice is not a trap.
        if (id === "pin") {
            if (root.isPinned(root.sub))
                root.unpinSub(root.sub);
            else
                root.pinSub(root.sub);
            return ;
        }
        if (id.indexOf("sort:") === 0) {
            root.chooseSort(id.slice(5));
            return ;
        }
        if (id.indexOf("sub:") === 0)
            root.openSub(id.slice(4));

    }
    canGoBack: root.screen !== "feed"
    onBackRequested: {
        if (root.screen === "post") {
            root.closePost();
            return ;
        }
        root.screen = "feed";
    }
    menuItems: [{
        "label": "Take this picture",
        "icon": "library_add",
        "hint": "into the catalogue",
        "action": () => {
            if (!root.post) {
                Toast.error("Open a post first");
                return ;
            }
            root.takePicture(root.post);
        }
    }, {
        "label": "Copy the link",
        "icon": "link",
        "action": () => {
            Sys.copyText(root.siteUrl, (ok) => {
                return ok ? Toast.show("Link copied") : Toast.error("Could not copy — " + Sys.lastError);
            });
        }
    }].concat(root.screen === "feed" ? root.layoutMenu : [])
    onOpened: {
        if (root.posts.length === 0)
            root.reload();

        // The rail draws these; they cost one request each, once ever.
        for (const name of root.pinned) root.fetchIcon(name)
    }

    _api: Api {
        id: api
    }

}
