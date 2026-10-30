pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

/*
 * The daemon connection — PROTOCOL.md v1 over a unix socket, newline-delimited
 * JSON.
 *
 * Everything is request/response by id, so a slow `items` page can never be
 * mistaken for the answer to a later `query`. The client degrades rather than
 * blocks: with no daemon running, `connected` stays false and Catalog reads the
 * fixture directly, which is also how the app behaved for the whole of Phase 1.
 */
Singleton {
    id: root

    /*
     * Where the daemon listens.
     *
     * `$QUARRY_SOCK` overrides it, which is what lets a development build be
     * tested against a development daemon and a copy of the catalogue while
     * the installed one keeps running for real use. Without it the two share
     * one socket, and whichever daemon started last silently answers for both.
     */
    readonly property string socketPath: Quickshell.env("QUARRY_SOCK")
        || `${Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"}/quarry/sock`

    property bool connected: false
    property string backend: ""        // "mock" while the daemon serves a fixture
    property int protocol: 0
    property int daemonItems: 0
    /*
     * The daemon is running code older than what is installed.
     *
     * Reported on the handshake rather than discovered: the running process is
     * the only thing that knows which binary it actually started from, and from
     * out here it is indistinguishable from a daemon that is up to date. See
     * PROTOCOL.md `hello`, and StaleBar, which is what says it out loud.
     */
    property bool stale: false
    /// Which process is answering — see StaleBar, where a restart that did not
    /// take has to name the daemon still holding the socket.
    property int daemonPid: 0
    property string error: ""

    // Wire counters, for the perf report — this is a hot path in a way a file
    // read never was.
    property int sent: 0
    property int received: 0
    property int bytesIn: 0

    signal event(string name, var payload)
    signal ready
    signal reconnected

    property int _nextId: 1
    /// When the daemon last said anything: a quiet socket and a lone timeout
    /// together mean the connection is gone, either alone does not.
    property double _lastReply: Date.now()
    property var _pending: ({})
    property var _deadlines: ({})
    property int timeouts: 0

    /*
     * A request that is never answered.
     *
     * A unix socket whose peer has gone does not always report itself closed —
     * the daemon was restarted under a running app and `connected` stayed true,
     * so every call was written into a socket nobody was reading and no reply
     * ever came. Nothing failed; the gallery simply stopped filling in, which
     * looks exactly like blank cells and reads as a bug in the view.
     *
     * So every call carries a deadline. One timeout is a slow source; several in
     * a row means the connection is gone, and reconnecting is the only thing
     * that can help.
     */
    property Timer _watchdog: Timer {
        interval: 2000
        running: true
        repeat: true
        onTriggered: {
            const now = Date.now();
            let expired = 0;
            /*
             * The tick walks a SNAPSHOT.
             *
             * A timed-out callback may reconnect, and that replaces `_pending`
             * and `_deadlines` with fresh objects — while this loop is still
             * walking the old one. Reading through `root._deadlines` then
             * returned undefined for every remaining id, counted them all as
             * expired, and fired a second reconnect at a socket already being
             * rebuilt.
             */
            const due = root._deadlines;
            for (const id in due) {
                if (root._deadlines !== due)
                    return;             // the connection was torn down under us
                if (due[id] > now)
                    continue;
                const callback = root._pending[id];
                delete root._pending[id];
                delete root._deadlines[id];
                expired++;
                root.timeouts++;
                if (callback)
                    callback("timed out", null);
            }
            /*
             * Everything outstanding expired at once: that is not a slow
             * source, that is a dead socket. One lone timeout is not, on its
             * own — a search round or an export can overrun its deadline while
             * nothing else is in flight, and tearing down a healthy socket for
             * it costs a handshake and a full refresh. So a single expiry only
             * counts when nothing has answered for a while either.
             */
            const silent = now - root._lastReply > 30000;
            if (expired >= 3 || (expired > 0 && silent))
                root.reconnect();
        }
    }

    /*
     * A DROPPED CALL MUST STILL ANSWER.
     *
     * Clearing `_pending` on a disconnect threw the callbacks away, and every
     * caller that had marked its request "in flight" stayed that way forever:
     * Catalog holds `_pendingPages[page]`, so each page that was being fetched
     * when the daemon went away was never asked for again. Measured after three
     * daemon restarts under a running window: 440,168 page asks, 438,315 of
     * them refused as already pending, and a gallery of empty cells.
     *
     * So the callbacks are called, with an error. Everyone who was waiting
     * learns the request is over and can ask again on the next reconnect.
     */
    function _failPending(reason) {
        const waiting = root._pending;
        root._pending = ({});
        root._deadlines = ({});
        // Deferred for the same reason as the "not connected" paths in `call`:
        // one of these callbacks asks for a page, which can fail, which fails
        // the rest — and doing that inside this loop puts the whole cascade on
        // one stack. See `_later`.
        for (const id in waiting) root._later(waiting[id], reason);

    }

    function reconnect() {
        /*
         * Every stream the proxy opened belonged to the daemon that has gone
         * away, so the URLs cached against those tokens answer nothing. Kept
         * ones would be played as black rectangles with no error — the exact
         * failure this app keeps being bitten by.
         */
        Playback.clear();
        root.connected = false;
        root.backend = "";
        root._failPending("connection lost");
        socketLoader.active = false;
        Qt.callLater(function () {
            socketLoader.active = true;
        });
    }

    /// `timeoutMs` for the calls that are slow by nature: a search round asks
    /// forty sites, and its answer is still wanted after thirty seconds.
    /*
     * A CALLBACK NEVER RUNS BEFORE THIS FUNCTION RETURNS.
     *
     * The two "not connected" paths below used to call back on the spot, and
     * that closed a loop with a stack in it:
     *
     *     itemAt -> _requestPage -> call() -> callback("not connected")
     *            -> pageEpoch++ -> every cell's onPageEpochChanged
     *            -> refill() -> itemAt -> _requestPage -> ...
     *
     * all in ONE stack frame chain, because nothing in it ever yielded. It only
     * bit at scale — the cascade has to be deep enough to exhaust the stack, so
     * a 200,000-row catalogue survived it and a 752,415-row one segfaulted on
     * launch, every time, in QV4 with no QML file named.
     *
     * `Qt.callLater` puts the answer on the next turn of the event loop, which
     * is where every other answer here already arrives from the socket. Callers
     * cannot tell the difference and the cycle can no longer nest.
     */
    function _later(callback, err) {
        if (!callback)
            return ;

        Qt.callLater(function () {
            callback(err, null);
        });
    }

    function call(method, params, callback, timeoutMs) {
        if (!root.connected) {
            root._later(callback, "not connected");
            return -1;
        }
        const id = root._nextId++;
        root._pending[id] = callback;
        // Generous: a cold thumbnail is a network fetch, and an export fetches a
        // full-size original.
        root._deadlines[id] = Date.now() + (timeoutMs > 0 ? timeoutMs : 30000);
        const socket = socketLoader.item;
        if (!socket) {
            delete root._pending[id];
            delete root._deadlines[id];
            root._later(callback, "not connected");
            return -1;
        }
        socket.write(JSON.stringify({
            "t": "req",
            "id": id,
            "m": method,
            "p": params || {}
        }) + "\n");
        socket.flush();
        root.sent++;
        return id;
    }

    /// Withdraw requests nobody waits for any more (the daemon drops `thumb`s);
    /// their callbacks are never called.
    function cancel(ids) {
        const live = ids.filter(id => root._pending[id] !== undefined);
        for (const id of live) {
            delete root._pending[id];
            delete root._deadlines[id];
        }
        if (live.length > 0)
            root.call("cancel", { "ids": live }, function () {});
    }

    function _dispatch(line) {
        root.received++;
        root.bytesIn += line.length;

        let frame;
        try {
            frame = JSON.parse(line);
        } catch (e) {
            console.warn("[client] unparseable frame:", line.slice(0, 120));
            return;
        }

        if (frame.t === "ev") {
            root.event(frame.m, frame.p);
            return;
        }

        root._lastReply = Date.now();
        const callback = root._pending[frame.id];
        delete root._pending[frame.id];
        delete root._deadlines[frame.id];
        if (!callback)
            return;
        callback(frame.ok ? null : (frame.err || "error"), frame.p || null);
    }

    /*
     * The socket is rebuilt, not reopened.
     *
     * Quickshell's Socket does not come back once its peer has gone: setting
     * `connected = true` again is accepted and does nothing, which showed up as
     * an app that ran on its offline fixture for the rest of a session after
     * one daemon restart — retrying every 1.5 seconds, forever, with no effect.
     * Recreating the object is what actually reconnects.
     */
    property Loader _socket: Loader {
        id: socketLoader
        active: true

        sourceComponent: Socket {
            path: root.socketPath
            connected: true

            onConnectionStateChanged: {
                if (connected) {
                    root.error = "";
                    root.connected = true;
                    root._lastReply = Date.now();
                    // Back to patient: the next disconnection is a restart,
                    // not a cold start.
                    root._attempts = 0;
                    /*
                     * One turn later.
                     *
                     * This signal arrives while the Loader is still creating
                     * the object, so `socketLoader.item` is null and anything
                     * sent from here goes nowhere — the handshake vanished and
                     * `backend` stayed empty while the socket was, in fact,
                     * connected.
                     */
                    Qt.callLater(root.hello);
                } else {
                    root.connected = false;
                    root.backend = "";
                    root._failPending("daemon went away");
                }
            }

            onError: err => {
                root.error = `socket error ${err}`;
                root.connected = false;
            }

            parser: SplitParser {
                splitMarker: "\n"
                onRead: line => root._dispatch(line)
            }
        }
    }

    /*
     * ASKED AGAIN, SLOWLY, BECAUSE THE UPGRADE HAPPENS MID-SESSION.
     *
     * `stale` is answered on the handshake, and the handshake happens once —
     * at startup, or after a reconnect. But the case this exists for is a
     * package installed while the window is open: the daemon is not restarted,
     * the socket never drops, so there is no second handshake and the bar would
     * never appear for the only scenario anybody hits.
     *
     * A minute is slow enough to be free (one tiny frame, against a watchdog
     * that already ticks every two seconds) and fast enough that the strip is
     * up before you have finished wondering why your fix did nothing.
     */
    property Timer _recheck: Timer {
        interval: 60000
        running: root.connected
        repeat: true
        onTriggered: root.call("hello", {
            "client": "quarry-qml",
            "protocol": 1
        }, function (err, payload) {
            if (err || !payload)
                return ;

            root.stale = payload.stale === true;
            root.daemonPid = Number(payload.pid || 0);
            root.daemonItems = payload.items;
        })
    }

    function hello() {
        root.call("hello", {
            "client": "quarry-qml",
            "protocol": 1
        }, function (err, payload) {
            if (err) {
                root.error = err;
                return;
            }
            root.protocol = payload.protocol;
            root.backend = payload.backend;
            root.daemonItems = payload.items;
            root.stale = payload.stale === true;
            root.daemonPid = Number(payload.pid || 0);
            // A reconnect means everything that failed while the daemon was
            // away deserves another go.
            root.reconnected();
            root.ready();
        });
    }

    /*
     * Reconnect until it works, not once.
     *
     * Two mistakes were in the first version. It fired once, so a daemon that
     * came back later than a second was never noticed — the app ran on the
     * fixture for the rest of the session with a socket it thought it had
     * retried. And it set `connected` false and true inside one handler, which
     * the property system collapses into no change at all, so even that single
     * attempt did nothing.
     *
     * Driven by `running` instead: while there is no connection, it keeps
     * trying, and the toggle happens across two turns of the event loop so it
     * is a real transition.
     */
    /*
     * FAST AT FIRST, PATIENT AFTERWARDS.
     *
     * A flat 1.5 seconds is right for "the daemon died, keep trying" and badly
     * wrong for the first second of a cold launch: the launcher now starts the
     * daemon and the window together, so the socket appears about 70ms in and
     * a 1.5s retry means the gallery sits empty for most of a second after it
     * is already answerable.
     *
     * So the first few attempts come quickly and then it backs off to the old
     * interval, which is what a reconnect actually wants.
     */
    property int _attempts: 0

    property Timer _retry: Timer {
        id: retry
        interval: root._attempts < 8 ? 120 : 1500
        repeat: true
        running: !root.connected
        onTriggered: {
            root._attempts++;
            // Tear the object down and build a new one; see above for why
            // reopening the old one is not an option.
            socketLoader.active = false;
            Qt.callLater(function () {
                socketLoader.active = true;
            });
        }
    }
}
