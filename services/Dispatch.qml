pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import QtWebSockets

/*
 * ┌───────────────────────────────────────────────────────────────────────┐
 * │  PLACEHOLDER NAME — "Dispatch" is not decided.                        │
 * │                                                                       │
 * │  The quarry↔Morse connection is supposed to get a name of its own.     │
 * │  Until the user picks one, this file, ChatPickerSheet.qml and          │
 * │  DispatchIndicator.qml carry it, and renaming is three file names plus │
 * │  the `Dispatch.` references in ItemMenu/ItemContextMenu/shell.qml.     │
 * │  Nothing permanent uses it: no package name, no id on disk, no string  │
 * │  a user ever reads. The target ids in Targets.qml are deliberately     │
 * │  spelled `telegram-*` rather than after the codename, because those DO │
 * │  persist (targets.json, the recent list) and would be painful to move. │
 * └───────────────────────────────────────────────────────────────────────┘
 *
 * The link to morsed — Morse/PROTOCOL.md v1, a WebSocket on loopback with a
 * token from `$XDG_RUNTIME_DIR/morse/endpoint.json`.
 *
 * Two rules this file is written around.
 *
 * NEVER BLOCK ON IT. Morse not running is the ordinary case, not an error: the
 * endpoint file is simply absent, `available` stays false, `reason` says so in
 * one line, and every caller degrades instead of waiting. Nothing in quarry
 * ever waits on this socket to draw.
 *
 * NEVER TOUCH A CONVERSATION. quarry asks for the chat list and sends files.
 * It does not call `messages.history`, and `lastMessage` is dropped from every
 * chat the moment it arrives (see `_slimChat`) so a message preview cannot
 * reach a screenshot, a log or a crash dump by accident. Nothing here is ever
 * printed — not a chat title, not the token.
 */
Singleton {
    id: root

    // ── presence ─────────────────────────────────────────────────────────────

    /// "absent" · no endpoint file — morsed is not running
    /// "connecting" · endpoint read, socket not greeted yet
    /// "signedOut" · daemon answers, but the account is not signed in
    /// "ready" · a file can actually be sent
    readonly property string state: {
        if (!root._haveEndpoint)
            return "absent";
        if (!root._greeted)
            return "connecting";
        return root._authState === "ready" ? "ready" : "signedOut";
    }

    readonly property bool available: root.state === "ready"

    /// Has an endpoint file existed at any point this session?
    ///
    /// The difference between "Morse has gone away" and "Morse was never
    /// installed", which is what decides whether a presence indicator is
    /// information or clutter. Sticky on purpose: it must not flicker off
    /// while morsed restarts.
    property bool everSeen: false

    /// Ask again, now — for someone who has just started morsed and does not
    /// want to wait out the two-second tick.
    function retry() {
        endpoint.reload();
        root._connect();
    }

    /// One line, fit for a strip or a menu row. "" when there is nothing to say.
    readonly property string reason: {
        switch (root.state) {
        case "absent":
            return "Morse isn't running — nothing to send to.";
        case "connecting":
            return "Reaching Morse…";
        case "signedOut":
            return root._authState === "connecting" ? "Morse is connecting to Telegram…" : "Morse is running, but not signed in to Telegram.";
        }
        return "";
    }

    /// "mock" or "tdlib", "" before the handshake. A mock send goes nowhere,
    /// and a UI that does not say so is lying about what just happened.
    readonly property string backend: root._backend
    readonly property bool mock: root._backend === "mock"

    // ── chats ────────────────────────────────────────────────────────────────

    /// Recent chats, pinned first then by `order` — the daemon's own sort, kept.
    /// Trimmed of message previews; see `_slimChat`.
    property var chats: []
    property bool chatsLoading: false

    // ── the send in flight ───────────────────────────────────────────────────

    /// "" · idle | "exporting" | "sending" | "sent" | "failed"
    property string sendState: ""
    /// What the current/last send is about, for the sheet's own status line.
    property string sendTitle: ""
    property string sendError: ""

    signal sent(string chatId)
    signal sendFailed(string message)

    // ── the wire ─────────────────────────────────────────────────────────────

    property bool _haveEndpoint: false
    property int _port: 0
    property string _token: ""       // never logged, never shown
    property bool _greeted: false
    property string _backend: ""
    property string _authState: ""
    property int _nextId: 1
    property var _pending: ({})
    property var _deadlines: ({})

    readonly property string endpointPath: `${Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000"}/morse/endpoint.json`

    /*
     * call(method, params, callback) — callback(err, result), err "" on success.
     *
     * Morse/INTERFACES.md calls this the cardinal rule and so does quarry's own
     * Client: there is no path out of here that leaves a callback unfired. A
     * spinner that never stops is the bug both projects have already paid for.
     */
    function call(method, params, callback) {
        const cb = callback || function () {};
        if (!root._greeted || socket.status !== WebSocket.Open) {
            cb(root.reason || "Not connected to Morse.", null);
            return -1;
        }
        const id = root._nextId++;
        root._pending[id] = cb;
        // Generous: an upload of a 15 MB video is not a fast request.
        root._deadlines[id] = Date.now() + 120000;
        socket.sendTextMessage(JSON.stringify({
            "type": "req",
            "id": id,
            "method": method,
            "params": params || {}
        }));
        return id;
    }

    function refreshChats() {
        if (!root.available) {
            root.chats = [];
            return;
        }
        root.chatsLoading = true;
        root.call("chats.list", {
            "limit": 40,
            "offset": 0
        }, function (err, result) {
            root.chatsLoading = false;
            if (err || !result || !Array.isArray(result.chats)) {
                root.chats = [];
                return;
            }
            root.chats = result.chats.map(root._slimChat);
        });
    }

    /*
     * Search is the SERVER's, not a filter over the forty we hold.
     *
     * Morse/PROTOCOL.md says so twice, and it is right: filtering the page in
     * hand answers "the matches among the forty" while looking like it answered
     * "the matches", so a chat you talk to weekly appears not to exist.
     *
     * `search.global` also returns messages. They are dropped here, unread —
     * quarry has no business holding them.
     */
    function searchChats(text, callback) {
        const cb = callback || function () {};
        if (!root.available || !text || text.trim().length === 0) {
            cb("", []);
            return;
        }
        root.call("search.global", {
            "query": text.trim(),
            "limit": 24
        }, function (err, result) {
            if (err || !result) {
                cb(err || "no answer", []);
                return;
            }
            cb("", (result.chats || []).map(root._slimChat));
        });
    }

    /// Everything about a chat quarry has any business knowing. `lastMessage`
    /// is deliberately not on the list.
    function _slimChat(chat) {
        return {
            "id": chat.id,
            "title": chat.title || "",
            "kind": chat.kind || "private",
            "unread": chat.unread || 0,
            "muted": !!chat.muted,
            "pinned": !!chat.pinned,
            "photo": chat.photo || ""
        };
    }

    // ── what can be sent, and how ────────────────────────────────────────────

    /*
     * The ways one item can travel, as an action record.
     *
     * Not a fixed list: "as a GIF" is meaningless for a PNG and "as a photo" is
     * meaningless for a 3D model, and offering a mode that cannot work is
     * exactly the dishonest degradation this is supposed to avoid.
     */
    function modesFor(item) {
        if (!item)
            return [];
        const family = item.family || "raster";
        if (family === "video") {
            return [
                {
                    "id": "video",
                    "label": "As a video",
                    "icon": "movie",
                    "hint": "plays in the chat"
                },
                {
                    "id": "file",
                    "label": "As a file",
                    "icon": "attach_file",
                    "hint": "untouched"
                }
            ];
        }
        if (family === "model" || family === "audio") {
            return [
                {
                    "id": "file",
                    "label": "As a file",
                    "icon": "attach_file",
                    "hint": "untouched"
                }
            ];
        }
        const out = [];
        if (item.animated)
            out.push({
                "id": "animation",
                "label": "As a GIF",
                "icon": "gif",
                "hint": "keeps moving"
            });
        out.push({
            "id": "photo",
            "label": "As a photo",
            "icon": "image",
            "hint": item.animated ? "still frame" : "Telegram recompresses"
        });
        out.push({
            "id": "file",
            "label": "As a file",
            "icon": "attach_file",
            "hint": "original quality"
        });
        return out;
    }

    /*
     * THE RECIPE PER MODE.
     *
     * `photo` re-encodes, because Telegram is going to re-encode it anyway and
     * a 40 MB PNG of a photograph buys nothing. The other two must not be
     * touched at all — a GIF re-encoded through the still pipeline arrives as
     * one frame, and "original quality" that went through a PNG round trip is
     * not the original.
     *
     * `verbatim` is a recipe flag the daemon does not have yet (see the report's
     * quarryd diff). serde ignores unknown fields, so an older daemon silently
     * re-encodes instead — which is why `_send` checks the reply for it rather
     * than assuming. Video already comes back verbatim today.
     */
    /*
     * "ORIGINAL SIZE" MEANS NOTHING FOR A VECTOR, AND 0×0 MEANS 1×1.
     *
     * A width and height of zero is how the pipeline is told "whatever the
     * picture already is", and for a raster that is exactly right. An SVG has
     * no pixels of its own, so the rasteriser is asked for a 0×0 buffer and
     * answers with the smallest legal one: a 629-byte JPEG, one pixel across,
     * sent to a chat as a picture. Measured, not guessed — it is what the first
     * run of this produced.
     *
     * So a vector is given a size: its own, capped to 1024 on the long edge,
     * and a square when the catalogue does not know its aspect.
     */
    function _sizeFor(item) {
        if (!item || item.family !== "vector")
            return {
                "width": 0,
                "height": 0,
                "fit": "none"
            };
        const w = item.w > 0 ? item.w : 0;
        const h = item.h > 0 ? item.h : 0;
        if (w <= 0 || h <= 0)
            return {
                "width": 1024,
                "height": 1024,
                "fit": "contain"
            };
        const scale = Math.min(1, 1024 / Math.max(w, h));
        return {
            "width": Math.max(1, Math.round(w * scale)),
            "height": Math.max(1, Math.round(h * scale)),
            "fit": "contain"
        };
    }

    function _recipeFor(mode, item) {
        const size = root._sizeFor(item);
        if (mode === "photo")
            return {
                "width": size.width,
                "height": size.height,
                "fit": size.fit,
                "gravity": "center",
                "format": size.fit === "contain" ? "png" : "jpeg",
                "quality": 92,
                "radius": 0,
                // A rasterised vector keeps its transparency; a photograph has
                // none to keep and its "background" is never seen.
                "background": "#00000000"
            };
        return {
            "width": size.width,
            "height": size.height,
            "fit": size.fit,
            "gravity": "center",
            "format": "png",
            "quality": 100,
            "radius": 0,
            "background": "#00000000",
            "verbatim": true
        };
    }

    /// Morse's `messages.sendFile` `kind`. "auto" for an animation until the
    /// Morse side grows an explicit `animation` (see the report's contract).
    function _kindFor(mode) {
        if (mode === "photo")
            return "photo";
        if (mode === "video")
            return "video";
        if (mode === "animation")
            return "auto";
        return "document";
    }

    /*
     * Send one item to one chat.
     *
     * Two hops, and the first one is quarry's: the daemon writes the file to a
     * spool under the cache, then its path goes to morsed. Images never cross
     * either socket — both sides pass paths, which is the same rule quarry's
     * own protocol is built on.
     */
    function sendItem(item, chat, mode, caption, callback) {
        const cb = callback || function () {};
        if (!item) {
            cb("nothing to send");
            return;
        }
        if (!root.available) {
            cb(root.reason || "Morse is not reachable.");
            return;
        }
        if (!Client.connected) {
            cb("quarryd is not running — it is what produces the file.");
            return;
        }

        const wanted = root._recipeFor(mode);
        root.sendState = "exporting";
        root.sendTitle = chat ? chat.title : "";
        root.sendError = "";

        Client.call("export", {
            "id": item.id,
            "recipe": wanted,
            "target": "telegram-send",
            "group": "telegram",
            // A spool, not an export: this is a copy made to hand to another
            // program, and it does not belong in ~/Pictures with the ones that
            // were asked for.
            "path": "~/.cache/quarry/outbox/{slug}-{w}x{h}.{ext}"
        }, function (err, payload) {
            if (err || !payload) {
                root._fail(cb, `quarryd could not produce the file: ${err || "no answer"}`);
                return;
            }

            // The honest half of the verbatim story. Asked for untouched bytes
            // and got a re-encode back: say so instead of sending a still frame
            // that claims to be a GIF.
            if (wanted.verbatim && payload.verbatim !== true && mode === "animation") {
                root._fail(cb, "This quarryd re-encodes — it would arrive as a still. Update quarryd for GIF sends.");
                return;
            }

            root.sendState = "sending";
            root.call("messages.sendFile", {
                "chatId": chat.id,
                "topicId": "",
                "path": payload.path,
                "caption": caption || "",
                "kind": root._kindFor(mode)
            }, function (sendErr) {
                if (sendErr) {
                    root._fail(cb, sendErr);
                    return;
                }
                root.sendState = "sent";
                clearState.restart();
                root.sent(chat.id);
                cb("");
            });
        }, 120000);
    }

    /*
     * One click from a menu row: this picture, that chat, the obvious form.
     *
     * The obvious form is the first mode `modesFor` offers, which is the one
     * that loses nothing — a GIF goes as a GIF, a video as a video, a still as
     * a photo. Anything else is a decision, and a decision belongs in the sheet.
     */
    function quickSend(item, chat) {
        if (!item || !chat)
            return;
        const modes = root.modesFor(item);
        const mode = modes.length > 0 ? modes[0].id : "file";
        Toast.show(`Sending to ${chat.title}…`);
        root.sendItem(item, chat, mode, "", function (err) {
            if (err) {
                Toast.error("Not sent: " + err);
                return;
            }
            Toast.show(`Sent to ${chat.title}`);
        });
    }

    /*
     * Send a file that already exists, exactly as it is.
     *
     * The export sheet's route: you have just chosen a crop, a size and a
     * format, and quarryd has written that file. Re-exporting it from the item
     * would throw all three away and send something else — so this takes the
     * path and does not touch the pipeline at all.
     */
    function sendPath(path, chat, mode, caption, callback) {
        const cb = callback || function () {};
        if (!path || !chat) {
            cb("nothing to send");
            return;
        }
        if (!root.available) {
            cb(root.reason || "Morse is not reachable.");
            return;
        }
        root.sendState = "sending";
        root.sendTitle = chat.title;
        root.sendError = "";
        root.call("messages.sendFile", {
            "chatId": chat.id,
            "topicId": "",
            "path": path,
            "caption": caption || "",
            "kind": root._kindFor(mode)
        }, function (err) {
            if (err) {
                root._fail(cb, err);
                return;
            }
            root.sendState = "sent";
            clearState.restart();
            root.sent(chat.id);
            cb("");
        });
    }

    function _fail(cb, message) {
        root.sendState = "failed";
        root.sendError = message;
        clearState.restart();
        root.sendFailed(message);
        cb(message);
    }

    /// The picker, wherever it lives.
    ///
    /// shell.qml may declare a `ChatPickerSheet` and assign it here, the way it
    /// does for the other sheets. When it has not, one is built on demand as a
    /// child of the window content so the menu rows work anyway — this file and
    /// the sheet are one feature and neither is useful without a surface to
    /// draw on.
    property var picker: null

    /// `filePath` is the export sheet's route: a file that already exists and
    /// must travel exactly as it is. Omit it and the picker exports from the
    /// item in whatever form is chosen there.
    function openPicker(item, filePath) {
        if (!root.picker && Shell.content) {
            const component = Qt.createComponent(Qt.resolvedUrl("../modules/gallery/ChatPickerSheet.qml"));
            if (component.status === Component.Ready) {
                root.picker = component.createObject(Shell.content, {
                    "anchors.fill": Shell.content,
                    "z": 94
                });
            } else if (component.status === Component.Error) {
                console.warn("[dispatch] picker:", component.errorString());
            }
        }
        if (!root.picker) {
            Toast.error(root.reason || "Nowhere to draw the chat picker.");
            return;
        }
        root.picker.openFor(item, filePath || "");
    }

    property Timer _clearState: Timer {
        id: clearState
        interval: 2600
        onTriggered: {
            root.sendState = "";
            root.sendError = "";
        }
    }

    // ── endpoint, socket, reconnection ───────────────────────────────────────

    /*
     * The endpoint file is the presence test.
     *
     * morsed writes it (0600) before it listens and it is gone when the daemon
     * is. Watching it means quarry notices Morse starting without polling a
     * port, and the absence is an ordinary state rather than a failed connect.
     */
    FileView {
        id: endpoint
        path: root.endpointPath
        watchChanges: true
        // Absent is the normal case, not a problem to report — and its content
        // is a credential, so an error printing it would be worse than silence.
        printErrors: false
        onFileChanged: reload()
        onLoadFailed: {
            root._haveEndpoint = false;
            root._token = "";
        }
        onLoaded: {
            let parsed = null;
            try {
                parsed = JSON.parse(text());
            } catch (e) {
                parsed = null;
            }
            if (!parsed || !parsed.port || !parsed.token) {
                root._haveEndpoint = false;
                return;
            }
            const changed = parsed.port !== root._port || parsed.token !== root._token;
            root._port = parsed.port;
            root._token = parsed.token;
            root._haveEndpoint = true;
            root.everSeen = true;
            if (changed && socket.active) {
                // A new token means a new daemon. Drop the old socket rather
                // than letting it fail one request at a time.
                socket.active = false;
            }
            root._connect();
        }
    }

    function _connect() {
        if (!root._haveEndpoint || socket.status === WebSocket.Open || socket.status === WebSocket.Connecting)
            return;
        socket.url = `ws://127.0.0.1:${root._port}`;
        socket.active = true;
    }

    property WebSocket _socket: WebSocket {
        id: socket
        active: false

        onStatusChanged: {
            if (socket.status === WebSocket.Open) {
                socket.sendTextMessage(JSON.stringify({
                    "type": "hello",
                    "token": root._token
                }));
                return;
            }
            if (socket.status === WebSocket.Error || socket.status === WebSocket.Closed) {
                root._greeted = false;
                root._backend = "";
                root._authState = "";
                socket.active = false;
                root._failAll("The connection to Morse dropped.");
            }
        }

        onTextMessageReceived: text => {
            let frame = null;
            try {
                frame = JSON.parse(text);
            } catch (e) {
                return;
            }
            if (!frame || !frame.type)
                return;

            if (frame.type === "welcome") {
                root._greeted = true;
                root._backend = frame.backend || "";
                // Auth state is fetched, not waited for: it only arrives as an
                // event when it CHANGES, and a client that just connected has
                // missed every change so far.
                root.call("auth.state", {}, function (err, result) {
                    root._authState = (!err && result) ? (result.state || "") : "";
                });
                return;
            }

            if (frame.type === "ev") {
                if (frame.event === "auth.state" && frame.data)
                    root._authState = frame.data.state || "";
                else if (frame.event === "chat.updated")
                    chatDebounce.restart();
                return;
            }

            if (frame.type === "res") {
                const cb = root._pending[frame.id];
                delete root._pending[frame.id];
                delete root._deadlines[frame.id];
                if (!cb)
                    return;
                // `error.message` is documented as safe to show; it never
                // carries a token, a number or message text.
                cb(frame.ok ? "" : ((frame.error && frame.error.message) || "Morse refused that."), frame.result || null);
            }
        }
    }

    function _failAll(why) {
        const ids = Object.keys(root._pending);
        const callbacks = ids.map(id => root._pending[id]);
        root._pending = ({});
        root._deadlines = ({});
        for (const cb of callbacks)
            if (cb)
                cb(why, null);
    }

    onAvailableChanged: {
        if (root.available)
            root.refreshChats();
        else
            root.chats = [];
    }

    // The chat list re-sorts on every arriving message; redrawing a picker
    // forty times a minute is not worth the freshness.
    property Timer _chatDebounce: Timer {
        id: chatDebounce
        interval: 1500
        onTriggered: if (root.available && root.picker && root.picker.open)
            root.refreshChats()
    }

    /*
     * One timer for the deadlines and the reconnect.
     *
     * It runs only while something is outstanding or the link is down, so an
     * idle quarry with no Morse on the machine costs a wake-up every two
     * seconds and nothing else. `reload()` is what notices morsed starting on a
     * machine where the file never existed for the watcher to attach to.
     */
    property Timer _tick: Timer {
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
                    cb("Morse did not answer in time.", null);
            }
            if (!root._haveEndpoint)
                endpoint.reload();
            else if (socket.status !== WebSocket.Open && socket.status !== WebSocket.Connecting)
                root._connect();
        }
    }
}
