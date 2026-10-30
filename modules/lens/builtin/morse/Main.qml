import QtQuick
import "fmt.js" as Fmt
import qs.modules.lens
import qs.services

/*
 * THE MORSE LENS — somebody's Telegram, read through quarry.
 *
 * Three screens: the chats you are in, one conversation, and — the reason this
 * exists inside a picture application — every picture and clip in a chat as a
 * WALL. A photograph somebody sent you two years ago is in the same catalogue
 * as a wallhaven wallpaper the moment you keep it, and until you do it is not
 * in the catalogue at all.
 *
 * READ-ONLY, AND MEANT IT. Wire.qml holds the list of methods this lens may
 * call and refuses everything else, so nothing here can send a message, react,
 * join, delete, or move read state on the account. `chats.open` is on that
 * forbidden list too: it tells Telegram the chat is on screen. The cost is that
 * this lens does not receive live messages — it refreshes when you ask it to,
 * which is what a reader does anyway.
 *
 * This file is the STATE; skins/ draws it. Same split as the 4chan lens, for
 * the same reason.
 *
 * Named for the client it reads: Morse, the user's own Telegram.
 * outside the manifest.
 */
Lens {
    // ── the wall ─────────────────────────────────────────────────────────────
    //     * ONE SERVER-SIDE QUESTION, NOT A SIEVE OVER WHAT IS LOADED.
    //     *
    //     * "Every picture in this chat" is `search.messages` with an empty query and
    //     * a filter, which Morse's protocol documents as a question in its own
    //     * right. Filtering the fifty messages a client happens to hold would answer
    //     * "the pictures among the last fifty" while looking like it answered the
    //     * real question.
    //     *
    //     * THE FILTER NAMES ARE A FIXED LIST because an unknown one does not fail —
    //     * measured against both backends, it silently returns the WHOLE chat. A
    //     * typo would put every message on a wall meant for pictures.
    //     * THE WALL HAS SHAPES, LIKE THE REST OF THE APP.
    //     *
    //     * Quarry's gallery lets you pick how the pictures are laid out; this wall
    //     * was one fixed grid of 200px squares whatever was in it. A chat of
    //     * screenshots wants big cells, a chat of a thousand stickers wants small
    //     * ones, and a list is the right shape when the names matter more than the
    //     * pictures. Remembered with the filter, in the lens's own settings.
    //     * THE SAME LAYOUTS THE GALLERY HAS, BY THE SAME NAMES.
    //     *
    //     * This wall had shapes of its own invention — Small, Medium, Large, List —
    //     * which meant learning a second vocabulary for one idea. Quarry already
    //     * has four ways of laying pictures out and people already know which one
    //     * they want; a lens is a different SOURCE, not a different app. Same ids,
    //     * same labels, same icons as the layout menu.
    //     * `fromId` is exclusive and the answer is newest first, so paging upward is
    //     * "everything before the oldest one I hold" and the two lists are joined at
    //     * the top, not merged.
    //     * A SHORT PAGE IS NOT THE TOP OF A CHAT.
    //     *
    //     * This used to stop paging the moment a page came back with fewer rows than
    //     * it asked for — and TDLib does that constantly: it answers from whatever
    //     * it has cached and fetches the rest in the background, so a chat with ten
    //     * years in it would hand over twenty messages, get called finished, and
    //     * never load another. Which is exactly what "it only loads a few" is.
    //     *
    //     * The real end of a chat is an answer with NOTHING in it, twice: once can
    //     * still be a cold cache. Everything else is worth asking again for.
    // ── files ────────────────────────────────────────────────────────────────
    //     * A thumbnail arrives as a local path already; the file itself has to be
    //     * asked for. `file.download` answers with the finished file and is
    //     * idempotent, so asking twice costs nothing — but a second ask while the
    //     * first is in flight would, which is what `_filePending` is for.
    //     * A WALL OF TWO HUNDRED TILES IS NOT TWO HUNDRED DOWNLOADS AT ONCE.
    //     *
    //     * Every tile asked for its thumbnail the instant it was drawn, so opening
    //     * a chat's pictures fired a couple of hundred `file.download` calls in one
    //     * breath. TDLib serialises them, the slow ones time out, and a timeout was
    //     * remembered as a failure FOR EVER — which is the wall of grey squares
    //     * that never fill in no matter how long you look at it.
    //     *
    //     * So: a queue with a small number in flight, newest ask first (what you
    //     * are looking at now beats what you scrolled past), and a failure that
    //     * expires so the next pass tries again instead of giving up for good.
    //     * SIXTEEN, NOT SIX — these are thumbnails.
    //     *
    //     * A chat thumbnail is a few kilobytes, and TDLib downloads them in
    //     * parallel perfectly happily; the small number here was sized for whole
    //     * videos. It is the wall's speed limit, so it is the wall's number:
    //     * sixteen fills a screen in one round trip's worth of time instead of
    //     * three, and is still bounded so scrolling a thousand-picture chat cannot
    //     * become a thousand open requests.
    // ── into quarry ──────────────────────────────────────────────────────────
    //     * KEPT MEANS COPIED.
    //     *
    //     * Morse's cache is swept on a timer — its own protocol says so, least
    //     * recently opened first — so adopting the file where it lies would give the
    //     * catalogue a row that points at nothing a week later. The file is copied
    //     * into quarry's own lens cache first and the copy is what is adopted.
    //     *
    //     * The key is `uniqueId`, Telegram's own name for a file: the same clip
    //     * forwarded into three chats is one picture, and keeping it twice would
    //     * make it two rows.
    //     * The thumbnail, which is usually already a file:// URL on this machine.
    //     *
    //     * When it is not, `thumbFileId` is how it is asked for — Telegram has
    //     * simply never fetched it. Without this a video's cell and an animated
    //     * sticker's cell are permanently blank rather than briefly empty.
    //     * THE REAL THUMBNAIL, WITH THE TINY ONE AS A STAND-IN — NOT INSTEAD OF IT.
    //     *
    //     * `media.thumb` is Telegram's minithumbnail: a base64 blob about thirty
    //     * pixels across, meant to be shown for the half-second before the real
    //     * thumbnail arrives. This returned it and stopped, so a tile that had one
    //     * NEVER asked for anything better — which is why a wall of pictures looked
    //     * like a wall of smudges no matter how long you waited. It was not a blur
    //     * setting; it was a thirty-pixel image stretched across two hundred.
    //     *
    //     * Now the real file wins as soon as it is here, the download is started
    //     * the first time a tile is drawn, and the minithumbnail fills the gap in
    //     * between — which is the job it was sent for.
    //     * JUST the minithumbnail — the thirty-pixel blob that travelled with the
    //     * message, never a file. `thumbOf` hands back the best picture it has,
    //     * which is what a picture layer wants; the blur underneath wants this one
    //     * specifically, and wants it to stay put while better ones arrive on top
    //     * (see Shot.qml).
    // ── the rail ─────────────────────────────────────────────────────────────
    //     * The rail becomes the chat list while this lens is open, which is exactly
    //     * what a Telegram window puts down the left-hand side. The open chat's two
    //     * readings — the conversation and its pictures — sit above it, so the wall
    //     * is one click from anywhere rather than a button on one screen.
    // ── the app's ⋮ ──────────────────────────────────────────────────────────
    //     * Only while this lens is the one on screen, and never carrying a chat's
    //     * name: the app collects these rows from EVERY live lens, so a title here
    //     * is a title in the overflow menu of whatever else is open.
    // Also the last one chosen anywhere, which is what a chat
    // with no choice of its own should open as.
    // A chat changing is a reason to re-sort the list, not to re-read a
    // conversation somebody is in the middle of — and not a reason to do
    // anything at all for a lens nobody has opened.
    //         * LIVE, THE WAY A MESSENGER IS.
    //         *
    //         * The lens listened for one event — a chat changed, and only while the
    //         * chat LIST was on screen. So an open conversation never grew: a
    //         * message arriving while you were reading did nothing until you left
    //         * and came back, which is not how any client behaves and is not what a
    //         * reader is for. morsed has been sending all of this from the start.
    // A chat is private: the catalogue says where it came from and
    // not who said it.
    /*
                 * MARKED ADULT BY DEFAULT.
                 *
                 * A chat carries no rating, and `false` is a guess in the
                 * direction that puts somebody's private photograph into a
                 * default search and onto the export ladders. Marked, it is
                 * still there and still searchable — quarry's own blur and
                 * hide settings simply have something to act on. One row in
                 * the menu turns it off.
                 */
    /*
     * IT MOVES WHERE IT SITS.
     *
     * A clip in a conversation plays inline, muted and looping, the way
     * Telegram itself draws one — a still with a badge is a video you have to
     * ask twice for. Two bounds, and neither is optional on a real account:
     *
     *   WHAT IS FETCHED — a GIF or a video note is small by construction and is
     *   always fetched. A plain video only up to `autoplayMaxBytes`; above it
     *   the poster and the badge stay and a tap downloads it, which is what
     *   this did before.
     *
     *   WHAT IS PLAYED — the PROXY, never the original. `fileId` is the size
     *   the daemon picked for a conversation to draw (no taller than 480) and
     *   it starts sooner for the same bytes; `originalFileId` is what the
     *   viewer and the catalogue take.
     *
     * Only a clip that is ON SCREEN is ever asked for: the skins call
     * `playFile` from inside their own visibility test, so scrolling past a
     * year of a group chat downloads nothing.
     */
    // The chat's own photo, which morsed has already written to
    // disk — sixty rows of identical glyphs is a rail you read
    // instead of a rail you recognise.
    //     * PER CHAT, AND REMEMBERED.
    //     *
    //     * One global shape was wrong for the same reason one global filter would
    //     * be: the chat of screenshots wants big cells and the chat of a thousand
    //     * stickers wants small ones, and you set that once per chat rather than
    //     * every time you open one. The map is keyed by chat id, and a chat you
    //     * have never chosen for falls back to the last shape you picked anywhere.
    //     * The wall's shape, inherited. Morse's skins have called it `wallLayout`
    //     * since the wall was built; the choosing, the per-chat memory and the
    //     * setter now live in Lens, so this is one name pointing at one model
    //     * rather than a second copy of it.

    id: root

    readonly property string brand: "Morse"
    // ── where you are ────────────────────────────────────────────────────────
    /// "chats" · "chat" · "media"
    property string screen: "chats"
    property var chats: []
    property bool chatsDone: false
    property var folders: []
    property string folderId: root.settings.folderId ? String(root.settings.folderId) : ""
    property bool loadingChats: false
    property string errorText: ""
    property var chat: null
    readonly property string chatId: root.chat ? String(root.chat.id) : ""
    readonly property string chatTitle: root.chat ? String(root.chat.title || "Chat") : ""
    /*
     * NOTHING LEAVES A SECRET CHAT.
     *
     * End-to-end, often set to destroy itself, and Morse's own rules say a
     * client must never quietly treat one as an ordinary chat. Reading it here
     * is reading it; copying a picture out of it into a permanent catalogue row
     * that then feeds a wallpaper and an avatar exporter is not. So it is
     * readable and nothing in it can be kept, exported or copied.
     */
    readonly property bool chatIsSecret: root.chat ? String(root.chat.kind || "") === "secret" : false
    readonly property bool chatIsMock: wire.mock
    /// NEWEST FIRST, exactly as the daemon answers. The view is laid out bottom
    /// to top, so index 0 sits at the bottom and the conversation reads the
    /// right way round without anything being reversed or re-sorted.
    property var messages: []
    /*
     * THREADS — a forum chat's top level is a list of topics, not a wall.
     *
     * morsed has had `topics.list` and `topics.history` all along; this lens
     * simply never asked for them, so a forum group opened as one flat stream
     * with every topic interleaved, which is unreadable and is not what the
     * chat is. `thread` is the topic being read, "" for the chat itself.
     */
    property var topics: []
    property bool loadingTopics: false
    property string thread: ""
    property string threadTitle: ""
    property bool loadingMessages: false
    property bool atTop: false
    property string chatFilter: "" // what is typed in "Find a chat"
    /// What is kept from a chat is marked adult unless you say otherwise; see
    /// the `adopt` call in `take`.
    readonly property bool markAdult: root.settings.markAdult !== false
    /*
     * ON UNLESS TURNED OFF — AND THE REASON IT USED TO BE OFF IS FIXED.
     *
     * This was opt-in, and the comment here recorded why: started bare, morsed
     * comes up on the FIXTURE backend with no credentials, publishes the
     * endpoint file that Morse's own client also reads, and that client then
     * talks to it — the user's login answered "invalid auth token", because
     * they were signing in to a daemon with no account behind it. A real
     * incident, and a good reason to refuse.
     *
     * The refusal cost the thing the lens is for, though: opened on a machine
     * where Morse was installed but not running, it said "Morse isn't running
     * — start it and this fills itself in", started nothing, and filled
     * nothing in. Ever. That is what this looked like from the outside.
     *
     * What changed is HOW it starts: through Morse's own launcher with
     * `--daemon`, which sets the backend, the database key and the path to
     * libtdjson exactly as Morse does, and opens no window (see Wire's
     * launchScript). A daemon started that way is the same daemon Morse's own
     * client would have started, so the incident above cannot happen.
     *
     * The bare binary is still never started automatically — only when
     * somebody presses Start, which is a person taking that decision.
     */
    readonly property bool autostart: root.settings.autostart !== false
    readonly property bool autoplay: root.settings.autoplay !== false
    readonly property int autoplayMaxBytes: 12 * 1024 * 1024
    /*
     * HOW MANY PLAYERS EXIST RIGHT NOW.
     *
     * A number rather than a promise: "only what is on screen plays" is
     * exactly the kind of claim that quietly stops being true, and this is
     * what a probe reads to check it (`app lensRead morse playersLive`).
     */
    property int playersLive: 0
    /*
     * WHAT THE LIST SHOWS.
     *
     * With nothing typed, the chats the daemon gave us. With something typed,
     * what the SERVER found: filtering the sixty in hand would answer "the
     * matches among the sixty" while looking like it answered "the matches",
     * so a chat you talk to weekly appears not to exist. Morse's protocol says
     * this twice and quarry's own Dispatch already does it this way.
     */
    property var foundChats: []
    property bool searchingChats: false
    readonly property var visibleChats: root.chatFilter.trim().length > 0 ? root.foundChats : root.chats
    property Timer _chatSearch
    readonly property var wallFilters: [{
        "id": "photoAndVideo",
        "label": "Pictures & video",
        "icon": "photo_library"
    }, {
        "id": "photo",
        "label": "Photos",
        "icon": "image"
    }, {
        "id": "video",
        "label": "Video",
        "icon": "movie"
    }, {
        "id": "animation",
        "label": "GIFs",
        "icon": "gif"
    }, {
        "id": "document",
        "label": "Files",
        "icon": "attach_file"
    }]
    property string wallFilter: root.settings.wallFilter ? String(root.settings.wallFilter) : "photoAndVideo"
    readonly property var wallLayouts: [{
        "id": "wall",
        "label": "Wall",
        "icon": "view_quilt",
        "hint": "real shapes",
        "cell": 240
    }, {
        "id": "grid",
        "label": "Grid",
        "icon": "grid_view",
        "hint": "even tiles",
        "cell": 200
    }, {
        "id": "sheet",
        "label": "Contact sheet",
        "icon": "apps",
        "hint": "hundreds",
        "cell": 112
    }, {
        "id": "compact",
        "label": "Compact",
        "icon": "view_list",
        "hint": "the facts",
        "cell": 0
    }]
    readonly property string wallLayout: root.layout
    readonly property int wallCell: root.layoutCell
    property var media: []
    /*
     * ALBUMS — several pictures posted as ONE thing.
     *
     * Telegram lets somebody send four photographs in a single act, and every
     * client draws them as one mosaic, because four bubbles claim they are four
     * separate things somebody said. The wire has carried `albumId` all along;
     * this wall ignored it and laid every frame out as its own square, so an
     * album of eight arrived as eight identical-looking cells.
     *
     * The grouping is consecutive, deliberately: an album IS contiguous in a
     * chat, and matching across the whole list would fuse two different albums
     * that happen to share an id after a re-send.
     */
    readonly property var mediaGrouped: {
        const out = [];
        let current = null;
        for (const message of root.media) {
            const album = message && message.albumId ? String(message.albumId) : "";
            if (album.length > 0 && current && current.album === album) {
                current.items.push(message);
                continue;
            }
            current = {
                "album": album,
                "items": [message],
                "lead": message
            };
            out.push(current);
        }
        return out;
    }
    property string mediaNext: ""
    property bool loadingMedia: false
    readonly property bool hasMore: root.wallFallback ? !root.scanDone : root.mediaNext.length > 0
    // ── plumbing ─────────────────────────────────────────────────────────────
    property Wire _wire
    // Facts about the link, not the link itself: a skin can come from a pack,
    // and the socket it would otherwise reach carries a token and a whitelist.
    readonly property bool linkReady: wire.ready
    readonly property string linkReason: wire.reason
    readonly property string linkState: wire.state
    /// What the autostart is doing — for `app lensRead morse linkStart`.
    readonly property string linkStart: `${wire._noDaemon ? "missing" : wire._starting ? "starting" : "idle"}${wire._lastStart.length > 0 ? " · " + wire._lastStart : ""}`
    readonly property bool mock: wire.mock
    /*
     * The detail under the reason — for a person, not for a probe.
     *
     * `linkStart` above is the diagnostic string and reads like one. This is
     * the one line worth putting on a screen, and only when something has
     * actually gone wrong: a daemon that could not be found, or a launcher
     * that refused. A daemon that simply has not been started yet needs no
     * explanation, it needs the button.
     */
    readonly property string linkDetail: {
        if (wire.state !== "absent")
            return "";

        if (wire._noDaemon)
            return "Install Morse, or point quarry at its morsed in settings.";

        const last = String(wire._lastStart || "");
        return last.indexOf("failed") >= 0 || last.indexOf("could not") >= 0 ? last : "";
    }
    readonly property bool fetching: root.loadingChats || root.loadingMessages || root.loadingMedia
    property Timer _chatDebounce
    /*
     * LINKS, THE WAY THE REAL CLIENT TREATS THEM.
     *
     * A `t.me/…` in a message is not a web page: it is a chat, a post or an
     * invite, and opening it in a browser is the one thing nobody wants. So it
     * is resolved through morsed — which says what it points at — and then
     * opened here. An invite that you are not in offers to join, because that
     * is what the link is FOR; everything else that is not Telegram goes to
     * quarry's own browser.
     *
     * Joining is the one thing this lens does that writes. It is never
     * automatic: it happens when you press it.
     */
    property string pendingInvite: ""
    property string inviteTitle: ""
    // What morsed already sends with an invite and the question never showed.
    property string invitePhoto: ""
    property int inviteMembers: 0
    /// Set for a public chat you are not in: it can be opened without joining.
    property string inviteChatId: ""
    property int _emptyPages: 0
    /*
     * AN OLDER MORSE CANNOT BE ASKED THIS QUESTION.
     *
     * "Every picture in this chat" is a filter with no words, and a daemon from
     * before that was written answers INVALID_PARAMS: missing query. Measured
     * against two builds on this machine — the newer one answers it, the older
     * one refuses. So the refusal is caught once and the wall falls back to
     * walking the history and keeping what carries media.
     *
     * That is a DIFFERENT question — "the pictures among the last N messages",
     * not "the pictures" — so the screen says so rather than quietly showing
     * less than it claims.
     */
    property bool wallFallback: false
    property int scanned: 0
    /// How far back the fallback will walk before it stops and says so.
    readonly property int scanLimit: 5000
    property string _scanFrom: ""
    property bool scanDone: false
    readonly property var _kindsFor: ({
        "photoAndVideo": ["photo", "video"],
        "photo": ["photo"],
        "video": ["video"],
        "animation": ["animation"],
        "document": ["document"]
    })
    property var files: ({
    })
    // fileId -> file:// path
    property var _filePending: ({
    })
    property int fileRevision: 0
    property int fetchRevision: 0
    property var _fileFailed: ({
    })
    readonly property int retryMs: 20000
    readonly property int maxFileFetches: 16
    property int _fetchesInFlight: 0
    property var _fetchQueue: []
    readonly property int fileRetryMs: 20000
    // ── looking at one ───────────────────────────────────────────────────────
    property var viewing: null
    /*
     * AN ALBUM IS ONE THING WITH SEVERAL PICTURES IN IT.
     *
     * Four photographs sent together are one act — the wall draws them as one
     * cell, which is right — but opening that cell used to show the first one
     * and then page out into every other picture in the chat. The other three
     * were reachable only by pressing next and recognising them as you went
     * past, and nothing said how many there were or that you had left.
     *
     * So the viewer scopes to the album while you are inside one: next and
     * previous walk its frames, the strip along the bottom is the album, and
     * the count is "2 of 4" rather than "2 of nine hundred". Stepping off
     * either end leaves the album and carries on through the chat — see
     * `viewerStep` — so scoping takes nothing away.
     */
    readonly property var viewerAlbum: root.viewing ? root.albumOf(root.viewing) : null
    readonly property var viewerAll: root.screen === "media" ? root.media : root.messages.filter((m) => {
        return m && m.media;
    })
    readonly property var viewerList: root.viewerAlbum && root.viewerAlbum.items.length > 1
        ? root.viewerAlbum.items : root.viewerAll
    readonly property int viewerIndex: {
        if (!root.viewing)
            return -1;

        for (let i = 0; i < root.viewerList.length; i++) if (String(root.viewerList[i].id) === String(root.viewing.id)) {
            return i;
        }
        return -1;
    }
    property var added: ({
    })
    // uniqueId -> catalogue id
    property var addedItems: ({
    })
    // uniqueId -> the row itself
    property int busyCount: 0
    property int bulkTotal: 0
    property int bulkDone: 0
    /// Attempts and successes are different numbers — a file that had not
    /// arrived is stepped over, and saying "60 kept" when twelve were kept is
    /// the kind of lie that is found out later.
    property int bulkKept: 0
    property bool bulkCancelled: false
    readonly property bool bulkRunning: root.bulkTotal > 0 && root.bulkDone < root.bulkTotal
    /// One retry for a file that was still downloading when its turn came.
    property Timer _fileWait

    /*
     * THE STORED "OFF" PREDATES THE FIX, SO IT IS LIFTED ONCE.
     *
     * Flipping the default above fixes nothing for anyone who already has
     * this lens: `autostart: false` is written into their saved settings,
     * an explicit answer that a default cannot override — and it was written
     * by a version where starting the daemon really was the wrong thing to
     * do. So the first run of this version clears it and marks that it has
     * done so, exactly once. Somebody who turns it off AFTER this keeps it
     * off, because `autostartReviewed` is already true by then.
     */
    function _reviewAutostart() {
        if (!root.settings || root.settings.autostartReviewed === true)
            return ;

        const next = {
        };
        for (const k in root.settings) next[k] = root.settings[k]
        next.autostart = true;
        next.autostartReviewed = true;
        root.saveSettings(next);
    }

    /*
     * "START MORSE", PRESSED BY A PERSON.
     *
     * The automatic attempt is rate-limited to one every thirty seconds and
     * latches when it finds nothing to start — both right for a timer that
     * runs by itself, both wrong for somebody who has just installed Morse
     * and pressed a button. A press clears the guard and the latch: it is a
     * fresh instruction, not a repeat of the last one.
     */
    function startLink() {
        wire._noDaemon = false;
        wire._startedAt = 0;
        wire.ensureRunning(true);
        wire.retry();
    }

    function setAutostart(on) {
        const next = {
        };
        for (const k in root.settings) next[k] = root.settings[k]
        next.autostart = !!on;
        root.saveSettings(next);
    }

    function setAutoplay(on) {
        const next = {
        };
        for (const k in root.settings) next[k] = root.settings[k]
        next.autoplay = !!on;
        root.saveSettings(next);
    }

    /// Whether this file is one autoplay may fetch by itself.
    function autoFetches(media) {
        if (!media)
            return false;

        const kind = String(media.kind || "");
        if (kind === "animation" || kind === "videoNote")
            return true;

        if (kind !== "video")
            return false;

        const size = Number(media.size) || 0;
        // An unknown size is not a small one.
        return size > 0 && size <= root.autoplayMaxBytes;
    }

    /// The file a conversation should PLAY, "" until it is here. Asks for it
    /// only when the bounds above allow.
    function playFile(message) {
        const media = message ? message.media : null;
        if (!media || !media.fileId || !root.autoplay)
            return "";

        const id = String(media.fileId);
        if (root.fileRevision < 0)
            return "";

        // a dependency, not dead code — see heldFile
        const held = root.files[id];
        if (held !== undefined)
            return held;

        if (!root.autoFetches(media))
            return "";

        const failedAt = root._fileFailed[id];
        if (failedAt !== undefined && Date.now() - failedAt < root.retryMs)
            return "";

        if (!root._filePending[id]) {
            root._filePending[id] = true;
            Qt.callLater(() => {
                return root._download(id);
            });
        }
        return "";
    }

    function playerOpened() {
        root.playersLive++;
    }

    function playerClosed() {
        root.playersLive = Math.max(0, root.playersLive - 1);
    }

    /*
     * A SCREEN AHEAD, IN ONE ASK.
     *
     * `file.prefetch` is morsed's own "you will want this shortly" — cheaper
     * than a download because it does not wait for the bytes, and it warms
     * TDLib's queue in the order the wall will actually need them. The wall
     * calls this as it scrolls, so the next screen is usually already there
     * when it arrives rather than starting to fetch when it does.
     */
    function prefetchThumbs(messages) {
        if (!wire.ready || !messages || messages.length === 0)
            return ;

        let asked = 0;
        for (const message of messages) {
            const media = message ? message.media : null;
            const id = media && media.thumbFileId ? String(media.thumbFileId) : "";
            if (id.length === 0 || root.files[id] !== undefined || root._filePending[id])
                continue;

            wire.call("file.prefetch", {
                "fileId": id,
                "urgent": false
            }, function() {
            });
            asked++;
            // A bounded ask: a scroll that flings through a thousand rows must
            // not turn into a thousand calls in one frame.
            if (asked >= 24)
                return ;

        }
    }

    /// What a skin draws over a clip that autoplay will not fetch by itself.
    function tooBigToAutoplay(message) {
        const media = message ? message.media : null;
        if (!media || !root.autoplay)
            return false;

        return String(media.kind || "") === "video" && !root.autoFetches(media);
    }

    function setMarkAdult(on) {
        const next = {
        };
        for (const k in root.settings) next[k] = root.settings[k]
        next.markAdult = !!on;
        root.saveSettings(next);
    }

    function searchChats() {
        const text = root.chatFilter.trim();
        if (text.length === 0) {
            root.foundChats = [];
            root.searchingChats = false;
            return ;
        }
        if (!wire.ready)
            return ;

        root.searchingChats = true;
        wire.call("search.global", {
            "query": text,
            "limit": 30
        }, function(err, result) {
            root.searchingChats = false;
            if (err || !result) {
                root.foundChats = [];
                return ;
            }
            // `search.global` answers with messages too. They are dropped
            // unread — this screen asked about chats.
            root.foundChats = Array.isArray(result.chats) ? result.chats : [];
        });
    }

    /// Kept because the skins call it; the model behind it is Lens's.
    function setWallLayout(id) {
        root.setLayout(id);
    }

    /// Where a message sits in its album, for the viewer's own caption.
    function albumOf(message) {
        if (!message || !message.albumId)
            return null;

        const album = String(message.albumId);
        for (const group of root.mediaGrouped) if (group.album === album && group.items.indexOf(message) >= 0) {
            return group;
        }
        return null;
    }

    function _onEvent(name, data) {
        if (name === "file.progress" && data) {
            // The finished file, and only the finished file: `prefixPath` is a
            // part-written one, and a picture drawn from that is half a picture.
            if (data.path && data.path.length > 0)
                root._fileLanded(String(data.fileId), String(data.path));
            else if (root._streamWanted[String(data.fileId)] && data.prefixPath && Number(data.prefixOffset || 0) === 0)
                root._partialArrived(String(data.fileId), data);

            return ;
        }
        if (name === "message.new" && data && data.message) {
            const message = data.message;
            if (String(message.chatId) === root.chatId && root.screen === "chat") {
                // The topic you are reading, when you are reading one: a
                // forum's other topics must not appear in the middle of this.
                const topic = String(message.topicId || "");
                if (root.thread.length === 0 || topic === root.thread) {
                    // Newest first — index 0 is the bottom of the view.
                    const already = root.messages.some((m) => {
                        return String(m.id) === String(message.id);
                    });
                    if (!already)
                        root.messages = [message].concat(root.messages);

                }
            }
            // The list reorders and its counts change on every message, in
            // every chat — debounced, because a busy account sends a lot.
            chatDebounce.restart();
            return ;
        }
        if (name === "message.deleted" && data) {
            const gone = {
            };
            for (const id of (data.messageIds || data.ids || [])) gone[String(id)] = true
            if (Object.keys(gone).length > 0)
                root.messages = root.messages.filter((m) => {
                return !gone[String(m.id)];
            });

            return ;
        }
        if (name === "topic.updated" && root.chatId.length > 0) {
            root.loadTopics();
            return ;
        }
        if (name === "folders.updated") {
            root.loadFolders();
            return ;
        }
        if (name === "chat.updated" && root.isOpen)
            chatDebounce.restart();

    }

    /*
     * WHERE YOU HAVE BEEN, not which rung of a ladder you are on.
     *
     * Back used to be a fixed order — viewer, then media, then chat, then the
     * list — which is right only if you arrived the way it assumes. Follow a
     * link from one chat into another and back took you to the LIST, throwing
     * away the chat you were reading and the place you were in it. The deeper
     * you went the more wrong it was.
     *
     * So it is a stack of the places you actually visited. Each entry is the
     * whole position — which chat, which topic, which screen, and where the
     * view was scrolled to — because arriving back at the right chat at the
     * wrong end of it is barely better than not arriving.
     */
    property var _trail: []

    /// Where we are now, in a form `_goTo` can put back.
    function _here() {
        return {
            "screen": root.screen,
            "chatId": root.chatId,
            "thread": root.thread,
            "threadTitle": root.threadTitle,
            "layout": root.wallLayout
        };
    }

    /// Remember this place before leaving it. Called by whatever is about to
    /// move you, so nothing has to remember to do it afterwards.
    function _leave() {
        if (root._restoring || root.screen === "chats")
            return ;

        const trail = root._trail.slice();
        trail.push(root._here());
        // Deep enough for any plausible chain of links, shallow enough that it
        // is never the thing holding a conversation in memory.
        if (trail.length > 24)
            trail.shift();

        root._trail = trail;
    }

    property bool _restoring: false

    function _goTo(place) {
        if (!place)
            return ;

        root._restoring = true;
        if (place.layout && place.layout !== root.wallLayout)
            root.setLayout(place.layout);

        if (place.screen === "chats") {
            root.showChats();
        } else if (String(place.chatId) !== root.chatId) {
            root.thread = place.thread || "";
            root.threadTitle = place.threadTitle || "";
            root.openChat(String(place.chatId));
            root.screen = place.screen;
        } else {
            root.screen = place.screen;
        }
        root._restoring = false;
    }

    function back() {
        if (root.viewing !== null) {
            root.closeViewer();
            return ;
        }
        /*
         * The media screen is a view OF the chat you are in, not a place you
         * travelled to, so it steps back to that chat rather than popping the
         * trail — otherwise looking at a chat's pictures would cost you the
         * chat you came from.
         */
        if (root.screen === "media") {
            root.screen = "chat";
            return ;
        }
        const trail = root._trail.slice();
        const place = trail.pop();
        if (!place) {
            root.showChats();
            return ;
        }
        root._trail = trail;
        root._goTo(place);
    }


    function showChats() {
        root.screen = "chats";
        root.chatFilter = "";
        // The list is the root of the trail: arriving here means there is
        // nowhere further back to go, and keeping the old trail would send
        // back into a chat you had already left.
        root._trail = [];
    }

    // quarryd itself is not what Morse talks to — morsed is — but the lens
    // still draws through quarry, and a refresh costs nothing when there is
    // nothing stale. See `reconnected` on Lens.
    onReconnected: root.refresh()

    function refresh() {
        if (root.screen === "media") {
            root.loadMedia(true);
        } else if (root.screen === "chat") {
            root.openChat(root.chatId);
        } else {
            root.loadFolders();
            root.loadChats();
        }
    }

    function loadFolders() {
        if (!wire.ready)
            return ;

        wire.call("folders.list", {
        }, function(err, result) {
            root.folders = (!err && result && Array.isArray(result.folders)) ? result.folders : [];
        });
    }

    function loadChats() {
        root.chatsDone = false;
        root._fetchChats(true);
    }

    /// The next page of the chat list. An account with more than sixty chats
    /// could otherwise only reach the first sixty, by any route.
    function loadMoreChats() {
        if (!root.chatsDone && !root.loadingChats && root.chatFilter.trim().length === 0)
            root._fetchChats(false);

    }

    function _fetchChats(fresh) {
        if (!wire.ready) {
            root.chats = [];
            return ;
        }
        root.loadingChats = true;
        root.errorText = "";
        const offset = fresh ? 0 : root.chats.length;
        wire.call("chats.list", {
            "limit": 60,
            "offset": offset,
            "folderId": root.folderId
        }, function(err, result) {
            root.loadingChats = false;
            if (err || !result || !Array.isArray(result.chats)) {
                root.errorText = err || "Morse gave no chats.";
                return ;
            }
            root.chatsDone = result.chats.length < 60;
            if (!fresh) {
                root.chats = root.chats.concat(result.chats);
                return ;
            }
            /*
             * A refresh is the first page again — and it runs on every message
             * in every chat. Replacing the list with it cut a list scrolled to
             * chat 150 back to 60, so you landed at the top. The fresh page
             * goes first (that is the new order) and the pages already loaded
             * stay under it.
             */
            const seen = {};
            for (const c of result.chats)
                seen[String(c.id)] = true;
            root.chats = result.chats.concat(root.chats.filter(c => !seen[String(c.id)]));
            if (root.chats.length > result.chats.length)
                root.chatsDone = false;
        });
    }

    function setFolder(id) {
        root.folderId = String(id || "");
        root.chats = [];
        root.loadChats();
        root._remember("folderId", root.folderId);
    }

    /// Small things the registry keeps for us: which tab, which filter.
    function _remember(key, value) {
        if (root.settings[key] === value)
            return ;

        const next = {
        };
        for (const k in root.settings) next[k] = root.settings[k]
        next[key] = value;
        root.saveSettings(next);
    }

    // ── one conversation ─────────────────────────────────────────────────────
    /*
     * `atMessage` starts the history at one message rather than at the newest.
     *
     * A `t.me/<name>/<id>` link names a message, not just a chat — it is how
     * anyone quotes a post — and this opened the chat at its newest message
     * and threw the id away. The link took you to the right room and then let
     * you look for the thing yourself, which in a busy channel is no answer.
     *
     * `messages.history` has always taken a `fromId` anchor; nothing new was
     * needed on the wire.
     */
    function openChat(id, atMessage) {
        const wanted = String(id);
        // Remember where we were BEFORE anything is cleared below — see `back`.
        if (wanted !== root.chatId)
            root._leave();

        const held = root.chatById(wanted);
        // Never the PREVIOUS chat: its id would be the one fetched, under the
        // new one's name.
        root.chat = held || {
            "id": wanted,
            "title": "",
            "kind": ""
        };
        root.screen = "chat";
        root.messages = [];
        root.atTop = false;
        root.media = [];
        root.mediaNext = "";
        root.wallFallback = false; // a refusal was about that call, not this one
        root.errorText = "";
        if (!held)
            wire.call("chats.get", {
            "chatId": wanted
        }, function(err, result) {
            if (!err && result && result.chat)
                root.chat = result.chat;

        });

        // Opening a chat leaves whatever topic you were in: a topic belongs to
        // the chat it is in, and carrying it across would page the wrong one.
        root.thread = "";
        root.threadTitle = "";
        root.topics = [];
        root._emptyPages = 0;
        root.loadHistory(atMessage ? String(atMessage) : "");
        // A forum's topics come alongside its messages rather than instead of
        // them: the chat still reads, and the topics are there to narrow it.
        if (root.chat && root.chat.isForum === true)
            root.loadTopics();

    }

    /*
     * `force` comes from a shift-click: straight to the system browser, past
     * both quarry's reader and Telegram's own handling. A t.me link resolved
     * inside the app is usually what you want — but not when you are trying to
     * open the thing in the browser you are logged into.
     */
    function openLink(url, force) {
        const target = String(url || "").trim();
        if (target.length === 0)
            return ;

        if (force) {
            root.openExternally(target, true);
            return ;
        }
        const telegram = /^(https?:\/\/)?(t\.me|telegram\.me|telegram\.dog)\//i.test(target) || target.indexOf("tg://") === 0;
        if (!telegram) {
            // A link out of somebody's message: your browser unless you
            // asked for quarry's window — see Lens.openExternally. NOT
            // `openLink`, which is this very function.
            root.openExternally(target, false);
            return ;
        }
        if (!wire.ready) {
            Toast.error("Morse is not connected");
            return ;
        }
        wire.call("links.resolve", {
            "url": target
        }, function(err, result) {
            const link = (!err && result) ? result.link : null;
            if (!link) {
                Toast.error(err || "Telegram would not say what that link is");
                return ;
            }
            /*
             * A link Telegram cannot route is not a link that quietly does
             * nothing. `reason` is sent for exactly this and was never read,
             * so a dead invite or a misspelt name looked identical to a click
             * that had not registered.
             */
            if (String(link.kind || "") === "unsupported") {
                Toast.error(String(link.reason || "Telegram cannot open that link"));
                return ;
            }
            // A chat you are already in opens; one you are not offers itself.
            // A public one you have not joined (member: false) asks too, and can still be just looked at.
            if (link.chatId && String(link.chatId).length > 0 && link.member !== false) {
                // At the message it names, when it names one.
                root.openChat(String(link.chatId), link.messageId || "");
                return ;
            }
            root.pendingInvite = target;
            root.inviteTitle = String(link.title || link.name || "that chat");
            root.invitePhoto = String(link.photo || "");
            root.inviteMembers = Number(link.members || 0);
            root.inviteChatId = link.member === false ? String(link.chatId || "") : "";
        });
    }

    function acceptInvite() {
        const link = root.pendingInvite;
        if (link.length === 0)
            return ;

        wire.call("links.join", {
            "url": link
        }, function(err, result) {
            root.pendingInvite = "";
            if (err || !result || !result.chatId) {
                Toast.error(err || "Telegram would not let us in");
                return ;
            }
            Toast.show(`Joined ${root.inviteTitle}`);
            root.loadChats();
            root.openChat(String(result.chatId));
        });
    }

    function declineInvite() {
        root.pendingInvite = "";
        root.inviteTitle = "";
        root.invitePhoto = "";
        root.inviteMembers = 0;
        root.inviteChatId = "";
    }

    /// Read a public chat without joining it, as before the question existed.
    function lookAtInvite() {
        const id = root.inviteChatId;
        root.declineInvite();
        if (id.length > 0)
            root.openChat(id);
    }

    function chatById(id) {
        for (let i = 0; i < root.chats.length; i++) if (String(root.chats[i].id) === String(id)) {
            return root.chats[i];
        }
        return null;
    }

    function loadHistory(fromId, threadId) {
        if (!wire.ready || root.loadingMessages || root.chatId.length === 0)
            return ;

        const topic = threadId === undefined ? root.thread : threadId;
        const older = fromId && fromId.length > 0;
        root.loadingMessages = true;
        // A topic is a chat inside a chat: same paging, same shape, one extra id.
        const method = topic && topic.length > 0 ? "topics.history" : "messages.history";
        const params = {
            "chatId": root.chatId,
            "fromId": fromId || "",
            "limit": 60
        };
        if (topic && topic.length > 0)
            params.topicId = topic;

        wire.call(method, params, function(err, result) {
            root.loadingMessages = false;
            if (err || !result || !Array.isArray(result.messages)) {
                root.errorText = err || "That conversation would not load.";
                return ;
            }
            if (result.messages.length === 0) {
                root._emptyPages++;
                root.atTop = root._emptyPages >= 2;
                return ;
            }
            root._emptyPages = 0;
            root.atTop = false;
            root.messages = older ? root.messages.concat(result.messages) : result.messages;
        });
    }

    /// A forum's topics, newest activity first. Answered by morsed, which has
    /// the forum flag on the chat and the list behind it.
    function loadTopics() {
        if (!wire.ready || root.loadingTopics || root.chatId.length === 0)
            return ;

        root.loadingTopics = true;
        wire.call("topics.list", {
            "chatId": root.chatId,
            "limit": 60
        }, function(err, result) {
            root.loadingTopics = false;
            if (err || !result || !Array.isArray(result.topics)) {
                // Not fatal: a chat that is not a forum simply has none, and
                // the conversation underneath is still perfectly readable.
                root.topics = [];
                return ;
            }
            root.topics = result.topics;
        });
    }

    /// Read one topic. The messages list is the topic's, and paging upward
    /// pages the topic — same call, one more id.
    function openThread(topic) {
        if (!topic)
            return ;

        root.thread = String(topic.id || topic.topicId || "");
        root.threadTitle = String(topic.title || topic.name || "Topic");
        root.messages = [];
        root.atTop = false;
        root._emptyPages = 0;
        root.loadHistory("", root.thread);
    }

    /// Back out of a topic to the forum's list of them.
    function closeThread() {
        if (root.thread.length === 0)
            return ;

        root.thread = "";
        root.threadTitle = "";
        root.messages = [];
        root.atTop = false;
        root._emptyPages = 0;
        root.loadHistory("", "");
    }

    function loadOlder() {
        if (root.atTop || root.loadingMessages || root.messages.length === 0)
            return ;

        // `fromId` is exclusive, so it is the oldest one held — the end of a
        // newest-first list.
        root.loadHistory(String(root.messages[root.messages.length - 1].id));
    }

    // ── the wall ─────────────────────────────────────────────────────────────
    function showMedia() {
        if (root.chatId.length === 0)
            return ;

        root.screen = "media";
        if (root.media.length === 0)
            root.loadMedia(true);

    }

    function setWallFilter(id) {
        // Only a name from the list: see wallFilters.
        for (let i = 0; i < root.wallFilters.length; i++) {
            if (root.wallFilters[i].id !== id)
                continue;

            root.wallFilter = id;
            root._remember("wallFilter", id);
            root.loadMedia(true);
            return ;
        }
    }

    function loadMedia(fresh) {
        if (!wire.ready || root.loadingMedia || root.chatId.length === 0)
            return ;

        if (root.wallFallback) {
            root._scanHistory(fresh);
            return ;
        }
        if (!fresh && !root.hasMore)
            return ;

        root.loadingMedia = true;
        wire.call("search.messages", {
            "query": "",
            "chatId": root.chatId,
            "fromId": fresh ? "" : root.mediaNext,
            "limit": 60,
            "filter": root.wallFilter
        }, function(err, result, code) {
            root.loadingMedia = false;
            if (err || !result || !Array.isArray(result.messages)) {
                /*
                 * The one refusal that has a second route: a daemon from
                 * before "a filter is a question on its own" rejects an empty
                 * query. Told apart by the protocol's CODE — a wording change
                 * upstream would otherwise switch this off silently, and an
                 * unrelated failure whose message happened to contain "query"
                 * would switch it on.
                 */
                if (code === "INVALID_PARAMS") {
                    root.wallFallback = true;
                    root._scanHistory(true);
                    return ;
                }
                root.errorText = err || "No answer for this chat's pictures.";
                return ;
            }
            // Anything without media is not for a wall — a filter the daemon
            // did not recognise answers with the whole chat, and this is the
            // second half of that guard.
            const rows = result.messages.filter((m) => {
                return m && m.media;
            });
            root.media = fresh ? rows : root.media.concat(rows);
            // Opaque. Passed back exactly as given; never parsed.
            root.mediaNext = String(result.nextFromId || "");
        });
    }

    /// One page of history at a time, keeping what carries media of the kind
    /// the wall is set to. Called again as the wall is scrolled.
    function _scanHistory(fresh) {
        if (fresh) {
            root.media = [];
            root.scanned = 0;
            root._scanFrom = "";
            root.scanDone = false;
        }
        if (root.scanDone || root.loadingMedia)
            return ;

        root.loadingMedia = true;
        wire.call("messages.history", {
            "chatId": root.chatId,
            "fromId": root._scanFrom,
            "limit": 80
        }, function(err, result) {
            root.loadingMedia = false;
            if (err || !result || !Array.isArray(result.messages)) {
                root.errorText = err || "That chat's history would not load.";
                root.scanDone = true;
                return ;
            }
            const page = result.messages;
            root.scanned += page.length;
            root.scanDone = page.length < 80;
            if (page.length > 0)
                root._scanFrom = String(page[page.length - 1].id);

            const kinds = root._kindsFor[root.wallFilter] || ["photo", "video"];
            const keep = page.filter((m) => {
                return m && m.media && kinds.indexOf(String(m.media.kind)) >= 0;
            });
            root.media = root.media.concat(keep);
            // A page of words only is not the end of the pictures — keep going
            // until something is found, the chat runs out, or this has read far
            // enough that carrying on would be a crawl nobody asked for.
            if (root.scanned >= root.scanLimit)
                root.scanDone = true;
            else if (keep.length === 0 && !root.scanDone && root.scanned % 400 !== 0)
                root._scanHistory(false);
        });
    }

    function miniOf(message) {
        const media = message ? message.media : null;
        if (!media)
            return "";

        return media.thumb && media.thumb.length > 0 ? String(media.thumb) : "";
    }

    /*
     * `thumbOf` without the stand-in: the real thumbnail if it is here, ""
     * if it is not — and it still asks for it. The picture layer wants this;
     * the thirty-pixel blob belongs to the blur underneath it.
     */
    function realThumbOf(message) {
        const best = root.thumbOf(message);
        return best.indexOf("data:") === 0 ? "" : best;
    }

    function thumbOf(message) {
        const media = message ? message.media : null;
        if (!media)
            return "";

        const id = media.thumbFileId ? String(media.thumbFileId) : "";
        const mini = media.thumb && media.thumb.length > 0 ? String(media.thumb) : "";
        if (id.length === 0)
            return mini;

        if (root.fileRevision >= 0) {
            const ready = root.files[id];
            if (ready !== undefined && ready.length > 0)
                return ready;

        }
        // Ask for the real one, then hand back the stand-in for this frame.
        const pending = root._filePending[id];
        const failedWhen = root._fileFailed[id];
        const retryable = failedWhen === undefined || Date.now() - failedWhen > root.fileRetryMs;
        if (!pending && retryable) {
            delete root._fileFailed[id];
            root._filePending[id] = true;
            Qt.callLater(() => {
                return root._download(id);
            });
        }
        if (mini.length > 0)
            return mini;

        return "";
    }

    /*
     * THE REAL FILE, FOR A PICTURE YOU ARE LOOKING AT.
     *
     * A bubble drew a thumbnail — at best a few hundred pixels, at worst the
     * thirty-pixel minithumbnail — and never asked for anything better, so a
     * conversation of photographs was a conversation of smudges. A photo is
     * small and you are looking straight at it, so the one on screen asks for
     * its own file; a video does not, because that is tens of megabytes for a
     * frame you have not pressed play on.
     */
    function wantFull(message) {
        const media = message ? message.media : null;
        if (!media || !media.fileId)
            return "";

        const id = String(media.fileId);
        if (root.fileRevision >= 0) {
            const held = root.files[id];
            if (held !== undefined)
                return held;

        }
        // Moving pictures and big documents stay on their thumbnail until
        // somebody opens them.
        const moving = String(media.kind || "") === "video" || String(media.kind || "") === "animation";
        const big = Number(media.size || 0) > 12 * 1024 * 1024;
        if (moving || big)
            return "";

        const failedAt = root._fileFailed[id];
        const retryable = failedAt === undefined || Date.now() - failedAt > root.fileRetryMs;
        if (!root._filePending[id] && retryable) {
            delete root._fileFailed[id];
            root._filePending[id] = true;
            Qt.callLater(() => {
                return root._download(id);
            });
        }
        return "";
    }

    /// The full file IF it is already here — never asks. What a list draws, so
    /// that scrolling past a hundred photographs does not download a hundred
    /// photographs.
    function heldFile(message) {
        const media = message ? message.media : null;
        if (!media || !media.fileId)
            return "";

        // The counter is READ so this re-runs when a file lands; it is a
        // dependency, not a leftover, and deleting it stops every picture in
        // the app from ever refreshing.
        if (root.fileRevision < 0)
            return "";

        const held = root.files[String(media.fileId)];
        return held !== undefined ? held : "";
    }

    /*
     * The full file for this message, "" until it is here. Asks for it once.
     *
     * `originalFileId` when there is one: a video's `fileId` is deliberately
     * the size a conversation should DRAW — the daemon substitutes a variant no
     * taller than 480 — so keeping or opening `fileId` would put the proxy in
     * the catalogue and call it the clip.
     */
    function fileOf(message) {
        const media = message ? message.media : null;
        if (!media || !media.fileId)
            return "";

        const id = String(media.originalFileId || media.fileId);
        if (root.fileRevision < 0)
            return "";

        // a dependency, not dead code — see heldFile
        const held = root.files[id];
        if (held !== undefined)
            return held;

        const failedAt = root._fileFailed[id];
        if (failedAt !== undefined && Date.now() - failedAt < root.retryMs)
            return "";

        if (!root._filePending[id]) {
            root._filePending[id] = true;
            // Deferred: a client that answers inside a binding writes the
            // counter that binding reads, and Qt abandons the binding.
            Qt.callLater(() => {
                return root._download(id);
            });
        }
        return "";
    }

    function isFetchingFile(message) {
        const media = message ? message.media : null;
        if (!media || !media.fileId)
            return false;

        if (root.fetchRevision < 0)
            return false;

        // a dependency, not dead code — see heldFile
        return root._filePending[String(media.fileId)] === true;
    }

    function _download(fileId) {
        if (root._fetchQueue.indexOf(fileId) < 0)
            root._fetchQueue.push(fileId);

        root._pumpFiles();
    }

    function _pumpFiles() {
        while (root._fetchesInFlight < root.maxFileFetches && root._fetchQueue.length > 0) {
            // The last asked for is the one on screen: a wall scrolls faster
            // than a download finishes, and the tiles above you are history.
            const fileId = root._fetchQueue.pop();
            root._fetchesInFlight++;
            root.fetchRevision++;
            wire.call("file.download", {
                "fileId": fileId
            }, function(err, result) {
                root._fetchesInFlight--;
                if (err || !result || !result.path) {
                    delete root._filePending[fileId];
                    // Remembered with a TIME, not as a verdict — see
                    // `thumbOf`, which asks again once it has aged out.
                    root._fileFailed[fileId] = Date.now();
                    root.fetchRevision++;
                    root.fileRevision++;
                    root._pumpFiles();
                    return ;
                }
                root._fileLanded(fileId, String(result.path));
                root._pumpFiles();
            });
        }
    }

    /*
     * WHAT IS HAPPENING TO THIS PICTURE — "", "fetching" or "failed".
     *
     * A picture that is downloading, one that is queued behind sixteen
     * others, and one whose download failed all looked EXACTLY the same on
     * screen: the blur, for ever, with nothing to press. The state was known
     * all along — `_filePending` and `_fileFailed` are right here — it simply
     * never reached the screen.
     *
     * Nothing is reported once a usable file has landed: furniture on top of
     * a picture that arrived is worse than no furniture at all.
     */
    function fileStateOf(message) {
        const media = message ? message.media : null;
        if (!media)
            return "";

        // Read so this recomputes as the queue moves.
        root.fetchRevision;
        root.fileRevision;
        const ids = [];
        if (media.fileId)
            ids.push(String(media.fileId));

        if (media.thumbFileId)
            ids.push(String(media.thumbFileId));

        for (let i = 0; i < ids.length; i++) {
            const held = root.files[ids[i]];
            if (held !== undefined && held.length > 0)
                return "";

        }
        for (let i = 0; i < ids.length; i++) if (root._filePending[ids[i]]) {
            return "fetching";
        }
        for (let i = 0; i < ids.length; i++) if (root._fileFailed[ids[i]] !== undefined) {
            return "failed";
        }
        return "";
    }

    /// Ask again for a picture that failed, now — a press is not the timed
    /// retry in `thumbOf`, and does not wait for its twenty seconds.
    function retryFile(message) {
        const media = message ? message.media : null;
        if (!media)
            return ;

        const ids = [];
        if (media.thumbFileId)
            ids.push(String(media.thumbFileId));

        if (media.fileId)
            ids.push(String(media.fileId));

        for (let i = 0; i < ids.length; i++) {
            const id = ids[i];
            delete root._fileFailed[id];
            if (!root._filePending[id]) {
                root._filePending[id] = true;
                root._download(id);
            }
        }
        root.fetchRevision++;
        root.fileRevision++;
    }

    function _fileLanded(fileId, path) {
        delete root._filePending[fileId];
        delete root._streamWanted[fileId];
        delete root._partial[fileId];
        delete root._fileFailed[fileId];
        // The daemon hands back a bare path; QML wants a URL.
        root.files[fileId] = path.indexOf("file://") === 0 ? path : "file://" + path;
        root.fetchRevision++;
        root.fileRevision++;
    }

    function openViewer(message) {
        if (!message || !message.media)
            return ;

        root.viewing = message;
        // Asked for HERE, not from a binding in the viewer: a fetch started
        // while a property is being evaluated is a side effect of drawing.
        if (Fmt.isMoving(message.media))
            root.watch(message);
        else
            root.fileOf(message);
    }

    /*
     * A CLIP STARTS PLAYING BEFORE IT HAS ARRIVED.
     *
     * The viewer used to ask for `originalFileId` — the full upload — and play
     * nothing until every byte was on disk: a 60 MB clip was a minute of
     * poster. Now, in order:
     *
     *   1. the 480p H.264 variant in `fileId` (morsed's choice for exactly
     *      this — a buffer covers several times the seconds), fetched URGENT so
     *      it is not queued behind sixteen thumbnails;
     *   2. played from its part-written file (`prefixPath`) as soon as a
     *      buffer has arrived, if `supportsStreaming` says the index is at the
     *      front — the viewer reopens it where it stopped when it runs dry;
     *   3. once that is complete, the original, swapped in at the same moment.
     */
    property var _streamWanted: ({})
    property var _partial: ({})
    property int partialRevision: 0
    /// Bytes to have before playing a part-written clip: ~15 s of 480p.
    readonly property int streamStartBytes: 1536 * 1024

    function watch(message) {
        const media = message ? message.media : null;
        if (!media || !media.fileId)
            return ;
        const small = String(media.fileId);
        if (root.files[small] !== undefined)
            return ;
        root._streamWanted[small] = true;
        root._filePending[small] = true;
        root.fetchRevision++;
        // Urgent, so TDLib puts it ahead of every thumbnail — and its progress
        // events are what let a clip start before it has finished.
        wire.call("file.prefetch", {
            "fileId": small,
            "urgent": true
        }, function(err) {});
        /*
         * AND A REAL DOWNLOAD, AT THE FRONT OF THE QUEUE.
         *
         * The prefetch answers at once and reports the finished file only
         * through `file.progress` events. A Morse that does not send those for
         * a prefetch left the viewer on its poster for ever — the clip did not
         * load at all, where before it merely loaded slowly. `file.download`
         * answers with the path itself, so the clip arrives either way; the
         * queue pops from the end, so pushing it last puts it first.
         */
        root._fetchQueue = root._fetchQueue.filter(id => id !== small);
        root._download(small);
    }

    function _partialArrived(fileId, data) {
        const path = String(data.prefixPath);
        root._partial[fileId] = {
            "url": path.indexOf("file://") === 0 ? path : "file://" + path,
            "prefix": Number(data.prefix || 0),
            "total": Number(data.total || 0)
        };
        root.partialRevision++;
    }

    /// The quick variant is on disk in full.
    function smallReady(message) {
        const media = message ? message.media : null;
        root.fileRevision;
        return !!media && !!media.fileId && root.files[String(media.fileId)] !== undefined;
    }

    /// The original, only if it has already arrived — never asks for it.
    function heldOriginal(message) {
        const media = message ? message.media : null;
        root.fileRevision;
        if (!media || !media.fileId)
            return "";
        const held = root.files[String(media.originalFileId || media.fileId)];
        return held === undefined ? "" : held;
    }

    /*
     * WHAT THE VIEWER'S PLAYER SHOULD OPEN NOW: the original if it is here,
     * else the quick variant, else enough of the quick variant to start —
     * "" while there is not yet enough of anything.
     */
    function playOf(message) {
        const media = message ? message.media : null;
        if (!media || !media.fileId)
            return "";
        root.fileRevision;
        root.partialRevision;
        const original = root.heldOriginal(message);
        if (original.length > 0)
            return original;
        const small = root.files[String(media.fileId)];
        if (small !== undefined)
            return small;
        const part = root._partial[String(media.fileId)];
        if (!part || media.supportsStreaming !== true)
            return "";
        const enough = part.total > 0 ? Math.min(part.total, root.streamStartBytes) : root.streamStartBytes;
        return part.prefix >= enough ? part.url : "";
    }

    /// The url is a part-written file: the player will run dry and reopen.
    function isLive(message, url) {
        const media = message ? message.media : null;
        root.partialRevision;
        const part = media ? root._partial[String(media.fileId)] : null;
        return !!part && url === part.url && root.files[String(media.fileId)] === undefined;
    }

    /// How much of the part-written file is readable now, for the reopen.
    function liveBytes(message) {
        const media = message ? message.media : null;
        root.partialRevision;
        const part = media ? root._partial[String(media.fileId)] : null;
        return part ? part.prefix : 0;
    }

    function openViewerAt(index) {
        const list = root.viewerList;
        if (index >= 0 && index < list.length)
            root.openViewer(list[index]);

    }

    function closeViewer() {
        root.viewing = null;
    }

    /// Leave the album in `delta`'s direction, landing on the first picture
    /// outside it. Does nothing when there is no album, which is what makes
    /// the end of the chat still be the end.
    function _stepOutOfAlbum(delta) {
        const album = root.viewerAlbum;
        if (!album || album.items.length < 2)
            return ;

        const all = root.viewerAll;
        const edge = delta > 0 ? album.items[album.items.length - 1] : album.items[0];
        let where = -1;
        for (let i = 0; i < all.length; i++) if (String(all[i].id) === String(edge.id)) {
            where = i;
            break;
        }
        if (where < 0)
            return ;

        const next = where + delta;
        if (next < 0 || next >= all.length)
            return ;

        root.openViewer(all[next]);
    }

    function viewerStep(delta) {
        const at = root.viewerIndex;
        if (at < 0)
            return ;

        const next = at + delta;
        if (next < 0 || next >= root.viewerList.length) {
            /*
             * OFF THE END OF AN ALBUM IS NOT THE END.
             *
             * Scoping the viewer to an album would otherwise trap you in it:
             * four pictures and a dead stop in both directions. Stepping past
             * either edge leaves the album at the place it occupies in the
             * chat, so the sequence reads as one continuous run of pictures
             * with the album's frames in their proper place.
             */
            root._stepOutOfAlbum(delta);
            return ;
        }

        root.openViewer(root.viewerList[next]);
        // Walking off the end is how a screen says "there is more" — and each
        // screen has its own more.
        if (next >= root.viewerList.length - 3) {
            if (root.screen === "media")
                root.loadMedia(false);
            else
                root.loadOlder();
        }
    }

    function keyOf(message) {
        const media = message ? message.media : null;
        if (!media)
            return "";

        return String(media.uniqueId || media.fileId || "");
    }

    function isAdded(message) {
        const key = root.keyOf(message);
        return key.length > 0 && root.added[key] !== undefined;
    }

    function take(message, onDone) {
        if (root.chatIsSecret) {
            Toast.error("Not out of a secret chat — that picture stays where it is.");
            if (onDone)
                onDone(false, null);

            return ;
        }
        const media = message ? message.media : null;
        if (!media) {
            if (onDone)
                onDone(false, null);

            return ;
        }
        if (root.isAdded(message)) {
            const key = root.keyOf(message);
            if (onDone)
                onDone(true, root.addedItems[key] || null);
            else
                Toast.show("Already in quarry");
            return ;
        }
        if (!Client.connected) {
            Toast.error("Can't keep it — start quarryd first");
            if (onDone)
                onDone(false, null);

            return ;
        }
        const source = root.fileOf(message);
        if (source.length === 0) {
            // The file is on its way; asking again once it lands is one click,
            // and a queue here would hide a download that never finishes.
            Toast.show(root.isFetchingFile(message) ? "Fetching it — try again in a moment" : "Asking Morse for the file…");
            if (onDone)
                onDone(false, null);

            return ;
        }
        const key = root.keyOf(message);
        const path = source.replace("file://", "");
        const ext = Fmt.extensionOf(path, media.mime);
        const dir = `${Sys.home}/.cache/quarry/lens/telegram`;
        const dest = `${dir}/${key}${ext}`;
        root.busyCount++;
        /*
         * ARGV, NEVER A SHELL.
         *
         * `path` is Telegram's download, and Telegram names a download after
         * what the SENDER called it. Through `bash -c` a file called
         * `$(…).jpg` is a command somebody else wrote, run because you clicked
         * "keep". `Sys.run` takes argv and starts the program directly, so a
         * name is only ever a name.
         */
        Sys.run(["mkdir", "-p", dir], function(madeDir) {
            if (!madeDir) {
                root.busyCount--;
                Toast.error("Could not make quarry's cache folder");
                if (onDone)
                    onDone(false, null);

                return ;
            }
            root._copyIn(path, dest, key, onDone);
        });
    }

    function _copyIn(path, dest, key, onDone) {
        Sys.run(["cp", "-f", path, dest], function(ok) {
            if (!ok) {
                root.busyCount--;
                // Not the file name: it is the sender's words, and a toast is
                // the one place on this screen that outlives the screen.
                Toast.error("Could not copy that file out of Morse");
                if (onDone)
                    onDone(false, null);

                return ;
            }
            Client.call("adopt", {
                "path": "file://" + dest,
                "tags": ["telegram"],
                "nsfw": root.markAdult
            }, function(err, payload) {
                root.busyCount--;
                if (err || !payload || !payload.item) {
                    Toast.error("quarry would not take it — " + String(err || "no item"));
                    if (onDone)
                        onDone(false, null);

                    return ;
                }
                const ids = {
                };
                for (const k in root.added) ids[k] = root.added[k]
                ids[key] = payload.item.id;
                root.added = ids;
                const rows = {
                };
                for (const k in root.addedItems) rows[k] = root.addedItems[k]
                rows[key] = payload.item;
                root.addedItems = rows;
                if (onDone)
                    onDone(true, payload.item);

            });
        });
    }

    /// The nth picture on this screen, kept — the hook a shortcut or a probe
    /// can reach where a whole message object cannot be passed.
    function takeAt(index) {
        const list = root.viewerList;
        if (index >= 0 && index < list.length)
            root.take(list[index], null);

    }

    /// Every picture on the wall, one at a time — each needs a download of its
    /// own, and forty parallel ones is a queue nobody can see the end of.
    function takeAll() {
        if (root.bulkRunning)
            return ;

        const wanted = root.media.filter((m) => {
            return m.media && !root.isAdded(m);
        });
        if (wanted.length === 0) {
            Toast.show("Nothing new here");
            return ;
        }
        root.bulkCancelled = false;
        root.bulkTotal = wanted.length;
        root.bulkDone = 0;
        root.bulkKept = 0;
        root._takeNext(wanted, 0);
    }

    function cancelBulk() {
        root.bulkCancelled = true;
    }

    function _takeNext(list, index) {
        if (root.bulkCancelled || index >= list.length) {
            const kept = root.bulkKept;
            const tried = root.bulkTotal;
            root.bulkTotal = 0;
            root.bulkDone = 0;
            Toast.show(root.bulkCancelled ? `Stopped — ${kept} kept` : (kept === tried ? `${kept} kept in quarry` : `${kept} of ${tried} kept — the rest are still coming down`));
            return ;
        }
        const message = list[index];
        const step = function step(ok) {
            if (ok)
                root.bulkKept++;

            root.bulkDone = index + 1;
            root._takeNext(list, index + 1);
        };
        // The file has to be here before it can be copied, so one that has not
        // arrived is asked for and picked up on the next pass.
        if (root.fileOf(message).length === 0) {
            fileWait.pending = message;
            fileWait.next = step;
            fileWait.restart();
            return ;
        }
        root.take(message, step);
    }

    // ── everything else you can do with one ──────────────────────────────────
    function withItem(message, onItem) {
        root.take(message, function(ok, item) {
            if (ok && item)
                onItem(item);

        });
    }

    function exportMedia(message, targetId) {
        root.withItem(message, function(item) {
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

    function setWallpaper(message, targetId) {
        root.withItem(message, function(item) {
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

    function findSimilar(message) {
        root.withItem(message, function(item) {
            Lenses.close();
            Catalog.findSimilar(item, false, "all");
        });
    }

    function copyPicture(message) {
        if (root.chatIsSecret) {
            Toast.error("Not out of a secret chat.");
            return ;
        }
        const source = root.fileOf(message);
        if (source.length === 0) {
            Toast.show("Fetching it first…");
            return ;
        }
        const media = message.media;
        Sys.copyImage(source.replace("file://", ""), media.mime && media.mime.indexOf("image/") === 0 ? media.mime : "image/png", (ok) => {
            return ok ? Toast.show("Picture copied · paste it anywhere") : Toast.error("Could not copy — " + Sys.lastError);
        });
    }

    function copyText(message) {
        if (root.chatIsSecret) {
            Toast.error("Not out of a secret chat.");
            return ;
        }
        const text = message && message.text ? String(message.text) : "";
        if (text.length === 0) {
            Toast.show("Nothing to copy — that message is only a file");
            return ;
        }
        Sys.copyText(text, (ok) => {
            return ok ? Toast.show("Copied") : Toast.error("Could not copy — " + Sys.lastError);
        });
    }

    /// Where the file is on this machine, for a file manager.
    /*
     * Save to Downloads / open in its own app — any file, fetched first when it
     * is not here yet. Saving is morsed's `file.save` (named, never overwrites).
     */
    function saveFile(message) {
        root._withFile(message, path => wire.call("file.save", {
            "path": path,
            "name": (message.media && message.media.name) || ""
        }, function(err, result) {
            if (err) {
                Toast.error(String(err));
                return ;
            }
            const saved = String(result.saved || "");
            Toast.show(`Saved ${saved.split("/").pop()} to Downloads`);
        }));
    }

    function openFile(message) {
        root._withFile(message, path => Qt.openUrlExternally("file://" + path));
    }

    function _withFile(message, then) {
        if (root.chatIsSecret) {
            Toast.error("Not out of a secret chat.");
            return ;
        }
        const media = message ? message.media : null;
        if (!media || !media.fileId)
            return ;
        const held = root.fileOf(message).replace("file://", "");
        if (held.length > 0) {
            then(held);
            return ;
        }
        Toast.show("Downloading it first…");
        const id = String(media.originalFileId || media.fileId);
        wire.call("file.download", {
            "fileId": id
        }, function(err, result) {
            if (err || !result || !result.path) {
                Toast.error("Could not download it.");
                return ;
            }
            root._fileLanded(id, String(result.path));
            then(String(result.path));
        });
    }

    function showFile(message) {
        if (root.chatIsSecret) {
            Toast.error("Not out of a secret chat.");
            return ;
        }
        // Fetched first when it is not here, like save and open.
        root._withFile(message, path => Sys.showInFiles(path));
    }

    // The app's layout button drives this wall: the base type reads these
    // two and does the rest (see modules/lens/Lens.qml).
    layouts: root.wallLayouts
    /// Per chat — the chat of screenshots wants big cells, the chat of a
    /// thousand stickers wants small ones.
    layoutContext: root.chatId
    // Both, deliberately: the registry assigns `settings` AFTER this object is
    // built, and a lens that has never been saved has nothing to assign.
    onSettingsChanged: root._reviewAutostart()
    Component.onCompleted: root._reviewAutostart()
    screenTitle: root.screen === "media" ? `${root.chatTitle} — pictures` : root.screen === "chat" ? (root.thread.length > 0 ? `${root.chatTitle} · ${root.threadTitle}` : root.chatTitle) : root.brand
    // ...or there is somewhere on the trail to go back TO, which is the whole
    // point of keeping one. See `back`.
    canGoBack: root.screen !== "chats" || root.viewing !== null || root._trail.length > 0
    /*
     * Telegram's own web client, for the things a lens is not: joining a group,
     * settings, anything that needs an account rather than a view of one. It
     * opens the chat you are in when Telegram can be told which — a numeric id
     * is not something web.telegram.org takes, so a username is what decides.
     */
    siteUrl: {
        const handle = root.chat && root.chat.username ? String(root.chat.username) : "";
        return handle.length > 0 ? `https://t.me/${handle}` : "https://web.telegram.org/";
    }
    onChatFilterChanged: chatSearch.restart()
    // ── chats ────────────────────────────────────────────────────────────────
    onOpened: {
        // Opening is the ask: if morsed is not up, start it now rather than
        // printing "it isn't running" at somebody who just said they want it.
        wire.ensureRunning();
        root.loadFolders();
        root.loadChats();
    }
    onBackRequested: root.back()
    navItems: {
        const rows = [];
        if (root.chatId.length > 0) {
            rows.push({
                "id": "__chat",
                "label": root.chatTitle,
                "sublabel": Fmt.chatKind(root.chat),
                "icon": Fmt.chatIcon(root.chat),
                "picture": root.chat ? String(root.chat.photo || "") : "",
                "count": "",
                "active": root.screen === "chat"
            });
            rows.push({
                "id": "__media",
                "label": "Pictures",
                "sublabel": "this chat, as a wall",
                "icon": "grid_view",
                "count": root.media.length > 0 ? String(root.media.length) : "",
                "active": root.screen === "media"
            });
        }
        rows.push({
            "id": "__chats",
            "label": "Chats",
            "sublabel": root.folderId.length > 0 ? Fmt.folderName(root.folders, root.folderId) : "all of them",
            "icon": "forum",
            "count": String(root.chats.length),
            "active": root.screen === "chats"
        });
        return rows;
    }
    // The chats themselves, as faces two to a row: twice as many fit in the rail.
    navTiles: root.visibleChats.slice(0, 60).map(c => ({
                "id": String(c.id),
                "label": String(c.title || "Chat"),
                "icon": Fmt.chatIcon(c),
                "picture": String(c.photo || ""),
                "initials": Fmt.initials(c),
                "hue": Fmt.hueOf(c.id || c.title || ""),
                "count": c.unread > 0 ? String(c.unread) : "",
                "active": root.chatId === String(c.id) && root.screen !== "chats"
            }))
    onNavPicked: (id) => {
        if (id === "__chats")
            root.showChats();
        else if (id === "__media")
            root.showMedia();
        else if (id === "__chat")
            root.screen = "chat";
        else
            root.openChat(id);
    }
    menuItems: {
        if (!root.isOpen)
            return [];

        const rows = [{
            "label": "Refresh",
            "icon": "refresh",
            "hint": root.screen === "chats" ? "the chat list" : "this chat",
            "trigger": () => {
                return root.refresh();
            }
        }, {
            "label": "Mark what you keep as adult",
            "icon": "no_adult_content",
            "checked": root.markAdult,
            "hint": "a chat has no rating",
            "trigger": () => {
                return root.setMarkAdult(!root.markAdult);
            }
        }];
        if (root.screen === "chat" && root.chatId.length > 0)
            rows.push({
            "label": "See the pictures as a wall",
            "icon": "grid_view",
            "trigger": () => {
                return root.showMedia();
            }
        });

        if (root.screen === "media")
            rows.push({
            "label": "Back to the conversation",
            "icon": "forum",
            "trigger": () => {
                return root.screen = "chat";
            }
        });

        if (root.screen === "media" && root.media.length > 0)
            rows.push({
            "label": "Keep every picture here",
            "icon": "library_add",
            "hint": `${root.media.length}`,
            "trigger": () => {
                return root.takeAll();
            }
        });

        if (!wire.ready)
            rows.push({
            "label": "Try Morse again",
            "icon": "cable",
            "hint": wire.state,
            "trigger": () => {
                wire.ensureRunning();
                wire.retry();
            }
        });

        rows.push({
            "label": "Play clips where they sit",
            "icon": "motion_photos_auto",
            "checked": root.autoplay,
            "hint": `muted · up to ${Math.round(root.autoplayMaxBytes / 1048576)} MB`,
            "trigger": () => {
                return root.setAutoplay(!root.autoplay);
            }
        });
        rows.push({
            "label": "Start Morse when this opens",
            "icon": "play_circle",
            "checked": root.autostart,
            "hint": root.autostart ? "the daemon only" : "off — Morse starts its own",
            "trigger": () => {
                return root.setAutostart(!root.autostart);
            }
        });
        return rows;
    }
    shortcuts: [{
        "sequence": "Ctrl+Shift+M",
        "action": () => {
            return Lenses.activeId === root.lensId ? Lenses.close() : Lenses.open(root.lensId);
        }
    }]

    _chatSearch: Timer {
        id: chatSearch

        interval: 250
        onTriggered: root.searchChats()
    }

    _wire: Wire {
        id: wire

        autostart: root.autostart
        onReadyChanged2: {
            if (root.isOpen)
                root.refresh();

        }
        onEvent: (name, data) => {
            return root._onEvent(name, data);
        }
    }

    _chatDebounce: Timer {
        id: chatDebounce

        interval: 1500
        onTriggered: {
            if (root.isOpen)
                root.loadChats();

        }
    }

    _fileWait: Timer {
        id: fileWait

        property var pending: null
        property var next: null

        interval: 1200
        onTriggered: {
            const message = fileWait.pending;
            const step = fileWait.next;
            fileWait.pending = null;
            fileWait.next = null;
            if (!message || !step)
                return ;

            if (root.fileOf(message).length === 0) {
                step(); // it can be kept later, by hand
                return ;
            }
            root.take(message, step);
        }
    }

}
