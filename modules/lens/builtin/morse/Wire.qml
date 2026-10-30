import QtQuick
import QtWebSockets
import Quickshell
import Quickshell.Io
import qs.modules.common

/*
 * THE LINE TO MORSED — Morse/PROTOCOL.md v1, read-only.
 *
 * A WebSocket on loopback with a token from
 * `$XDG_RUNTIME_DIR/morse/endpoint.json`, exactly as Morse's own client and
 * quarry's Dispatch service speak it. This is a SECOND connection rather than
 * a reuse of Dispatch's: Dispatch promises, in writing, never to touch a
 * conversation — it exists to send a picture to a chat and drops every message
 * preview the moment it arrives. A reader of conversations is the opposite job,
 * so it gets its own socket and its own rules, and Dispatch's promise stays
 * true for the service that is always running.
 *
 * READ-ONLY IS ENFORCED HERE, NOT REMEMBERED.
 *
 * Every method this lens may call is on the list below, and `call()` refuses
 * anything else — including a method a future screen adds by accident. The
 * account on the other end is somebody's actual Telegram: nothing in this lens
 * may send, react, join, delete, mark read, or open a chat (`chats.open` tells
 * TDLib the chat is on screen, which moves read state on the server), and a
 * typo must not be the thing standing between those and a stranger's account.
 *
 * NEVER BLOCK ON IT. Morse not running is ordinary: the endpoint file is
 * absent, `state` says "absent", and every screen degrades to a line of text
 * rather than a spinner.
 */
QtObject {
    //     * EVERY METHOD THIS LENS IS ALLOWED TO CALL.
    //     *
    //     * Reading, and nothing else. `chats.open`/`chats.close`, `chats.markRead`,
    //     * `stories.view`, every `messages.*` that writes, every `*.set*` and all of
    //     * `auth.*` are deliberately absent — see the note at the top of this file.
    //     * Narrow on purpose: these are the methods this lens CALLS, not the ones a
    //     * screen might want one day. `me.get` is off it because it is the only
    //     * method that puts a phone number on the wire, and `chats.members` because
    //     * it is a list of names. Widening it is a deliberate act.
    //     *
    //     * Frozen at startup so it cannot be pushed to from a skin.
    //     * `links.join` is the ONE write on this list, and it is here on purpose.
    //     *
    //     * Everything else a lens can call only reads: no sending, no deleting, no
    //     * settings. Joining is different because a `t.me` invite is a link whose
    //     * entire meaning is "come in" — opening it any other way is either a
    //     * browser showing a join page the account cannot use, or nothing at all.
    //     * It never fires on its own: the lens resolves the link, says what it is,
    //     * and joins when somebody presses the button.
    // ── internals ────────────────────────────────────────────────────────────
    //     * MORSE IS STARTED, NOT WAITED FOR.
    //     *
    //     * Opening this lens means wanting to read Telegram, and "it isn't running"
    //     * is a thing the machine can fix by itself. Only the DAEMON is started —
    //     * no window, nothing on screen — and it is detached (`setsid`), because it
    //     * is shared: Morse's own launcher may already be using it, and quarry
    //     * closing must not take somebody's client down with it.
    //     *
    //     * Candidates in order, so a checkout can override an installed copy.

    id: root

    /// "absent" · no endpoint file — morsed is not running
    /// "connecting" · endpoint read, not greeted yet
    /// "signedOut" · the daemon answers, but Telegram is not signed in
    /// "ready" · questions can be asked
    readonly property string state: {
        if (!root._haveEndpoint)
            return root._starting ? "starting" : "absent";

        if (!root._greeted)
            return "connecting";

        return root._authState === "ready" ? "ready" : "signedOut";
    }
    readonly property bool ready: root.state === "ready"
    /// One line fit to print on an empty screen. "" when there is nothing to say.
    readonly property string reason: {
        switch (root.state) {
        case "absent":
            return root._noDaemon ? "Morse is not installed where I can find it — set MORSE_DAEMON to its morsed." : "Morse isn't running — start it and this fills itself in.";
        case "starting":
            return "Starting Morse…";
        case "connecting":
            return "Reaching Morse…";
        case "signedOut":
            return root._authState === "connecting" ? "Morse is connecting to Telegram…" : "Morse is running, but not signed in to Telegram.";
        }
        return "";
    }
    /// "mock" or "tdlib". A mock's chats are fixtures, and a screen that does
    /// not say so is claiming to show somebody's Telegram when it is not.
    readonly property string backend: root._backend
    readonly property bool mock: root._backend === "mock"
    readonly property var allowed: ["auth.state", "folders.list", "chats.list", "chats.get", "messages.history", "topics.list", "topics.history", "search.messages", "search.global", "file.download", "file.prefetch", "file.save", "links.resolve", "links.join"]
    property bool autostart: true
    property bool _starting: false
    /*
     * "Nothing to start" is a fact about this moment, not for ever: the path
     * can be set in settings while the app is running, and the daemon can be
     * installed. So it is cleared whenever that setting changes.
     */
    property bool _noDaemon: false
    /*
     * THE LAUNCHER FIRST, THE BINARY ONLY AS A LAST RESORT.
     *
     * Starting `morsed` directly LOOKS like it works — a daemon appears, an
     * endpoint is published, this lens connects — and it serves FIXTURES. A
     * bare morsed with no environment defaults to the mock backend, and the
     * three things that make it real (MORSE_BACKEND, the path to libtdjson,
     * the database key) live in Morse's own launcher, written there when it
     * was installed. Started without them, quarry was quietly reading a
     * different Telegram from the one Morse's own window shows.
     *
     * So: the launcher, with `--daemon` — which starts the daemon, waits for
     * its endpoint and opens no window — and the bare binary only where no
     * launcher exists. Old launchers have no such flag and would open the
     * whole interface, so the flag is checked for before it is used.
     */
    readonly property string launchScript: 'for l in "$MORSE_LAUNCHER" "$(command -v morse 2>/dev/null)" "$HOME/.local/bin/morse" /usr/bin/morse; do [ -n "$l" ] && [ -x "$l" ] && grep -q -- "--daemon" "$l" 2>/dev/null && { "$l" --daemon && exit 0; exit 4; }; done; [ "$2" = "bare" ] || exit 5; for c in "$1" "$MORSE_DAEMON" "$(command -v morsed 2>/dev/null)" /usr/lib/morse/morsed /usr/bin/morsed "$HOME/.local/lib/morse/morsed"; do [ -n "$c" ] && [ -x "$c" ] && exec setsid -f "$c"; done; exit 3'
    property Connections _pathWatch
    /// `app lensRead morse linkStart` instead of guessed at.
    property string _lastStart: ""
    property double _startedAt: 0
    property Process _starter
    /*
     * KEEP ASKING, DO NOT WAIT TO BE ASKED.
     *
     * Hanging the start off the endpoint file's "load failed" alone was not
     * enough in the live app: the lens sat instantiated and enabled with the
     * daemon down and nothing ever tried. Enabling this lens is the standing
     * instruction — so while the link is absent, it tries, spaced by the guard
     * in `ensureRunning`.
     */
    property Timer _keepUp
    /// It published nothing in time — say so rather than spinning for ever.
    property Timer _startTimeout
    property bool _haveEndpoint: false
    property int _port: 0
    property string _token: "" // never logged, never drawn
    property bool _greeted: false
    property string _backend: ""
    property string _authState: ""
    property int _nextId: 1
    property var _pending: ({
    })
    property var _deadlines: ({
    })
    /*
     * Where morsed says it is listening. `QUARRY_MORSE_ENDPOINT` names another
     * file — a second daemon on a private runtime directory, which is how this
     * lens is tested without going near the account on the real one.
     */
    readonly property string endpointPath: Quickshell.env("QUARRY_MORSE_ENDPOINT") || `${Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000"}/morse/endpoint.json`
    property FileView _endpoint
    property WebSocket _socket
    property Timer _retryState
    /// One timer for deadlines and reconnection. On a machine with no Morse it
    /// costs a wake-up every two seconds and nothing else.
    property Timer _tick

    signal event(string name, var data)
    signal readyChanged2() // fired when the link becomes usable

    /*
     * call(method, params, callback, timeoutMs) — callback(err, result, code).
     *
     * `err` is a line fit to show and `code` is the protocol's own
     * (`INVALID_PARAMS`, `NOT_FOUND`, `BACKEND`…), because a caller that has to
     * tell one refusal from another must not do it by reading the prose.
     *
     * There is no path out of here that leaves a callback unfired: Morse's
     * INTERFACES.md calls that the cardinal rule and quarry's own Client says
     * the same. A spinner that never stops is the bug both projects have
     * already paid for.
     */
    function call(method, params, callback, timeoutMs) {
        const cb = callback || function() {
        };
        if (root.allowed.indexOf(method) < 0) {
            // Loud, because this can only be a programming mistake — and the
            // one it guards against writes to somebody's account.
            console.warn("[morse] refused a method that is not read-only:", method);
            cb("That is not a read-only method.", null, "REFUSED");
            return -1;
        }
        if (!root._greeted || socket.status !== WebSocket.Open) {
            cb(root.reason || "Not connected to Morse.", null, "OFFLINE");
            return -1;
        }
        const id = root._nextId++;
        root._pending[id] = cb;
        // A first chats.list on a cold TDLib cache is genuinely slow, and a
        // timeout that fires in normal use trains people to ignore it. A
        // download is slower still: `file.download` does not answer until the
        // whole file is here, and a 15 MB video over a phone line is minutes.
        root._deadlines[id] = Date.now() + (timeoutMs > 0 ? timeoutMs : 30000);
        socket.sendTextMessage(JSON.stringify({
            "type": "req",
            "id": id,
            "method": method,
            "params": params || {
            }
        }));
        return id;
    }

    /// Ask again now — for someone who has just started morsed.
    function retry() {
        endpoint.reload();
        root._connect();
    }

    /// `force` is somebody pressing Start: neither the setting nor the
    /// once-per-half-minute guard applies to a person asking directly, and it
    /// is the only way the bare binary is ever started.
    function ensureRunning(force) {
        if ((!root.autostart && !force) || root._haveEndpoint || root._starting || root._noDaemon)
            return ;

        // One attempt per half minute: a daemon that dies on startup must not
        // become a loop that restarts it forever.
        if (!force && Date.now() - root._startedAt < 30000)
            return ;

        root._startedAt = Date.now();
        root._starting = true;
        /*
         * THE PATH IS READ NOW, NOT BOUND.
         *
         * As a binding on `command`, it was evaluated when this object was
         * built — before the settings file had been read — so the first
         * attempt ran with an empty path, found nothing, and latched
         * `_noDaemon` for the session. Reading it here means the attempt uses
         * whatever is known at the moment it is made.
         */
        const configured = String(Prefs.morseDaemon || "");
        root._lastStart = configured.length > 0 ? "asked, with a path" : "asked, with no path set";
        starter.command = ["sh", "-c", root.launchScript, "morse-autostart", configured, force ? "bare" : ""];
        starter.running = true;
        startTimeout.restart();
    }

    function _connect() {
        if (!root._haveEndpoint || socket.status === WebSocket.Open || socket.status === WebSocket.Connecting)
            return ;

        socket.url = `ws://127.0.0.1:${root._port}`;
        socket.active = true;
    }

    function _failAll(why) {
        const ids = Object.keys(root._pending);
        const callbacks = ids.map((id) => {
            return root._pending[id];
        });
        root._pending = ({
        });
        root._deadlines = ({
        });
        for (const cb of callbacks) if (cb) {
            cb(why, null, "OFFLINE");
        }
    }

    Component.onCompleted: Object.freeze(root.allowed)

    _pathWatch: Connections {
        function onMorseDaemonChanged() {
            root._noDaemon = false;
            root._startedAt = 0;
            root.ensureRunning();
        }

        target: Prefs
    }
    /// What the last start attempt did — named, so a failure can be read with

    _starter: Process {
        id: starter

        onExited: (code, status) => {
            if (code === 5) {
                /*
                 * No launcher — and a bare morsed is not started behind
                 * somebody's back. Started without Morse's environment it
                 * comes up on fixtures and hijacks the endpoint file that
                 * Morse's own client reads, which once cost a real login. So
                 * this stops and says so; the Start button passes `bare`,
                 * which is a person taking that decision.
                 */
                root._noDaemon = true;
                root._starting = false;
                startTimeout.stop();
                root._lastStart = "Morse's launcher was not found — press Start to run its daemon directly";
            } else if (code === 4) {
                // The launcher exists and refused: a real failure with a
                // reason, not an absence. Its stderr is already in _lastStart.
                root._starting = false;
                startTimeout.stop();
                root._lastStart = `Morse's launcher could not start the daemon — ${root._lastStart}`;
            } else if (code === 3) {
                root._noDaemon = true;
                root._starting = false;
                startTimeout.stop();
                root._lastStart = "no morsed found";
            } else if (code === 0) {
                root._lastStart = "started, waiting for its endpoint";
            } else if (code !== 0) {
                root._lastStart = `start failed (exit ${code}) ${root._lastStart}`;
                root._starting = false;
                startTimeout.stop();
            }
        }

        // Filled in by ensureRunning, which reads the configured path at the
        // moment it launches rather than when this object was built.
        // 3 is the loop falling through: nothing executable to start.
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.trim().length > 0)
                    root._lastStart = text.trim().slice(-120);

            }
        }

        stderr: StdioCollector {
            onStreamFinished: {
                if (text.trim().length > 0)
                    root._lastStart = text.trim().slice(-120);

            }
        }

    }

    _keepUp: Timer {
        interval: 10000
        repeat: true
        running: root.autostart && !root._haveEndpoint && !root._starting && !root._noDaemon
        triggeredOnStart: true
        onTriggered: root.ensureRunning()
    }

    _startTimeout: Timer {
        id: startTimeout

        interval: 15000
        onTriggered: root._starting = false
    }

    _endpoint: FileView {
        id: endpoint

        path: root.endpointPath
        watchChanges: true
        // Absent is the normal case, and the contents are a credential — an
        // error printing either would be worse than silence.
        printErrors: false
        onFileChanged: endpoint.reload()
        onLoadFailed: {
            root._haveEndpoint = false;
            root._token = "";
            root.ensureRunning();
        }
        onLoaded: {
            let parsed = null;
            try {
                parsed = JSON.parse(endpoint.text());
            } catch (e) {
                parsed = null;
            }
            if (!parsed || !parsed.port || !parsed.token) {
                root._haveEndpoint = false;
                return ;
            }
            const changed = parsed.port !== root._port || parsed.token !== root._token;
            root._port = parsed.port;
            root._token = parsed.token;
            root._haveEndpoint = true;
            root._starting = false;
            startTimeout.stop();
            // A new token is a new daemon: drop the old socket rather than
            // failing one request at a time.
            if (changed && socket.active)
                socket.active = false;

            root._connect();
        }
    }

    _socket: WebSocket {
        id: socket

        active: false
        onStatusChanged: {
            if (socket.status === WebSocket.Open) {
                socket.sendTextMessage(JSON.stringify({
                    "type": "hello",
                    "token": root._token
                }));
                return ;
            }
            if (socket.status === WebSocket.Error || socket.status === WebSocket.Closed) {
                root._greeted = false;
                root._backend = "";
                root._authState = "";
                socket.active = false;
                root._failAll("The connection to Morse dropped.");
            }
        }
        onTextMessageReceived: (text) => {
            let frame = null;
            try {
                frame = JSON.parse(text);
            } catch (e) {
                return ;
            }
            if (!frame || !frame.type)
                return ;

            if (frame.type === "welcome") {
                root._greeted = true;
                root._backend = frame.backend || "";
                // Asked for, not waited for: the state only arrives as an event
                // when it CHANGES, and a client that just connected has missed
                // every change so far.
                root.call("auth.state", {
                }, function(err, result) {
                    if (err) {
                        // Asking failed; that is not an answer about the
                        // account. Try once more before saying anything.
                        retryState.restart();
                        return ;
                    }
                    root._authState = result ? (result.state || "") : "";
                    if (root.ready)
                        root.readyChanged2();

                });
                return ;
            }
            if (frame.type === "ev") {
                if (frame.event === "auth.state" && frame.data) {
                    root._authState = frame.data.state || "";
                    if (root.ready)
                        root.readyChanged2();

                }
                root.event(frame.event || "", frame.data || null);
                return ;
            }
            if (frame.type === "res") {
                const cb = root._pending[frame.id];
                delete root._pending[frame.id];
                delete root._deadlines[frame.id];
                if (!cb)
                    return ;

                // `error.message` is documented as safe to show: never a token,
                // a phone number or message text.
                cb(frame.ok ? "" : ((frame.error && frame.error.message) || "Morse refused that."), frame.result || null, (frame.error && frame.error.code) || "");
            }
        }
    }

    _retryState: Timer {
        id: retryState

        interval: 1500
        onTriggered: root.call("auth.state", {
        }, function(err, result) {
            root._authState = (!err && result) ? (result.state || "") : "";
            if (root.ready)
                root.readyChanged2();

        })
    }

    _tick: Timer {
        interval: 2000
        repeat: true
        running: true
        onTriggered: {
            const now = Date.now();
            for (const id in root._deadlines) {
                if (root._deadlines[id] > now)
                    continue;

                const cb = root._pending[id];
                delete root._pending[id];
                delete root._deadlines[id];
                if (cb)
                    cb("Morse did not answer in time.", null, "TIMEOUT");

            }
            if (!root._haveEndpoint)
                endpoint.reload();
            else if (socket.status !== WebSocket.Open && socket.status !== WebSocket.Connecting)
                root._connect();
        }
    }

}
