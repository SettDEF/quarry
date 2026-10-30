import QtQuick
import "post.js" as Post
import qs.modules.common
import qs.modules.lens
import qs.services

/*
 * THE 4CHAN LENS — a board reader, not a source adapter.
 *
 * Three screens: the boards you allow, one board's catalogue, one thread with
 * its replies. All of it read-only, over the public JSON API, one request a
 * second with conditional GETs (Api.qml enforces both). Images come straight
 * from i.4cdn.org; nothing is rehosted, and nothing enters the catalogue until
 * you say so.
 *
 * This file is the STATE. It knows nothing about how any of it looks — the
 * skins under skins/ read it and draw. That split is why the Yotsuba skin can
 * look like the site and the Quarry skin like the app, off one navigation
 * stack and one fetch queue.
 *
 * WHICH BOARDS. The default list is drawn and created work and wallpapers, the
 * things this app is for. Nothing is on by default that carries reposted
 * photographs of real people — /b/ and the photo boards are not shipped on, and
 * adding them is a deliberate act with a warning attached. A board the site
 * does not mark worksafe marks every row it contributes as adult, so quarry's
 * own blur and hide settings have something to act on.
 */
Lens {
    id: root

    // ── where you are ────────────────────────────────────────────────────────
    /// "boards" · "catalog" · "thread" · "images"
    property string screen: "boards"
    property string board: ""
    /*
     * Bound, not assigned. Assigned once at navigation time, both of these were
     * wrong whenever the board list had not landed yet — and "unknown board" is
     * conservatively ADULT, so a board opened straight from a result blurred
     * itself for good. A binding corrects itself when the list arrives.
     */
    readonly property string boardTitle: {
        for (let i = 0; i < root.allBoards.length; i++) if (root.allBoards[i].board === root.board) {
            return root.allBoards[i].title;
        }
        return "";
    }
    readonly property bool boardAdult: root.isAdultBoard(root.board)
    property int threadNo: 0
    property string threadTitle: ""
    property var allBoards: [] // every board the site lists
    property var threads: [] // the current catalogue, flattened
    property var posts: [] // the current thread
    property var backlinks: ({
    }) // no -> [nos that replied]
    property string filter: "" // substring filter over a catalogue
    property bool spoilersShown: false
    property bool loading: false
    property string errorText: ""
    /*
     * WHAT THE CATALOGUE SHOWS, AFTER EVERYTHING THAT GETS A SAY.
     *
     * Three filters in order: what you hid by hand, what you typed in the
     * filter box, and what your own scripts decided (services/Scripts.qml).
     * The script pass is last so a person's explicit choices are never
     * overridden by a file they wrote a month ago — and it gets the board, so
     * a script can care about /g/ and not /a/.
     */
    readonly property var visibleThreads: {
        const needle = root.filter.trim().toLowerCase();
        const kept = root.threads.filter((t) => {
            return !root.isHidden(t.no);
        });
        const matched = needle.length === 0 ? kept : kept.filter((t) => {
            return (Post.plain(t.sub) + " " + Post.plain(t.com)).toLowerCase().indexOf(needle) >= 0;
        });
        return Scripts.filterRows(matched, {
            "lens": "fourchan",
            "screen": "catalogue",
            "board": root.board
        });
    }
    /// The thread with what you hid taken out. The OP always stays: hiding it
    /// means hiding the thread, which is done from the catalogue.
    readonly property var visiblePosts: {
        const kept = root.posts.filter((p, i) => {
            return i === 0 || !root.isHidden(p.no);
        });
        // The OP is not offered to scripts: hiding it means hiding the thread,
        // which is a catalogue decision, and a thread whose first post
        // vanished reads as a bug rather than a filter.
        const rest = Scripts.filterRows(kept.slice(1), {
            "lens": "fourchan",
            "screen": "thread",
            "board": root.board
        });
        return kept.length > 0 ? [kept[0]].concat(rest) : rest;
    }
    /*
     * HIDDEN, AND STILL HIDDEN TOMORROW.
     *
     * Per board, in the lens's own settings — a thread you closed for good and
     * the posts that were not worth the room. Something that comes back after a
     * restart was never hidden.
     */
    readonly property var hiddenMap: (root.settings.hidden && typeof root.settings.hidden === "object") ? root.settings.hidden : ({
    })
    readonly property var hiddenHere: {
        const held = root._list(root.hiddenMap[root.board]);
        return held ? held.map((n) => {
            return Number(n);
        }) : [];
    }
    readonly property int hiddenCount: root.hiddenHere.length
    // ── which boards you allow ───────────────────────────────────────────────
    //
    //     * Drawn and created content, and wallpapers. /wg/ wallpapers, /w/ anime
    //     * wallpapers, /wsg/ worksafe gifs, /a/ anime, /g/ technology (its desktop
    //     * threads are where wallpapers actually circulate), /ic/ artwork critique,
    //     * /3/ 3D modelling, /po/ papercraft and origami.
    //
    readonly property var defaultBoards: ["3", "a", "g", "ic", "po", "w", "wg", "wsg"]
    readonly property var enabledBoards: {
        const held = root._list(root.settings.boards);
        return held ? held : root.defaultBoards;
    }
    /*
     * "OFFER ADULT BOARDS" IS THIS LENS ASKING, NOT THIS LENS DECIDING.
     *
     * It was read alone, so a board switched on months ago stayed in the rail
     * and stayed openable with quarry's own "Show adult results" turned off —
     * the catalogue kept the promise and the lens quietly broke it. The global
     * switch is the ceiling; this setting only chooses within it.
     */
    readonly property bool adultBoardsOffered: Prefs.showNsfw && root.settings.adultBoardsOffered === true

    /*
     * 4chan's own `ws_board` flag is the signal, and it is taken at its word.
     *
     * That is stricter than it first looks: /wg/ and /ic/ are flagged 0 despite
     * being mostly wallpapers and drawings, so they go too while the switch is
     * off. That is the correct trade — the flag is the site saying "not safe
     * for work", and second-guessing it per board is how a hidden category
     * turns out to have been showing something after all.
     */
    function _boardAllowed(b) {
        return Prefs.showNsfw || b.ws_board === 1;
    }

    readonly property var boards: root.allBoards.filter((b) => {
        return root.enabledBoards.indexOf(b.board) >= 0 && root._boardAllowed(b);
    })
    /// What you could add: everything else, adult boards only once asked for.
    readonly property var offerableBoards: root.allBoards.filter((b) => {
        return root.enabledBoards.indexOf(b.board) < 0 && root._boardAllowed(b) && (root.adultBoardsOffered || b.ws_board === 1 || root.defaultBoards.indexOf(b.board) >= 0);
    })
    /// Jump to a post inside the open thread. Skins bind their list to this.
    property int focusPost: 0
    // ── images ───────────────────────────────────────────────────────────────
    readonly property string files: "https://i.4cdn.org"
    /*
     * PICTURES COME THROUGH THE DAEMON, NOT STRAIGHT OFF THE CDN.
     *
     * Loading them from QML has no pacing, no retry and no cache: opening a
     * thread asks for fifty files at once and 4chan answers 429, which QML
     * shows as nothing at all. The daemon has the per-host limiter and a disk
     * cache, so each URL is asked for once and kept.
     */
    property var localFiles: ({
    })
    property int localRevision: 0
    property var localPending: ({
    })
    /*
     * url -> when it last failed.
     *
     * Without this a failure is a LOOP: the ask fails, the counter moves, every
     * binding that wanted the picture runs again and asks again — measured at
     * 80% of a core with the daemon down, which is the one time this path is
     * guaranteed to fail. A failure is remembered for half a minute and then
     * forgiven, so a daemon coming back fixes itself without a retry storm.
     */
    property var localFailed: ({
    })
    readonly property int localRetryMs: 30000
    /*
     * A SECOND COUNTER, ON PURPOSE.
     *
     * "A fetch started" must not move the counter `local()` itself reads, or
     * every picture binding re-runs because of something it just did — Qt
     * calls that a binding loop and says so once per tile. Only the spinner
     * watches this one.
     */
    property int fetchRevision: 0
    /*
     * A FAILURE HAS TO EXPIRE BY ITSELF.
     *
     * The penalty box stops a retry storm, but nothing re-runs a picture's
     * binding on its own — so a tile that failed once while the daemon was
     * restarting stayed blank for good, and starting quarryd did not fix it.
     * The counter is nudged while anything is waiting out its half minute, and
     * a reconnect forgives the lot at once.
     */
    property Timer _forgive

    _forgive: Timer {
        interval: root.localRetryMs
        repeat: true
        running: Object.keys(root.localFailed).length > 0
        onTriggered: root.localRevision++
    }

    property Connections _daemon

    _daemon: Connections {
        function onReconnected() {
            root.localFailed = ({
            });
            root.localRevision++;
        }

        target: Client
    }

    /// Every post in the open thread that carries a picture.
    readonly property var threadImages: root.posts.filter((p) => {
        return root.hasImage(p);
    })
    /// …minus what you hid. ONE list, read by the wall, the viewer, the rail's
    /// count and "take every picture": two of them disagreeing is a counter
    /// that says 40 over a wall of 39, and arrows that walk to a picture which
    /// is not there.
    readonly property var wallImages: root.visiblePosts.filter((p) => {
        return root.hasImage(p);
    })
    // ── looking at one file ──────────────────────────────────────────────────
    //
    //     * THE VIEWER IS THE POINT OF A PICTURE LENS.
    //     *
    //     * Expanding in place is how the site reads a thread; it is not how you look
    //     * at a 4000px photograph or watch a clip. So the file opens over the whole
    //     * view at its own size, and the arrow keys walk the thread's pictures
    //     * without losing your place in the conversation.
    //
    property var viewing: null
    /// What the arrow keys walk: the pictures on the screen you opened from.
    readonly property var viewerList: root.screen === "catalog" ? root.visibleThreads.filter((t) => {
        return root.hasImage(t);
    }) : root.wallImages
    readonly property int viewerIndex: {
        if (!root.viewing)
            return -1;

        for (let i = 0; i < root.viewerList.length; i++) if (root.viewerList[i].no === root.viewing.no) {
            return i;
        }
        return -1;
    }
    // ── add to quarry ────────────────────────────────────────────────────────
    //
    //     * The image is fetched to quarry's own cache and then ADOPTED, which is the
    //     * same path a file dropped on a board takes: it gets a thumbnail, a
    //     * dominant colour and a perceptual hash, and it can be searched for
    //     * afterwards. Nothing is indexed behind your back — one picture, because
    //     * you asked for that picture.
    //     *
    //     * The folder is named `4chan-<board>`, and quarryd tags an adopted file
    //     * with its folder, so `tag:4chan-wg` finds everything you took from /wg/.
    //
    readonly property string userAgent: "quarry/0.1 (lens; +https://github.com/quarry)"
    property var added: ({
    }) // tim -> catalogue id, for a tick in the UI
    property var addedItems: ({
    }) // tim -> the row itself, for export and similar
    property int busyCount: 0
    property int bulkTotal: 0
    property int bulkDone: 0
    property bool bulkCancelled: false
    readonly property bool bulkRunning: root.bulkTotal > 0 && root.bulkDone < root.bulkTotal
    // ── plumbing ─────────────────────────────────────────────────────────────
    property Api _api

    _api: Api {
        id: api

        onFailed: (url, message) => {
            return console.warn("[4chan]", url, message);
        }
    }

    readonly property bool fetching: root.loading || api.busy

    function isHidden(no) {
        return root.hiddenHere.indexOf(Number(no)) >= 0;
    }

    function setHidden(no, on) {
        const list = root.hiddenHere.filter((n) => {
            return n !== Number(no);
        });
        if (on)
            list.push(Number(no));

        const map = {
        };
        for (const k in root.hiddenMap) map[k] = root.hiddenMap[k]
        map[root.board] = list;
        const next = root._settingsCopy();
        next.hidden = map;
        root.saveSettings(next);
    }

    function hidePost(post) {
        if (!post)
            return ;

        // Step off it first: hiding what the viewer is showing would leave the
        // viewer on a post that is no longer in any list, with both arrows dead.
        if (root.viewing && Number(root.viewing.no) === Number(post.no)) {
            root.viewerStep(1);
            if (root.viewing && Number(root.viewing.no) === Number(post.no))
                root.viewerStep(-1);

            if (root.viewing && Number(root.viewing.no) === Number(post.no))
                root.closeViewer();

        }
        root.setHidden(post.no, true);
        Toast.show("Hidden", "Undo", () => {
            return root.setHidden(post.no, false);
        });
    }

    /// A thread's number IS its first post's number, so hiding the OP from
    /// inside the thread would quietly delete the thread from the catalogue.
    function isOp(post) {
        return !!(post && root.posts.length > 0 && Number(root.posts[0].no) === Number(post.no));
    }

    function unhideAll() {
        const map = {
        };
        for (const k in root.hiddenMap) map[k] = root.hiddenMap[k]
        map[root.board] = [];
        const next = root._settingsCopy();
        next.hidden = map;
        root.saveSettings(next);
        Toast.show(`Everything on /${root.board}/ is back`);
    }

    /*
     * A LIST THAT CAME BACK THROUGH A `var` PROPERTY IS NOT AN `Array`.
     *
     * The registry hands a lens its settings by assigning them to a QML `var`,
     * which converts a JS array into a QVariantList — and `Array.isArray` is
     * FALSE for one of those. So this read "no boards saved" every single
     * start, handed back the defaults, and the boards someone had picked were
     * sitting in the file the whole time. That is the "it resets every time".
     *
     * Measured against the user's own lenses.json: nine boards on disk, eight
     * defaults on screen.
     */
    function _list(value) {
        if (!value || typeof value === "string" || value.length === undefined)
            return null;

        const out = [];
        for (let i = 0; i < value.length; i++) out.push(String(value[i]))
        return out;
    }

    /*
     * Turning the switch off while reading an adult board leaves it, rather
     * than leaving the thread on screen until the next navigation.
     */
    property Connections _adultSwitch: Connections {
        target: Prefs

        function onShowNsfwChanged() {
            if (Prefs.showNsfw || root.board.length === 0)
                return ;

            if (root.isAdultBoard(root.board))
                root.showBoards();

        }
    }

    function isAdultBoard(id) {
        if (!id || id.length === 0)
            return false;

        for (let i = 0; i < root.allBoards.length; i++) if (root.allBoards[i].board === id) {
            return root.allBoards[i].ws_board !== 1;
        }
        return true; // unknown board: assume the careful answer
    }

    function setBoardEnabled(id, on) {
        // Compared as strings on both sides: a board is "3" as often as it is
        // "wg", and one number slipping in makes the removal quietly miss.
        const wanted = String(id);
        const list = root.enabledBoards.filter((b) => {
            return String(b) !== wanted;
        });
        if (on)
            list.push(wanted);

        list.sort();
        const next = root._settingsCopy();
        next.boards = list;
        root.saveSettings(next);
    }

    function offerAdultBoards(on) {
        const next = root._settingsCopy();
        next.adultBoardsOffered = !!on;
        root.saveSettings(next);
    }

    function _settingsCopy() {
        const out = {
        };
        for (const k in root.settings) out[k] = root.settings[k]
        return out;
    }

    function back() {
        if (root.viewing !== null) {
            root.closeViewer();
            return ;
        }
        if (root.screen === "images")
            root.screen = "thread";
        else if (root.screen === "thread")
            root.showCatalog(root.board);
        else if (root.screen === "catalog")
            root.showBoards();
    }

    /// Every picture in the open thread, as a wall — which is the thing quarry
    /// is for. The thread is still there behind it, one step back.
    function showImages() {
        if (root.threadNo > 0)
            root.screen = "images";

    }

    function showBoards() {
        api.clearPending();
        root.screen = "boards";
        root.filter = "";
        root.loadBoards();
    }

    function loadBoards() {
        if (root.allBoards.length > 0 && !root.loading)
            return ;
 // /boards.json barely changes
        root.loading = true;
        root.errorText = "";
        api.get("/boards.json", function(data, error) {
            root.loading = false;
            if (error.length > 0 || !data || !data.boards) {
                root.errorText = "Could not read the board list — " + error;
                return ;
            }
            root.allBoards = data.boards;
        });
    }

    function showCatalog(id) {
        /*
         * The last gate, and the one that matters.
         *
         * Filtering the lists is presentation; this is the door. A board can be
         * reached by a restored session, a keyboard shortcut or a link in a
         * post, none of which go through the rail — so the check lives here as
         * well, where every route ends up.
         */
        if (!Prefs.showNsfw && root.isAdultBoard(String(id))) {
            root.showBoards();
            return ;
        }
        api.clearPending();
        root.board = String(id);
        root.screen = "catalog";
        root.filter = "";
        root.errorText = "";
        // Paint what is already in memory, then refresh over the top of it.
        const seen = api.cached(`/${root.board}/catalog.json`);
        root.threads = seen ? root._flatten(seen) : [];
        root.loading = true;
        api.get(`/${root.board}/catalog.json`, function(data, error) {
            if (root.screen !== "catalog" || root.board !== id)
                return ;

            root.loading = false;
            if (error.length > 0 || !data) {
                root.errorText = `Could not read /${id}/ — ${error}`;
                return ;
            }
            root.threads = root._flatten(data);
        });
    }

    function _flatten(pages) {
        const out = [];
        for (let i = 0; i < pages.length; i++) {
            const threads = pages[i].threads || [];
            for (let j = 0; j < threads.length; j++) out.push(threads[j])
        }
        return out;
    }

    function showThread(no, title) {
        api.clearPending();
        root.threadNo = Number(no);
        root.threadTitle = title && title.length > 0 ? Post.plain(title) : `#${no}`;
        root.screen = "thread";
        root.errorText = "";
        root.spoilersShown = false;
        const seen = api.cached(`/${root.board}/thread/${no}.json`);
        root._takeThread(seen);
        root.loading = true;
        api.get(`/${root.board}/thread/${no}.json`, function(data, error) {
            if (root.screen !== "thread" || root.threadNo !== Number(no))
                return ;

            root.loading = false;
            if (error.length > 0 || !data) {
                root.errorText = `Could not read that thread — ${error}`;
                return ;
            }
            root._takeThread(data);
        });
    }

    function _takeThread(data) {
        const list = (data && data.posts) ? data.posts : [];
        root.posts = list;
        root.backlinks = Post.backlinks(list);
        if (list.length > 0 && list[0].sub)
            root.threadTitle = Post.plain(list[0].sub);

    }

    function goToPost(no) {
        root.focusPost = Number(no);
    }

    function refresh() {
        if (root.screen === "thread" || root.screen === "images") {
            root.showThread(root.threadNo, root.threadTitle);
        } else if (root.screen === "catalog") {
            root.showCatalog(root.board);
        } else {
            root.allBoards = [];
            root.loadBoards();
        }
    }

    function hasImage(post) {
        return post && post.tim !== undefined && post.ext !== undefined;
    }

    function thumbUrl(post, boardId) {
        return `${root.files}/${boardId || root.board}/${post.tim}s.jpg`;
    }

    function fileUrl(post, boardId) {
        return `${root.files}/${boardId || root.board}/${post.tim}${post.ext}`;
    }

    /*
     * A local path for `url` when there is one; asks for it when there is not.
     *
     * THE ASK IS DEFERRED, and that is not tidiness. quarryd's client answers
     * a call SYNCHRONOUSLY when it is not connected, so the callback ran inside
     * the binding that was asking for the picture and wrote the counter that
     * same binding reads — Qt calls that a binding loop, abandons the binding,
     * and the picture never arrives. Measured: 42 abandoned bindings on one
     * catalogue, and 80% of a core spent retrying with the daemon down.
     */
    function local(url) {
        if (!url || url.length === 0)
            return "";

        // Read so the binding depends on it and re-runs when a file lands.
        const seen = root.localRevision;
        const held = root.localFiles[url];
        if (held !== undefined)
            return held;

        const failedAt = root.localFailed[url];
        if (failedAt !== undefined && Date.now() - failedAt < root.localRetryMs)
            return "";

        if (!root.localPending[url]) {
            root.localPending[url] = true;
            Qt.callLater(() => {
                return root._fetch(url);
            });
        }
        return "";
    }

    function _fetch(url) {
        root.fetchRevision++;
        Client.call("cache_url", {
            "url": url,
            "referer": "https://boards.4chan.org/"
        }, function(err, payload) {
            delete root.localPending[url];
            if (err || !payload || !payload.path) {
                // Blank, not wrong — and not asked for again straight away.
                root.localFailed[url] = Date.now();
                root.fetchRevision++;
                root.localRevision++;
                return ;
            }
            delete root.localFailed[url];
            root.localFiles[url] = "file://" + payload.path;
            root.fetchRevision++;
            root.localRevision++;
        });
    }

    /// The thumbnail, then the file: a cell shows something immediately and
    /// sharpens when the full picture has been fetched.
    function pictureFor(post, wantFull, boardId) {
        const thumb = root.local(root.thumbUrl(post, boardId));
        if (!wantFull)
            return thumb;

        const full = root.local(root.fileUrl(post, boardId));
        return full.length > 0 ? full : thumb;
    }

    function isVideo(post) {
        return root.hasImage(post) && String(post.ext).toLowerCase() === ".webm";
    }

    /// A post's comment as plain text, for the clipboard.
    function plainText(post) {
        return post ? Post.plain(post.com) : "";
    }

    function fileName(post) {
        return `${Post.plain(post.filename)}${post.ext}`;
    }

    /// The file itself — full resolution, through the daemon's cache like
    /// everything else. "" until it lands.
    function fullFor(post, boardId) {
        return root.local(root.fileUrl(post, boardId));
    }

    /// True while the full file is still coming. Reads `fetchRevision`, the
    /// counter that moves when a fetch STARTS as well as when it lands.
    function isFetching(post, boardId) {
        const seen = root.fetchRevision;
        return root.localPending[root.fileUrl(post, boardId)] === true;
    }

    function openViewer(post) {
        if (!root.hasImage(post))
            return ;

        root.viewing = post;
        root.fullFor(post); // start the fetch with the viewer, not after it
    }

    /// The nth picture on this screen — what a keyboard shortcut and a probe
    /// can both ask for, where a whole post object is not passable.
    function openViewerAt(index) {
        const list = root.viewerList;
        if (index >= 0 && index < list.length)
            root.openViewer(list[index]);

    }

    function closeViewer() {
        root.viewing = null;
    }

    function viewerStep(delta) {
        const at = root.viewerIndex;
        if (at < 0)
            return ;

        const next = at + delta;
        if (next < 0 || next >= root.viewerList.length)
            return ;

        root.openViewer(root.viewerList[next]);
    }

    // ── what you can do with one post ────────────────────────────────────────
    /// Where this post lives on the site. In a catalogue a "post" is a thread's
    /// first one, so its own number is the thread.
    function postUrl(post) {
        const thread = root.screen === "catalog" || root.threadNo === 0 ? post.no : root.threadNo;
        return `https://boards.4chan.org/${root.board}/thread/${thread}#p${post.no}`;
    }

    function copyImageLink(post) {
        Sys.copyText(root.fileUrl(post), (ok) => {
            return ok ? Toast.show("Image link copied") : Toast.error("Could not copy — " + Sys.lastError);
        });
    }

    function copyPostLink(post) {
        Sys.copyText(root.postUrl(post), (ok) => {
            return ok ? Toast.show("Post link copied") : Toast.error("Could not copy — " + Sys.lastError);
        });
    }

    /// The picture itself on the clipboard — the cached file, so nothing is
    /// fetched twice and the CDN is not asked again.
    function copyImageFile(post) {
        const path = root.fullFor(post);
        if (path.length === 0) {
            Toast.show("Fetching it first…");
            return ;
        }
        const mime = String(post.ext).toLowerCase() === ".png" ? "image/png" : String(post.ext).toLowerCase() === ".gif" ? "image/gif" : "image/jpeg";
        Sys.copyImage(path.replace("file://", ""), mime, (ok) => {
            return ok ? Toast.show("Picture copied · paste it anywhere") : Toast.error("Could not copy — " + Sys.lastError);
        });
    }

    function openOnSite(post) {
        Sys.open(root.postUrl(post));
    }

    function openImageInBrowser(post) {
        Sys.open(root.fileUrl(post));
    }

    /// The app's own list, given this file rather than a catalogue row — one
    /// list of engines for the whole app, not a second one here.
    function webSearches(post) {
        if (!root.hasImage(post))
            return [];

        return Catalog.pictureSearchEngines({
            "family": root.isVideo(post) ? "video" : "raster",
            "url": root.fileUrl(post),
            "sample": "",
            "thumb": root.thumbUrl(post)
        });
    }

    /*
     * EVERYTHING ELSE QUARRY CAN DO NEEDS THE PICTURE IN QUARRY.
     *
     * Export, wallpaper and "find similar" all act on a catalogue row, so the
     * picture is taken first — which is what you were going to do anyway, and
     * it means these rows work on a picture you have not taken yet rather than
     * being greyed out until you remember to.
     */
    function withItem(post, onItem) {
        root.addImage(post, function(ok, item) {
            if (!ok || !item)
                return ;

            onItem(item);
        });
    }

    function exportImage(post, targetId) {
        root.withItem(post, function(item) {
            const target = Targets.byId(targetId);
            Toast.show(`Exporting ${target ? target.label : targetId}…`);
            Catalog.exportItem(item, targetId, function(err, payload) {
                if (err) {
                    Toast.error("That did not work: " + err);
                    return ;
                }
                Toast.show(`${payload.path.split("/").pop()} · ${payload.human}`, "Show", () => {
                    return Sys.showInFiles(payload.path);
                });
            });
        });
    }

    function setWallpaper(post, targetId) {
        root.withItem(post, function(item) {
            Toast.show("Exporting for the wallpaper…");
            Catalog.exportItem(item, targetId, function(err, payload) {
                if (err) {
                    Toast.error("Export failed: " + err);
                    return ;
                }
                Sys.setWallpaper(payload.path, (ok) => {
                    return ok ? Toast.show("Wallpaper set · the palette follows") : Toast.error(`Saved to ${payload.path} — no wallpaper switcher answered`);
                });
            });
        });
    }

    /// Like this one, in your own catalogue. The lens closes: the answer is a
    /// wall of results, and that lives behind this screen.
    function findSimilar(post) {
        root.withItem(post, function(item) {
            Lenses.close();
            Catalog.findSimilar(item, false, "all");
        });
    }

    function isAdded(post) {
        return root.hasImage(post) && root.added[String(post.tim)] !== undefined;
    }

    function addImage(post, onDone) {
        if (!root.hasImage(post)) {
            if (onDone)
                onDone(false);

            return ;
        }
        if (root.isAdded(post)) {
            const held = root.addedItems[String(post.tim)] || Catalog.itemById(root.added[String(post.tim)]);
            if (onDone)
                onDone(true, held || null);
            else
                Toast.show("Already in quarry");
            return ;
        }
        if (!Client.connected) {
            Toast.error("Can't add — start quarryd first");
            if (onDone)
                onDone(false);

            return ;
        }
        const boardId = root.board;
        const dir = `${Sys.home}/.cache/quarry/lens/4chan-${boardId}`;
        const dest = `${dir}/${post.tim}${post.ext}`;
        const url = root.fileUrl(post, boardId);
        const q = JSON.stringify;
        root.busyCount++;
        Sys.run(["bash", "-c", `mkdir -p ${q(dir)} && curl -sfL --max-time 120 -A ${q(root.userAgent)} -o ${q(dest + ".part")} ${q(url)} && mv -f ${q(dest + ".part")} ${q(dest)}`], function(ok) {
            if (!ok) {
                root.busyCount--;
                Toast.error("Could not fetch that file");
                if (onDone)
                    onDone(false);

                return ;
            }
            /*
             * `nsfw` and `tags` ride along for the daemon that will read them;
             * an older daemon ignores unknown params, so this is safe to send
             * now and marks adult boards correctly the moment it lands.
             */
            Client.call("adopt", {
                "path": "file://" + dest,
                "nsfw": root.isAdultBoard(boardId),
                "tags": ["4chan", boardId],
                "page_url": `https://boards.4chan.org/${boardId}/thread/${root.threadNo}#p${post.no}`
            }, function(err, payload) {
                root.busyCount--;
                if (err || !payload || !payload.item) {
                    Toast.error("quarry would not take it — " + String(err || "no item"));
                    if (onDone)
                        onDone(false);

                    return ;
                }
                const next = {
                };
                for (const k in root.added) next[k] = root.added[k]
                next[String(post.tim)] = payload.item.id;
                root.added = next;
                const rows = {
                };
                for (const k in root.addedItems) rows[k] = root.addedItems[k]
                rows[String(post.tim)] = payload.item;
                root.addedItems = rows;
                if (onDone)
                    onDone(true, payload.item);

            });
        });
    }

    /// Every picture in the open thread, one at a time so the file host is not
    /// hit with two hundred parallel requests.
    function addThread() {
        if (root.bulkRunning)
            return ;

        const wanted = root.wallImages.filter((p) => {
            return !root.isAdded(p);
        });
        if (wanted.length === 0) {
            Toast.show("Nothing new in this thread");
            return ;
        }
        root.bulkCancelled = false;
        root.bulkTotal = wanted.length;
        root.bulkDone = 0;
        root._addNext(wanted, 0);
    }

    function cancelBulk() {
        root.bulkCancelled = true;
    }

    function _addNext(list, index) {
        if (root.bulkCancelled || index >= list.length) {
            const done = root.bulkDone;
            root.bulkTotal = 0;
            root.bulkDone = 0;
            Toast.show(root.bulkCancelled ? `Stopped — ${done} added` : `${done} added to quarry`);
            return ;
        }
        root.addImage(list[index], function() {
            root.bulkDone = index + 1;
            root._addNext(list, index + 1);
        });
    }

    screenTitle: root.screen === "images" ? `/${root.board}/ — ${root.threadTitle} · images` : root.screen === "thread" ? `/${root.board}/ — ${root.threadTitle}` : root.screen === "catalog" ? `/${root.board}/ — ${root.boardTitle}` : "4chan"
    canGoBack: root.screen !== "boards" || root.viewing !== null
    // The rail becomes this lens's board list while it is open.
    // The rail says which board, what it is for, and marks the adult ones —
    // eight rows of the same speech-bubble told you nothing.
    //
    //     * THE RAIL IS THIS LENS'S NAVIGATION WHILE IT IS OPEN.
    //     *
    //     * Not just a list of boards: where you are is on it too. A thread puts its
    //     * own row at the top with the two ways to read it — as a conversation and
    //     * as a wall of its pictures — and the board you are in carries its live
    //     * thread count, so the rail says what it costs to go there.
    //
    navItems: {
        const rows = [];
        if (root.threadNo > 0 && root.board.length > 0) {
            rows.push({
                "id": "__thread",
                "label": root.threadTitle,
                "sublabel": `${root.posts.length} posts`,
                "icon": "forum",
                "count": "",
                "active": root.screen === "thread"
            });
            rows.push({
                "id": "__images",
                "label": "Pictures",
                "sublabel": "this thread, as a wall",
                "icon": "grid_view",
                "count": String(root.wallImages.length),
                "active": root.screen === "images"
            });
        }
        rows.push({
            "id": "__boards",
            "label": "Boards",
            "sublabel": "the ones you read",
            "icon": "dashboard",
            "count": String(root.boards.length),
            "active": root.screen === "boards"
        });
        for (let i = 0; i < root.boards.length; i++) {
            // What is actually in there, once you are in there — a number
            // on every row would be a number nobody has fetched.
            // The catalogue's own size, not the filtered one: `filter`
            // changes per keystroke and the rail's whole model would be
            // rebuilt with it.

            const b = root.boards[i];
            const here = root.board === b.board;
            rows.push({
                "id": b.board,
                "label": `/${b.board}/`,
                "sublabel": b.title || "",
                "icon": b.ws_board === 0 ? "no_adult_content" : "forum",
                "count": here && root.threads.length > 0 ? String(root.threads.length) : "",
                "active": here && root.screen !== "boards"
            });
        }
        return rows;
    }
    onNavPicked: (id) => {
        if (id === "__boards")
            root.showBoards();
        else if (id === "__images")
            root.showImages();
        else if (id === "__thread")
            root.screen = "thread";
        else
            root.showCatalog(id);
    }
    /*
     * THE BOARD, IN THE FOUR SHAPES THE GALLERY USES.
     *
     * A catalogue is a wall of thumbnails with words under them, which is
     * exactly what the gallery's layouts are for — and the app's layout
     * button now drives any lens that names them. Everything behind these
     * two lines is inherited from Lens.
     */
    layouts: root.pictureLayouts
    /// Per board: /wg/ wants big tiles, /a/ wants a contact sheet.
    layoutContext: root.board
    // ── navigation ───────────────────────────────────────────────────────────
    onOpened: root.loadBoards()
    onBackRequested: root.back()
    /*
     * The viewer is about ONE post on ONE screen. The rail is still live behind
     * it, so picking another board (or another reading of this thread) would
     * otherwise leave it open over a screen its post no longer belongs to —
     * with its file url rebuilt from the NEW board, which is a 404.
     */
    onBoardChanged: root.closeViewer()
    onScreenChanged: root.closeViewer()
    /// Where this screen lives on the site itself. The property is the Lens
    /// base's — every lens has one, and the host offers it as a row.
    siteUrl: {
        if ((root.screen === "thread" || root.screen === "images") && root.board.length > 0)
            return `https://boards.4chan.org/${root.board}/thread/${root.threadNo}`;

        if (root.screen === "catalog" && root.board.length > 0)
            return `https://boards.4chan.org/${root.board}/catalog`;

        return "https://boards.4chan.org/";
    }
    // What the app's ⋮ offers while this lens is open. Rows that cannot act on
    // this screen are left out rather than greyed: a lens contributes to the
    // app's own menu, and a dead row there reads as the app being broken.
    menuItems: {
        const here = root.screen === "thread" || root.screen === "images" ? "this thread" : root.screen === "catalog" ? `/${root.board}/` : "boards";
        const rows = [{
            "label": "Refresh",
            "icon": "refresh",
            "hint": here,
            "trigger": () => {
                return root.refresh();
            }
        }];
        if (root.screen === "thread")
            rows.push({
            "label": "See the pictures as a wall",
            "icon": "grid_view",
            "hint": `${root.threadImages.length}`,
            "trigger": () => {
                return root.showImages();
            }
        });

        if (root.screen === "images")
            rows.push({
            "label": "Back to the conversation",
            "icon": "forum",
            "hint": `${root.posts.length} posts`,
            "trigger": () => {
                return root.screen = "thread";
            }
        });

        rows.push({
            "label": "Open the real site here",
            "icon": "public",
            "hint": here,
            "trigger": () => {
                return root.showSite();
            }
        });
        rows.push({
            "label": "Copy the link to this page",
            "icon": "link",
            "trigger": () => {
                return Sys.copyText(root.siteUrl, (ok) => {
                    return ok ? Toast.show("Link copied") : Toast.error("Could not copy — " + Sys.lastError);
                });
            }
        });
        if (root.screen === "thread" || root.screen === "images")
            rows.push({
            "label": "Take every picture here",
            "icon": "library_add",
            "hint": "into the catalogue",
            "trigger": () => {
                return root.addThread();
            }
        });

        if (root.hiddenCount > 0 && root.screen !== "boards")
            rows.push({
            "label": `Show what you hid on /${root.board}/`,
            "icon": "visibility",
            "hint": String(root.hiddenCount),
            "trigger": () => {
                return root.unhideAll();
            }
        });

        return rows;
    }
    shortcuts: [{
        "sequence": "Ctrl+Shift+4",
        "action": () => {
            return Lenses.activeId === root.lensId ? Lenses.close() : Lenses.open(root.lensId);
        }
    }]
}
