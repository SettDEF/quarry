pragma Singleton
import qs.modules.common
import QtQuick

/*
 * THE REAL FILE FOR A ROW THAT ONLY HAS A PAGE.
 *
 * Half the catalogue's video can be played by handing its `url` to a player:
 * the boorus store an actual .webm and a preview beside it. The tube sites
 * store neither — measured here: pornhub 867 playable URLs out of 2,720 rows
 * and no previews at all, eporner 0 of 1,790, hqporner 0 of 1,220. For those
 * the `url` is a PAGE, and a player given a page shows nothing at all.
 *
 * So autoplay on a wall of them did nothing, which read as autoplay being
 * broken rather than as there being no file to play. Finding the file is two
 * round trips — `renditions` reads the page, `stream` opens a local proxy for
 * what it found — and that is far too expensive to do per tile.
 *
 * Hence this: resolution is asked for only by the few tiles PlayGate has
 * admitted, answers are kept for the session, and a row already being worked
 * on is never asked for twice. A wall scrolled past at speed therefore costs a
 * handful of requests rather than one per tile.
 */
QtObject {
    id: root

    /// id → the local proxy URL, once found. Kept for the session: scrolling
    /// back to something you just passed must not pay for it again.
    property var _found: ({})
    /// id → true while its two requests are in the air.
    property var _working: ({})
    /// Ids that cannot be resolved, so they are asked for once and never again.
    property var _hopeless: ({})
    property int revision: 0

    /*
     * Three, matching PlayGate's slots. The cap is here as well as there
     * because a resolution outlives the tile that asked for it — a tile can
     * scroll away and lose its slot while its two requests are still in the
     * air, and without a cap a fast scroll would leave dozens of them running.
     */
    property int maxInFlight: 3
    property int inFlight: 0

    readonly property int known: root.revision >= 0 ? Object.keys(root._found).length : 0

    /// Already playable as it stands: a file, not a page. Checked on the path
    /// only — a query string full of `?format=mp4` proves nothing about what
    /// the server will send.
    function isDirect(url) {
        const path = String(url || "").split("?")[0].split("#")[0].toLowerCase();
        return path.endsWith(".mp4") || path.endsWith(".webm") || path.endsWith(".m4v")
            || path.endsWith(".mov") || path.endsWith(".mkv") || path.endsWith(".m3u8");
    }

    /// What a player should be given for this row, or "" if nothing is known
    /// yet. Reading `revision` is what makes a binding re-run when one lands.
    function urlFor(item) {
        if (!item)
            return "";

        if (root.isDirect(item.sample))
            return String(item.sample);

        if (root.isDirect(item.url))
            return String(item.url);

        return root.revision >= 0 && root._found[item.id] ? root._found[item.id] : "";
    }

    /*
     * Ask for the file behind a page. Safe to call repeatedly — it is called
     * from a tile that may be rebound several times a second — because every
     * state it could be in is remembered.
     */
    function resolve(item) {
        if (!item || !item.id || !Client.connected)
            return ;

        const id = String(item.id);
        if (root._found[id] || root._working[id] || root._hopeless[id])
            return ;

        if (root.inFlight >= root.maxInFlight)
            return ;

        if (root.isDirect(item.sample) || root.isDirect(item.url))
            return ;

        root._working[id] = true;
        root.inFlight++;
        Client.call("renditions", {
            "id": id
        }, function(err, payload) {
            const list = (payload && payload.renditions) || [];
            if (err || list.length === 0) {
                root._done(id, "");
                return ;
            }
            /*
             * The LAST rendition, not the first.
             *
             * `renditions` answers best-first, and best on a wall is the wrong
             * end: a tile is a few hundred pixels and a 4K stream decoded into
             * it costs the frame budget everything while looking identical.
             */
            const chosen = list[list.length - 1].url;
            Client.call("stream", {
                "id": id,
                "url": chosen
            }, function(streamErr, opened) {
                root._done(id, streamErr || !opened || !opened.url ? "" : String(opened.url));
            });
        });
    }

    function _done(id, url) {
        delete root._working[id];
        root.inFlight = Math.max(0, root.inFlight - 1);
        if (url.length > 0)
            root._found[id] = url;
        else
            root._hopeless[id] = true;
        root.revision++;
    }

    /// Everything forgotten — the proxy's tokens belong to a daemon that is no
    /// longer there, so a reconnect must not replay URLs that cannot answer.
    function clear() {
        root._found = ({});
        root._working = ({});
        root._hopeless = ({});
        root.inFlight = 0;
        root.revision++;
    }
}
