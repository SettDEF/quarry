import Quickshell
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtMultimedia
import qs.modules.common
import qs.modules.widgets
import qs.services

/*
 * A video, played where the picture would be.
 *
 * The poster frame is already on disk — the wall drew a tile from it — so this
 * opens showing something immediately and the player fades in over it when it
 * has decoded enough to draw. That ordering is the whole trick: a video pane
 * that starts black and stays black for a second reads as broken, and the
 * frame the daemon already extracted is a perfectly good still of the thing
 * you clicked.
 *
 * It streams the source URL rather than downloading first. A wallpaper you
 * APPLY is exported to disk (see quarryd's export_video) because a wallpaper
 * has to survive being offline; a video you are only looking at does not, and
 * waiting for fifteen megabytes before showing anything would be the worse
 * trade.
 */
Item {
    id: root

    required property var item
    /// Whether this pane is the one on screen. A player that keeps decoding
    /// behind a closed overlay is a video you cannot see burning a core.
    property bool active: false

    /*
     * Sound plays here too.
     *
     * An audio row is a file with a player and no picture: everything this view
     * does — resolving it, the bar, the scrubber, the keys — is the same work,
     * and a second view for it would be the same file with the VideoOutput
     * deleted. The poster stands in for the picture, as it already does while a
     * video is still opening.
     */
    readonly property bool isAudio: !!item && item.family === "audio"
    readonly property bool isVideo: !!item && (item.family === "video" || root.isAudio)
    readonly property bool playing: player.playbackState === MediaPlayer.PlayingState
    /// The file this pane should be playing, for the item it shows now.
    readonly property string wanted: root.isVideo && root.item ? String(root.item.url) : ""
    /*
     * Ready means a frame of THIS item's video — not any frame.
     *
     * The player's source was a binding, and a new item restarted playback
     * from a handler that could run before the binding moved: the OLD url was
     * played again, and when the new stream then failed to open, the old
     * video went on playing under the new item's title and details.
     */
    readonly property bool ready: player.hasVideo && player.position > 0
        && root._loaded === root.wanted && root.wanted.length > 0

    /*
     * FOR AN APP THAT EMBEDS THIS PANE (reel).
     *
     * A player needs to start where you stopped and to know when a file has
     * finished, so the next one can follow. Neither is anything the gallery
     * uses, so they are exposed rather than built in.
     */
    readonly property alias mediaPlayer: player
    /// The file played to its end (never while looping).
    signal ended()
    /// Where to start the next file that loads, in ms — restored once it opens.
    function startAt(ms) { root._resumeAt = Math.max(0, ms); }

    /// The url load() last handed the player — compared as the string we set,
    /// not as `player.source`, which Qt normalises into a url that need not
    /// read back identically.
    property string _loaded: ""
    readonly property real controlsOpacity: controlBar.opacity
    readonly property var probe: ({
            "active": root.active,
            "playing": root.playing,
            "ready": root.ready,
            "hasVideo": player.hasVideo,
            "position": player.position,
            "duration": player.duration,
            "status": player.mediaStatus,
            "failure": root.failure,
            "loaded": root._loaded.slice(-40),
            "wanted": root.wanted.slice(-40),
            // Who the arrow keys reach: this view seeks with them, the viewer
            // around it steps between pictures with them, and only the one
            // holding focus ever sees them.
            "focused": root.activeFocus
        })

    /*
     * THE CONTROL BAR AS NUMBERS.
     *
     * "The timeline feels cramped" is a measurement, not a taste: it is the
     * scrubber's width as a fraction of the bar it sits in. Reported here so a
     * test can hold the redesign to it instead of a screenshot being re-judged
     * by eye every time the theme moves.
     */
    readonly property var barProbe: ({
            "paneW": Math.round(root.width),
            "barW": Math.round(controlBar.width),
            "barH": Math.round(controlBar.height),
            "scrubW": Math.round(scrubber.width),
            "scrubH": Math.round(scrubber.height),
            "trackH": scrubber.trackWidth,
            "share": controlBar.width > 0 ? Math.round(100 * scrubber.width / controlBar.width) : 0
        })

    /// Play or pause, for whoever is asking — the button, or the space bar.
    function toggle() {
        if (root.playing)
            player.pause();
        else
            player.play();
    }

    /// Seconds, as a person writes them.
    function clock(ms) {
        if (!(ms > 0))
            return "0:00";
        const total = Math.floor(ms / 1000);
        const minutes = Math.floor(total / 60);
        const seconds = total % 60;
        return `${minutes}:${seconds < 10 ? "0" : ""}${seconds}`;
    }

    onActiveChanged: {
        if (root.active && root.isVideo) {
            player.play();
            root.loadQualities();
        } else {
            player.pause();
        }
    }

    // A different item in the same pane: the player has to be told, or it keeps
    // playing the last one under a new title.
    /*
     * Reload on a new FILE, not on a new object.
     *
     * The record behind the viewer is re-read whenever a page of results
     * lands, which during an endless fetch is every few seconds — a fresh copy
     * of the same row each time. Reloading on every copy restarted the video
     * over and over, so it never got to play.
     */
    onWantedChanged: {
        if (root.wanted !== root._loaded)
            root.load();
    }
    onItemChanged: {
        root.qualities = [];
        root.quality = "";
        root.askedQualities = false;
        if (root.isVideo && root.active)
            root.loadQualities();
    }
    Component.onCompleted: root.load()

    /// Switch files explicitly: stop, empty, then the new source on the next
    /// turn of the event loop, so nothing of the previous one can play on.
    function load() {
        player.stop();
        root.failure = "";
        root._viaQuarry = "";
        // A place remembered for a quality switch belongs to the file it was
        // switched in; a different clip must not inherit it.
        root._resumeAt = 0;
        root.fetching = false;
        player.source = "";
        const next = root.wanted;
        root._loaded = "";
        if (next.length === 0)
            return;
        Qt.callLater(function () {
            if (root.wanted !== next)
                return;         // stepped again before this one started
            root._loaded = next;
            /*
             * A poster is not a video, and handing one to the player does not
             * fail: it reports "buffering" for ever and the pane sits on the
             * still. Tube rows carry their poster as the file, so the page is
             * read first and the stream played instead.
             */
            // Named the other way round on purpose: these CDNs serve posters
            // from paths like "…/rs:fit:320:180/vts:930?hash=…", which no
            // "is it a picture" test catches. Only something that looks like a
            // video file goes to the player; everything else goes through the
            // daemon, which reads the page and finds the real stream.
            if (!root.playableUrl(next)) {
                root.throughQuarry("this row carries its poster, not the video");
                return;
            }
            player.source = next;
            if (root.active)
                player.play();
        });
    }

    MediaPlayer {
        id: player
        // Set by load(), never bound — see `ready`.
        videoOutput: output
        audioOutput: AudioOutput {
            // Muted by default, and deliberately: this is a gallery. Sound
            // arriving unannounced from a wallpaper preview is startling in a
            // way no setting makes up for afterwards.
            muted: !Prefs.videoSound
            volume: volume.value
        }
        // Loop is a SETTING now, not a constant. A short clip you are judging
        // as a wallpaper wants to loop; a two-minute one you are watching once
        // does not, and there was no way to say so.
        loops: root.looping ? MediaPlayer.Infinite : 1
        playbackRate: root.rate

        /*
         * A STREAM THE PLAYER COULD NOT OPEN IS ASKED FOR ONCE MORE.
         *
         * Most failures here were not codecs but hosts: a CDN that wants its
         * referer, a wiki that rate-limits bursts. The daemon fetches the file
         * the way it fetches everything else and the player opens the local
         * copy — only if that fails too is the error shown.
         */
        onErrorOccurred: (error, message) => root.throughQuarry(message)

        /*
         * A stream can fail without an error.
         *
         * Wikimedia's 429 arrives as `InvalidMedia` with no `errorOccurred` at
         * all (measured), so the fallback never ran and the pane sat on its
         * poster. Either signal starts it.
         */
        onMediaStatusChanged: {
            if (player.mediaStatus === MediaPlayer.InvalidMedia && root._loaded.length > 0)
                root.throughQuarry("the host would not serve it");
            if (player.mediaStatus === MediaPlayer.EndOfMedia && !root.looping)
                root.ended();
            // The other half of playQuality: the new file is open, so the place
            // it was switched at can finally be restored.
            const loaded = player.mediaStatus === MediaPlayer.LoadedMedia || player.mediaStatus === MediaPlayer.BufferedMedia;
            if (root._resumeAt > 0 && loaded && player.duration > 0) {
                player.position = Math.min(root._resumeAt, player.duration - 1);
                root._resumeAt = 0;
            }
        }
    }

    /*
     * THE QUALITIES THIS CLIP HAS.
     *
     * Asked for once per video (the daemon probes the host), kept in `qualities`
     * as {label, url, w, h}. `quality` is the label being played; empty means
     * whatever the row's own file is.
     */
    property var qualities: []
    property string quality: ""
    property bool askedQualities: false

    function loadQualities() {
        if (root.askedQualities || !root.item || !Client.connected)
            return;
        root.askedQualities = true;
        const asked = root.item.id;
        Client.call("renditions", { "id": asked }, function (err, payload) {
            if (err || !payload || !root.item || root.item.id !== asked)
                return;
            root.qualities = payload.renditions || [];
            // A remembered choice is applied as soon as it is known to exist.
            const wanted = Prefs.videoQuality;
            if (wanted && wanted !== "auto") {
                const match = root.qualities.find(q => q.label === wanted);
                if (match && String(player.source) !== match.url)
                    root.playQuality(match);
            }
        });
    }

    /*
     * Switch file without losing the place: the same clip at another size.
     *
     * The place cannot be restored HERE. `play()` hands the url to the daemon
     * and sets `player.source` in a callback a tick or more later, so the
     * assignment that used to sit at the end of this function ran against a
     * stopped player with no source and was dropped on the floor: picking
     * 720p three minutes in started you again from zero, which is the one
     * thing the function's own name promised not to do. So the place is
     * REMEMBERED, and the player seeks to it when the new file is loaded.
     */
    property int _resumeAt: 0

    function playQuality(rendition) {
        if (!rendition || !rendition.url)
            return;
        root._resumeAt = player.position;
        root.quality = rendition.label;
        root._viaQuarry = root.wanted;    // this is already the way through
        player.stop();
        root._loaded = root.wanted;
        root.play(rendition.url, root.wanted);
    }

    /// Fetch this clip with the daemon and play the local copy — the way out
    /// of a host that refuses the player but not quarry.
    /// Whether a URL is something the player itself can open. A poster from a
    /// tube CDN has no picture extension either, so this asks the positive
    /// question rather than trying to spot a still.
    /// A heading and its reason, without saying the same thing twice.
    function say(heading, reason) {
        const detail = String(reason || "").trim();
        if (detail.length === 0)
            return heading;
        if (heading.toLowerCase().indexOf(detail.toLowerCase()) >= 0 || detail.toLowerCase().indexOf(heading.toLowerCase()) >= 0)
            return detail.charAt(0).toUpperCase() + detail.slice(1);
        return `${heading} — ${detail}`;
    }

    /*
     * The `/?` is not a typo.
     *
     * Kernel Video Sharing — porntrex, rule34video and a long tail of older tube
     * sites — serves `.../2836667_1080p.mp4/?token=...`, with a slash BETWEEN the
     * extension and the query. Requiring the extension to end the path or be followed
     * by `?` calls that file unplayable, so the viewer resolved the page, got a
     * perfectly good URL back, and refused to play it. knapd's `playable_url` has the
     * same rule for the same reason; if one changes, so does the other.
     */
    function playableUrl(url) {
        return /\.(mp4|webm|mkv|mov|m4v|m3u8)\/?($|[?#])/i.test(url) || String(url).startsWith("file://");
    }

    function throughQuarry(why) {
        const failedOn = root._loaded;
        if (root._viaQuarry.length > 0 || failedOn.length === 0 || !root.item || !Client.connected) {
            root.fetching = false;
            // no second way to try (or it failed too): say so, or the host never learns it failed
            if (root._viaQuarry.length > 0 || !Client.connected)
                root.failure = why || "this video could not be played";
            return;
        }
        root._viaQuarry = failedOn;
        root.fetching = true;
        root.failure = "";

        /*
         * A "video" whose file is a picture is a poster: tube sites publish
         * the still and the page, never the file. The page is read for the
         * real one, which also fixes the row for good.
         */
        if (!root.playableUrl(failedOn) && root.item.page_url && root.item.page_url.length > 0) {
            Client.call("resolve", { "id": root.item.id }, function (err, payload) {
                if (root.wanted !== failedOn)
                    return;
                if (err || !payload || !payload.url) {
                    root.fetching = false;
                    // The daemon's own words where it has them, rather than a
                    // heading with the same sentence repeated after the dash.
                    root.failure = root.say("No video on that page", err || why);
                    return;
                }
                root.play(payload.url, failedOn);
            });
            return;
        }
        /*
         * A FILE THE HOST REFUSED IS STREAMED, NOT DOWNLOADED.
         *
         * This went straight to `fetchLocal`, which fetches the WHOLE file
         * before the player gets a byte — erome refuses its clips without its
         * own Referer, so every one of them sat on its poster for as long as a
         * 700 MB download takes. The daemon's stream door adds the Referer and
         * serves the parts as they are asked for; a full fetch is what `play`
         * falls back to if even that fails.
         */
        root.play(failedOn, failedOn);
    }

    /*
     * Play a stream the page gave us, or fetch it first when it cannot be
     * played from here.
     *
     * A playlist needs the page's Referer for every segment, which a media
     * player cannot send — the host answers 410 and the pane sits on its
     * poster. Those go to the daemon, which has ffmpeg and the headers.
     */
    function play(url, failedOn) {
        if (!root.item || !Client.connected) {
            root.fetching = false;
            player.source = url;
            if (root.active)
                player.play();
            return;
        }
        // Through the daemon's local door: it adds the Referer these hosts
        // insist on and streams the parts as the player asks for them, so
        // playback starts at once instead of after a whole download.
        Client.call("stream", { "id": root.item.id, "url": url }, function (err, payload) {
            if (root.wanted !== failedOn)
                return;
            if (err || !payload || !payload.url) {
                // No local port, or the page would not say: fall back to
                // fetching the file outright.
                root.fetchLocal(failedOn, err || "", url);
                return;
            }
            root.fetching = false;
            player.source = payload.url;
            if (root.active)
                player.play();
        });
    }

    /// Ask the daemon for a local copy — of a chosen quality when there is one.
    function fetchLocal(failedOn, why, url) {
        if (!root.item || !Client.connected) {
            root.fetching = false;
            return;
        }
        root.fetching = true;
        const asked = { "id": root.item.id };
        const picked = url && url.length > 0 ? url
            : (root.qualities.find(q => q.label === root.quality) || {}).url;
        if (picked)
            asked.url = picked;
        Client.call("media", asked, function (err, payload) {
            if (root.wanted !== failedOn)
                return;     // moved on while it downloaded
            root.fetching = false;
            if (err || !payload || !payload.path) {
                root.failure = root.say("This video could not be played", err || why);
                return;
            }
            player.source = "file://" + payload.path;
            if (root.active)
                player.play();
        }, 900000);
    }

    /// What went wrong, shown rather than swallowed — a codec the system cannot
    /// decode is a real answer, and an empty black pane is not.
    property string failure: ""
    /// The url whose stream failed and is now being fetched through quarryd.
    property string _viaQuarry: ""
    property bool fetching: false

    // ── the tools ───────────────────────────────────────────────────────────

    property bool looping: true
    property real rate: 1.0

    /*
     * THE BAR'S LOOK, FOR AN APP THAT EMBEDS THIS PANE.
     *
     * The defaults are the gallery's: a solid pill. reel puts the controls
     * straight over a scrim on the picture — no box — with the play button in
     * the accent colour, so it sets these instead of forking the file.
     */
    property color barColor: Appearance.colors.colSurfaceContainerHighest
    property color barBorderColor: Appearance.colors.colOutlineVariant
    property color controlIconColor: Appearance.colors.colOnLayer1
    property color controlTextColor: Appearance.colors.colOnLayer1
    /// Play/pause as a filled accent circle rather than a plain icon.
    property bool filledPlay: false
    /// Keep the controls up — the embedding app sets this while the pointer
    /// is on chrome of its own (a title row, an open panel), which this pane
    /// cannot see: it reads that as the pointer leaving, and hid everything.
    property bool holdControls: false
    /// The time under the pointer on the timeline (ms), or -1, and where that
    /// is across this pane — for a preview still above it.
    property real _scrubX: -1
    readonly property real scrubHoverMs: root._scrubX >= 0 && player.duration > 0 && scrubber.width > 0
        ? Math.max(0, Math.min(1, root._scrubX / scrubber.width)) * player.duration : -1
    readonly property real scrubHoverX: root._scrubX >= 0 ? scrubber.mapToItem(root, root._scrubX, 0).x : -1
    readonly property real scrubTopY: controlBar.y
    onHoldControlsChanged: if (!root.holdControls) root.wake()
    /// How the picture fills the pane.
    property int fillMode: VideoOutput.PreserveAspectFit
    /// How long the controls stay after the pointer stops, while playing.
    property int idleMs: 2600
    /// Where "save this frame" writes.
    property string framesDir: `${Quickshell.env("HOME")}/.cache/quarry/frames`
    /// "png" | "jpg" — grabToImage picks the encoder from the extension.
    property string framesFormat: "png"
    /// Name frames after the title rather than the row id.
    property bool framesByTitle: false
    /// Which of the bar's tools are shown.
    property bool showFrameButtons: true
    property bool showScreenshotButton: true
    property bool showSpeedButton: true
    property bool showLoopButton: true
    /// Elapsed, or time left. Both are useful and neither is right for
    /// everyone, so the label is a button rather than a decision.
    property bool showRemaining: false

    readonly property var rates: [0.25, 0.5, 1.0, 1.25, 1.5, 2.0]

    function cycleRate() {
        const at = root.rates.indexOf(root.rate);
        root.rate = root.rates[(at + 1) % root.rates.length];
    }

    /// Move by `ms`, clamped — seeking past the end of a non-looping video
    /// stops it, which is not what pressing "forward" is asking for.
    function nudge(ms) {
        if (!(player.duration > 0))
            return;
        player.position = Math.max(0, Math.min(player.duration - 1, player.position + ms));
    }

    /*
     * A frame at a time, and only while paused.
     *
     * The reason this is here at all: a video source is a way of FINDING a
     * still. The frame you want for an avatar is rarely the poster frame, and
     * without a step you are dragging a scrubber at 1/500th of its width and
     * hoping. 40 ms is a frame at 25 fps and close enough at 30 — QtMultimedia
     * exposes no frame-accurate step, so this is honest about being a nudge.
     */
    function stepFrame(direction) {
        player.pause();
        root.nudge(direction * 40);
    }

    /*
     * THE FRAME ON SCREEN, WRITTEN OUT.
     *
     * The one tool a gallery's video player needs that a media player does not.
     * `grabToImage` takes what the scene graph is actually drawing, so what is
     * saved is the frame you stopped on — not a re-decode that lands somewhere
     * near it.
     */
    signal frameGrabbed(string path)

    function grabFrame() {
        if (!root.item)
            return;
        /*
         * Nothing on screen is not a frame.
         *
         * The output is held at opacity 0 until `ready`, and grabToImage takes
         * what is DRAWN — so pressing this while the clip was still opening,
         * or after stepping back to position zero, wrote out a fully
         * transparent PNG and reported success.
         */
        if (!root.ready) {
            Toast.error("Nothing to save yet — let the video start");
            return;
        }
        const dir = root.framesDir;
        const at = Math.floor(player.position);
        // Which clip this grab belongs to, read now. Both steps below are
        // asynchronous, and stepping to the next item mid-grab used to save the
        // NEW video's picture under the OLD one's name.
        const on = root.wanted;
        const stem = root.framesByTitle && root.item.title ? String(root.item.title).replace(/\.[^.]+$/, "") : String(root.item.id);
        const path = `${dir}/${stem.replace(/[^A-Za-z0-9_.-]/g, "_")}-${at}.${root.framesFormat}`;
        // `saveToFile` does not create directories and reports the failure as
        // a bare false, so the folder is made first rather than diagnosed after.
        Sys.run(["mkdir", "-p", dir], function () {
            if (root.wanted !== on)
                return;
            output.grabToImage(function (result) {
                if (root.wanted !== on)
                    return;
                if (result.saveToFile(path))
                    root.frameGrabbed(path);
                else
                    Toast.error("Could not write the frame");
            });
        });
    }

    VideoOutput {
        id: output
        anchors.fill: parent
        fillMode: root.fillMode
        opacity: root.ready ? 1 : 0
        Behavior on opacity {
            NumberAnimation {
                duration: 180
                easing.type: Easing.OutCubic
            }
        }
    }

    /*
     * THE CONTROLS COME BACK WHEN YOU MOVE THE POINTER.
     *
     * They were revealed by hovering the BAR — which, while playing, is fully
     * transparent. To bring back the controls you had to already know where
     * they were and put the pointer inside a strip you could not see, and every
     * other pixel of the video did nothing. From the outside that is a player
     * with no controls at all.
     *
     * So the whole pane wakes them, and they fade out again after a few seconds
     * of stillness — the ordinary contract for video chrome. While paused they
     * simply stay: nothing is moving, so nothing is being covered up.
     */
    property bool chromeAwake: true

    function wake() {
        root.chromeAwake = true;
        // Only a playing video hides its controls. Restarting the timer while
        // paused would take them away from someone reading the scrubber.
        if (root.playing)
            idle.restart();
        else
            idle.stop();
    }

    /*
     * A MouseArea rather than a HoverHandler, for one reason: `positionChanged`.
     *
     * Movement is the signal here, not merely being inside the pane — sitting
     * still should let the controls fade and the next twitch should bring them
     * back. HoverHandler's `point` is a grouped value type whose change signal
     * cannot be relied on for that; `onPositionChanged` is exactly it.
     *
     * `Qt.NoButton` so it takes no clicks: it is declared before the control
     * bar, so the bar's buttons sit above it and keep working, and the wheel
     * still reaches the detail view's step handler.
     */
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        hoverEnabled: true
        propagateComposedEvents: true

        onPositionChanged: root.wake()
        onEntered: root.wake()
        onExited: {
            if (root.playing)
                root.chromeAwake = false;
        }
    }

    Timer {
        id: idle
        interval: root.idleMs
        onTriggered: {
            // Never while the scrubber is held — the bar cannot leave from
            // under a drag that is still happening.
            if (root.playing && !scrubber.held && !root.holdControls)
                root.chromeAwake = false;
        }
    }

    // A pause is a request to look at the frame AND at the controls.
    onPlayingChanged: root.wake()

    /*
     * THE KEYS, SO THE TOOLS ARE NOT ONLY BUTTONS.
     *
     * Scrubbing a video to find one frame is the kind of thing you do with two
     * hands on the keyboard, not by aiming at a 30px target thirty times.
     * `Keys` rather than Shortcut: this pane is one of several in an overlay,
     * and a global shortcut would still fire with a still image on screen.
     */
    focus: root.active && root.isVideo
    Keys.onPressed: event => {
        event.accepted = root.handleKey(event);
    }

    /*
     * …EXCEPT THE KEYS NEVER ARRIVED.
     *
     * `focus: true` here asks for focus in the enclosing scope, but the viewer
     * around this pane calls forceActiveFocus() on ITSELF when it opens, and
     * neither is a FocusScope — so the viewer held the focus and this handler
     * was never reached. Measured, with a video open and playing: activeFocus
     * false. Every shortcut the buttons advertise in their tooltips — s to save
     * the frame, comma and full stop to step, l to loop, ] for speed — did
     * nothing at all, and the two that did work (space, m) worked only because
     * the viewer had special-cased them by hand.
     *
     * So the map lives in a function the viewer calls first. It answers whether
     * it took the key, and anything it does not take falls through to the
     * viewer as before.
     */
    function handleKey(event) {
        switch (event.key) {
        case Qt.Key_Space:
            root.toggle();
            break;
        case Qt.Key_Left:
            root.nudge(event.modifiers & Qt.ShiftModifier ? -60000 : -10000);
            break;
        case Qt.Key_Right:
            root.nudge(event.modifiers & Qt.ShiftModifier ? 60000 : 10000);
            break;
        case Qt.Key_Comma:
            root.stepFrame(-1);
            break;
        case Qt.Key_Period:
            root.stepFrame(1);
            break;
        case Qt.Key_M:
            Prefs.videoSound = !Prefs.videoSound;
            break;
        case Qt.Key_L:
            root.looping = !root.looping;
            break;
        case Qt.Key_S:
            root.grabFrame();
            break;
        case Qt.Key_BracketRight:
            root.cycleRate();
            break;
        default:
            return false;            // anything else belongs to the overlay
        }
        return true;
    }

    // ── the controls ────────────────────────────────────────────────────────

    /// Darken the bottom of the picture behind the controls — for a bar with
    /// no box of its own (reel). Declared here so it sits between the video
    /// and the controls, which an embedding app cannot do from outside.
    property bool scrim: false
    Rectangle {
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: Math.min(parent.height * 0.4, 200)
        visible: root.scrim && root.isVideo && controlBar.opacity > 0.01
        opacity: controlBar.opacity
        gradient: Gradient {
            GradientStop { position: 0; color: "transparent" }
            GradientStop { position: 0.5; color: Qt.rgba(0, 0, 0, 0.42) }
            GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.8) }
        }
    }

    /*
     * A PILL, THE WAY RODDED DRAWS ONE.
     *
     * The old bar was a play button, a clock and a raw slider — and the slider
     * was bound straight to `player.position`, so the player fought every drag
     * and snapped the handle back to the playhead. It could not be used to find
     * a moment, which is the only thing a scrubber is for.
     *
     * It hides while playing and comes back on hover, because the picture is
     * the point; it stays put while you are actually holding the scrubber, or
     * it would vanish out from under the drag.
     */
    Rectangle {
        id: controlBar
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 16
        /*
         * Width comes from the PANE, not from the contents: sizing to content
         * is what starved the timeline. Capped, because a bar stretched across
         * a 3000px screen puts the play button and the frame grab a foot apart.
         */
        implicitWidth: Math.min(root.width - 32, 1180)
        implicitHeight: 92
        radius: Appearance.rounding.verylarge
        color: root.barColor
        border.width: 1
        border.color: root.barBorderColor
        antialiasing: true

        visible: root.isVideo && opacity > 0.01
        opacity: root.chromeAwake || root.holdControls || hover.hovered || scrubber.held || !root.playing ? 1 : 0

        /*
         * HOW MUCH OF THE BOTTOM THIS PANEL OWNS.
         *
         * Anything else that floats at the bottom of the window — the script
         * docks — has no way of knowing this bar is here, and a dock parked on
         * top of the scrub bar is a dock you have to move the mouse around.
         * Host.bottomInset is the channel for exactly this and nothing was
         * filling it, so the dock was placed by a number typed in by hand and
         * landed in the middle of the controls.
         *
         * Reported whether or not the bar is faded out: it comes back the
         * moment the pointer moves, and a dock that drops onto the controls
         * every time they fade would be worse than one that stays clear.
         */
        Binding {
            target: Host
            property: "bottomInset"
            value: controlBar.anchors.bottomMargin + controlBar.implicitHeight
            when: root.isVideo && root.visible
            restoreMode: Binding.RestoreBindingOrValue
        }
        Behavior on opacity {
            NumberAnimation {
                duration: Appearance.animDur(160)
            }
        }
        Behavior on implicitWidth {
            NumberAnimation {
                duration: Appearance.animDur(220)
                easing.type: Easing.OutCubic
            }
        }

        HoverHandler {
            id: hover
        }

        /*
         * TWO ROWS, BECAUSE THE TIMELINE IS THE POINT.
         *
         * It was one row, and the scrubber said `Layout.fillWidth` under a
         * comment promising it "takes whatever is left" — but the pill sized
         * itself to `bar.implicitWidth`, which is its own content, so there
         * never WAS anything left. Measured on a 1244px pane: an 84px scrubber
         * in a 642px bar. Thirteen per cent. One pixel per eight seconds of a
         * ten minute clip — not a control, a rounding error.
         *
         * So the timeline gets a row of its own at the full width of the bar,
         * and the bar takes its width from the PANE rather than from what is
         * inside it. The buttons sit underneath in two groups: what plays the
         * video on the left, what the video is FOR on the right. They thin out
         * from the middle as the pane narrows, and the frame grab — the reason
         * a gallery's player is not just a player — is no longer the first
         * thing overboard, which is what the old order had it as.
         */
        ColumnLayout {
            id: bar
            anchors.fill: parent
            anchors.leftMargin: 18
            anchors.rightMargin: 18
            anchors.topMargin: 9
            anchors.bottomMargin: 7
            spacing: 2

            // ── the timeline, and nothing else ──────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                spacing: 12

                // Elapsed or remaining, whichever you asked for. A click swaps
                // it. No fixed width cap: an hour-long clip reads 1:23:45 and
                // the row is wide enough now to simply let it.
                StyledText {
                    Layout.minimumWidth: 52
                    horizontalAlignment: Text.AlignRight
                    text: {
                        const at = scrubber.held ? scrubber.value : player.position;
                        if (!root.showRemaining)
                            return root.clock(at);
                        return "-" + root.clock(Math.max(0, player.duration - at));
                    }
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: scrubber.held ? Appearance.colors.colPrimary : root.controlTextColor

                    TapHandler {
                        gesturePolicy: TapHandler.ReleaseWithinBounds
                        onTapped: root.showRemaining = !root.showRemaining
                    }
                    StyledToolTip {
                        visible: seekHov.hovered
                        text: root.showRemaining ? "Show elapsed" : "Show what is left"
                    }
                    HoverHandler {
                        id: seekHov
                        cursorShape: Qt.PointingHandCursor
                    }
                }

                /*
                 * Bound only while you are not holding it — see StyledSlider.
                 * The seek is issued once, on release: seeking on every pixel
                 * of the drag is a request per frame, and on a streamed source
                 * that stutters far worse than the drag being slightly behind.
                 */
                StyledSlider {
                    id: scrubber

                    // Where the pointer is over the timeline, for a preview — see scrubHoverMs.
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        hoverEnabled: true
                        onPositionChanged: m => root._scrubX = m.x
                        onExited: root._scrubX = -1
                    }
                    Layout.fillWidth: true
                    Layout.minimumWidth: 120
                    // A step up in weight from the volume's XS. The slider's
                    // whole design puts hierarchy in the TRACK, and this is the
                    // control the bar exists for; they used to be identical.
                    configuration: StyledSlider.Configuration.S
                    /*
                     * The handle moves at the speed the video does.
                     *
                     * This was off, because the widget's default velocity is a
                     * UI speed and the range here is milliseconds of video — so
                     * smoothing made the handle crawl. Off, though, means the
                     * handle only moves when the player reports a position,
                     * which is a few times a second: it sat still and jumped,
                     * for the length of the clip.
                     *
                     * 1000 value-units per second IS one second of video per
                     * second of real time, times whatever speed you are playing
                     * at — so between reports the handle glides exactly where
                     * the picture is, and a seek still lands within 220ms.
                     */
                    smoothValue: true
                    // A stopped picture must not have a moving handle: see smoothPaused.
                    smoothPaused: !root.playing
                    smoothVelocity: 1000 * Math.max(0.05, root.rate)
                    enabled: player.seekable
                    from: 0
                    to: Math.max(1, player.duration)
                    readout: root.clock(scrubber.value)
                    buffered: player.duration > 0 ? player.bufferProgress : -1

                    onPressedChanged: {
                        if (pressed)
                            return;
                        /*
                         * Read the drop point BEFORE the binding comes back:
                         * the moment `held` goes false the Binding overwrites
                         * `value` with the playhead, and seeking after that
                         * lands you where playback already was rather than
                         * where you let go.
                         */
                        player.position = scrubber.value;
                    }

                    Binding {
                        target: scrubber
                        property: "value"
                        value: player.position
                        when: !scrubber.held
                        restoreMode: Binding.RestoreNone
                    }
                }

                StyledText {
                    Layout.minimumWidth: 52
                    text: player.duration > 0 ? root.clock(player.duration) : "--:--"
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: Appearance.font.pixelSize.small
                    // Was the outline role — a border colour, used as text, on
                    // a light surface. Same colour as its twin, held back by
                    // opacity instead, which is a difference in emphasis rather
                    // than a difference in kind.
                    color: root.controlTextColor
                    opacity: 0.7
                }
            }

            // ── what plays it, and what it is for ───────────────────────────
            RowLayout {
                Layout.fillWidth: true
                spacing: 2

                IconButton {
                    visible: root.width >= 420
                    icon: "replay_10"
                    tooltip: "Back 10 seconds  (←)"
                    size: 36
                    iconColor: toggled ? Appearance.colors.colOnSecondaryContainer : root.controlIconColor
                    onClicked: root.nudge(-10000)
                }

                IconButton {
                    icon: root.playing ? "pause" : "play_arrow"
                    tooltip: root.playing ? "Pause  (space)" : "Play  (space)"
                    size: root.filledPlay ? 44 : 40
                    iconSize: Appearance.font.pixelSize.huge
                    // Filled: an accent disc under the button, which keeps its
                    // own hover/press tint — now a wash of the icon colour.
                    iconColor: root.filledPlay ? Appearance.colors.colOnPrimary : root.controlIconColor
                    hoverColor: root.filledPlay ? ColorUtils.transparentize(Appearance.colors.colOnPrimary, 0.84) : Appearance.colors.colLayer1Hover
                    fill: root.filledPlay ? 1 : 0
                    onClicked: root.toggle()

                    Rectangle {
                        anchors.fill: parent
                        z: -1
                        visible: root.filledPlay
                        radius: width / 2
                        color: Appearance.colors.colPrimary
                    }
                }

                IconButton {
                    visible: root.width >= 420
                    icon: "forward_10"
                    tooltip: "Forward 10 seconds  (→)"
                    size: 36
                    iconColor: toggled ? Appearance.colors.colOnSecondaryContainer : root.controlIconColor
                    onClicked: root.nudge(10000)
                }

                Item {
                    Layout.preferredWidth: 8
                }

                // A frame at a time — only meaningful while stopped, and it
                // says so by leaving rather than by greying out into a puzzle.
                IconButton {
                    visible: root.showFrameButtons && !root.playing && root.width >= 560
                    icon: "skip_previous"
                    tooltip: "A frame back  (,)"
                    size: 36
                    iconColor: toggled ? Appearance.colors.colOnSecondaryContainer : root.controlIconColor
                    onClicked: root.stepFrame(-1)
                }
                IconButton {
                    visible: root.showFrameButtons && !root.playing && root.width >= 560
                    icon: "skip_next"
                    tooltip: "A frame on  (.)"
                    size: 36
                    iconColor: toggled ? Appearance.colors.colOnSecondaryContainer : root.controlIconColor
                    onClicked: root.stepFrame(1)
                }

                Item {
                    Layout.preferredWidth: 8
                    visible: root.showFrameButtons && !root.playing && root.width >= 560
                }

                // Sound sits with the transport, where every player puts it.
                IconButton {
                    icon: Prefs.videoSound ? (volume.value > 0.5 ? "volume_up" : "volume_down") : "volume_off"
                    tooltip: Prefs.videoSound ? "Mute  (m)" : "Unmute  (m)"
                    size: 36
                    iconColor: toggled ? Appearance.colors.colOnSecondaryContainer : root.controlIconColor
                    onClicked: Prefs.videoSound = !Prefs.videoSound
                }

                StyledSlider {
                    id: volume
                    visible: root.width >= 620
                    Layout.preferredWidth: 86
                    configuration: StyledSlider.Configuration.XS
                    from: 0
                    to: 1
                    readout: `${Math.round(volume.value * 100)}%`
                    onMoved: {
                        Prefs.videoVolume = volume.value;
                        // Dragging the volume up is asking to hear it. Leaving
                        // it muted while the slider says 70% would be a control
                        // that lies about what it just did.
                        Prefs.videoSound = true;
                    }

                    /*
                     * The same guard the scrubber has, for the same reason.
                     *
                     * `value: Prefs.videoVolume` as a plain binding survives
                     * exactly until the first drag: dragging a Slider writes
                     * `value` imperatively and the binding is gone for good, so
                     * the volume set anywhere else — the settings panel, another
                     * window — stopped reaching this control after one touch.
                     */
                    Binding {
                        target: volume
                        property: "value"
                        value: Prefs.videoVolume
                        when: !volume.pressed
                        restoreMode: Binding.RestoreNone
                    }
                }

                // The gap that makes two groups out of one strand of icons.
                Item {
                    Layout.fillWidth: true
                    Layout.minimumWidth: 12
                }

                /*
                 * WHAT SCRIPTS AND EXTENSIONS PUT IN THE TIMELINE.
                 *
                 * A dock that applies while something is open belongs IN this
                 * bar, not floating over it — which is where it used to sit,
                 * on top of the scrub bar, because it had nowhere else to be.
                 * The controls come from the same list the strip over the wall
                 * uses, so one declaration lands in both places, and
                 * `Host.registerDock` means an extension gets a seat here with
                 * no change to this file.
                 *
                 * Only docks that said they belong over a viewer: a control for
                 * the wall behind is not wanted while you are looking at this.
                 */
                Repeater {
                    model: Scripts.revision >= 0 && Prefs.scriptsEnabled
                        ? Scripts.openDocks().filter(d => d.overViewer) : []

                    delegate: ScriptDock {
                        required property var modelData

                        inline: true
                        dock: modelData
                        Layout.alignment: Qt.AlignVCenter
                    }
                }

                /*
                 * The reason a gallery's player is not just a player.
                 *
                 * A video is a way of finding a still: the frame you want for
                 * an avatar is almost never the poster frame. This writes out
                 * exactly what is on screen, so a clip becomes a picture you
                 * can use — and it now outlives the generic transport buttons
                 * when the pane narrows instead of going first.
                 */
                IconButton {
                    visible: root.showScreenshotButton
                    icon: "photo_camera"
                    tooltip: "Save this frame  (s)"
                    size: 36
                    iconColor: toggled ? Appearance.colors.colOnSecondaryContainer : root.controlIconColor
                    onClicked: root.grabFrame()
                }

                // Speed, as a label rather than a menu: six values, one click
                // each, and the current one is always readable without opening
                // anything. It keeps a faint outline at 1× — with none at all
                // it read as a caption that happened to be clickable.
                Rectangle {
                    visible: root.showSpeedButton && root.width >= 480
                    Layout.preferredWidth: 46
                    Layout.preferredHeight: 30
                    radius: Appearance.rounding.small
                    color: rateTap.pressed ? Appearance.colors.colLayer2Active : rateHov.hovered ? Appearance.colors.colLayer2Hover : root.rate === 1 ? "transparent" : Appearance.colors.colSecondaryContainer
                    border.width: root.rate === 1 ? 1 : 0
                    border.color: Appearance.colors.colOutlineVariant

                    StyledText {
                        anchors.centerIn: parent
                        text: `${root.rate}×`
                        font.family: Appearance.font.family.monospace
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: root.rate === 1 ? Appearance.colors.colSubtext : Appearance.colors.colOnSecondaryContainer
                    }

                    HoverHandler {
                        id: rateHov
                        cursorShape: Qt.PointingHandCursor
                    }
                    TapHandler {
                        id: rateTap
                        gesturePolicy: TapHandler.ReleaseWithinBounds
                        onTapped: root.cycleRate()
                    }
                    StyledToolTip {
                        visible: rateHov.hovered
                        text: "Playback speed  (])"
                    }
                }

                IconButton {
                    visible: root.showLoopButton && root.width >= 400
                    icon: "repeat"
                    tooltip: root.looping ? "Stop looping  (l)" : "Loop this  (l)"
                    size: 36
                    iconColor: toggled ? Appearance.colors.colOnSecondaryContainer : root.controlIconColor
                    toggled: root.looping
                    onClicked: root.looping = !root.looping
                }

                IconButton {
                    id: qualityButton
                    visible: root.qualities.length > 1
                    icon: "high_quality"
                    tooltip: root.quality.length > 0 ? `Quality · ${root.quality}` : "Quality"
                    size: 36
                    iconColor: toggled ? Appearance.colors.colOnSecondaryContainer : root.controlIconColor
                    toggled: qualityMenu.visible
                    onClicked: {
                        if (qualityMenu.visible) {
                            qualityMenu.close();
                            return;
                        }
                        // Only the anchor is recorded here. Where the menu
                        // lands is a binding on its own size — see qualityMenu.
                        const at = qualityButton.mapToItem(root, qualityButton.width / 2, 0);
                        root._menuAnchor = Qt.point(at.x, at.y);
                        qualityMenu.open();
                    }
                }
            }
        }
    }

    Column {
        anchors.centerIn: parent
        spacing: 10
        visible: root.fetching && !root.ready
        LoadingIndicator {
            anchors.horizontalCenter: parent.horizontalCenter
        }
        StyledText {
            anchors.horizontalCenter: parent.horizontalCenter
            color: Appearance.colors.colSubtext
            text: "Fetching the video through quarry…"
        }
    }

    // A codec the machine cannot handle, said out loud.
    StyledText {
        anchors.centerIn: parent
        visible: root.failure.length > 0 && !root.ready
        width: parent.width * 0.7
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        color: Appearance.colors.colSubtext
        text: root.failure
    }

    /// Where the quality menu points: the middle of its button's top edge.
    property point _menuAnchor: Qt.point(0, 0)
    /// For the `app quality` probe: the menu, so its place can be measured.
    readonly property alias qualityPopup: qualityMenu

    /// Open the quality menu the way its button does. False when this video
    /// has only one quality and there is nothing to choose.
    function showQualities() {
        if (root.qualities.length < 2)
            return false;
        const at = qualityButton.mapToItem(root, qualityButton.width / 2, 0);
        root._menuAnchor = Qt.point(at.x, at.y);
        qualityMenu.open();
        return true;
    }

    /*
     * Small: four sizes and a default, over a video someone is watching.
     *
     * Its place is BOUND, not assigned once when it opens. Assigned, it was
     * measured before its rows existed — the menu was one row tall at that
     * moment, so "above the button" put its top near the button and the rest
     * of the list ran off the bottom of the pane, half of it unreachable. A
     * binding re-places it the moment it knows how tall it really is, and the
     * second clamp keeps its bottom inside the pane.
     */
    MenuPopup {
        id: qualityMenu
        minWidth: 168
        x: Math.max(8, Math.min(root._menuAnchor.x - qualityMenu.width / 2, root.width - qualityMenu.width - 8))
        y: Math.max(8, Math.min(root._menuAnchor.y - qualityMenu.height - 10, root.height - qualityMenu.height - 8))

        MenuRow {
            text: "Automatic"
            icon: "auto_awesome"
            checked: Prefs.videoQuality === "auto"
            onTriggered: {
                Prefs.videoQuality = "auto";
                qualityMenu.close();
            }
        }

        MenuRow {
            separator: true
        }

        Repeater {
            model: root.qualities
            delegate: MenuRow {
                required property var modelData
                text: modelData.label
                icon: "smart_display"
                hint: modelData.w > 0 ? `${modelData.w}×${modelData.h}` : ""
                checked: root.quality === modelData.label
                onTriggered: {
                    // Remembered by name, so the next clip opens the same way.
                    Prefs.videoQuality = modelData.label;
                    root.playQuality(modelData);
                    qualityMenu.close();
                }
            }
        }
    }
}
