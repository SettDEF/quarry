import "../fmt.js" as Fmt
import QtMultimedia
import QtQuick
import QtQuick.Layouts
import qs.modules.common
import qs.modules.widgets
import qs.services

/*
 * ONE PICTURE OR CLIP, THE WAY A PHONE SHOWS IT.
 *
 * Telegram's viewer, which is what anybody reading a chat already knows: the
 * picture on black, filling the screen; the bars float over it on a gradient
 * and get out of the way when you stop moving; one slim strip of the chat's
 * other media along the bottom with where you are in the middle of it. The
 * wheel zooms toward the pointer, a drag pans, a double click is 100%.
 *
 * This replaced two opaque bars stacked under a picture that ran beneath its
 * own thumbnail drawer, on a background you could see the chat through.
 *
 * The wall and the conversation draw thumbnails; this is where the real file
 * is asked for. Until it lands the thumbnail stands in, so opening something
 * is never a blank screen.
 */
Item {
    id: root

    required property var lens
    readonly property var message: root.lens.viewing
    readonly property var media: root.message ? root.message.media : null
    /// The full file. For a clip, only once its quick variant is complete, so
    /// the original does not compete with the bytes playback is waiting for.
    /// A lens instance from before streaming (a skin reloads under a running
    /// lens, which keeps its old Main) plays the finished file as it used to.
    readonly property bool streams: typeof root.lens.playOf === "function"
    readonly property string file: !root.message ? "" : root.streams && Fmt.isMoving(root.media) && !root.lens.smallReady(root.message) ? root.lens.heldOriginal(root.message) : root.lens.fileOf(root.message)
    /// What the player opens — see `playOf` on the lens.
    readonly property string playUrl: !root.moving ? "" : root.streams ? root.lens.playOf(root.message) : root.file
    /// Playing a part-written file: it will run dry, and is reopened.
    readonly property bool live: root.streams && root.lens.isLive(root.message, root.playUrl)
    /// Where to pick up after a reopen or a switch to a better file.
    property real resumeAt: 0
    property bool stalled: false
    property real stalledBytes: 0
    /// Where the clip is, in ms — read by probes and tests.
    readonly property real position: player.position
    /// The real thumbnail, and separately the thirty-pixel blob that stands
    /// in for it — the blob is drawn blurred rather than magnified. See Shot.
    readonly property string thumb: root.message ? root.lens.realThumbOf(root.message) : ""
    readonly property string mini: root.message ? root.lens.miniOf(root.message) : ""
    readonly property bool fetching: root.message ? root.lens.isFetchingFile(root.message) : false
    readonly property bool moving: Fmt.isMoving(root.media)
    readonly property bool playing: player.playbackState === MediaPlayer.PlayingState
    /// A voice note is a clip with no picture: it wants the same bar, and the
    /// same bar is what it gets.
    readonly property bool hasPlayer: root.moving && root.playUrl.length > 0

    /*
     * ZOOM: 1 is the picture fitted to the screen; more is closer. The wheel
     * zooms toward the pointer, a drag pans once it is bigger than the screen,
     * a double click jumps between fitted and real pixels.
     */
    property real zoom: 1
    readonly property real maxZoom: 8
    /// The bars over the picture. They leave when the pointer rests, and any
    /// movement or a tap brings them back.
    property bool chrome: true

    signal contextRequested(var message, real sceneX, real sceneY)

    /*
     * FULL SCREEN MEANS THE WHOLE SCREEN.
     *
     * The viewer filled the lens's pane — inside the app's card, beside the
     * rail, under the search bar — with no way to give a clip the screen. Full
     * screen lifts it into the window's overlay, hides the app's chrome and
     * makes the window itself full screen; leaving puts all three back as they
     * were.
     */
    /// The skin lifts the viewer into the window's overlay while this is set.
    property bool full: false
    property bool _wasFullscreen: false
    property bool _wasSuppressed: false

    function setFull(on) {
        if (on === root.full)
            return;
        const win = Shell.window;
        if (on) {
            root._wasFullscreen = !!win && win.fullscreen === true;
            root._wasSuppressed = Host.chromeSuppressed;
            Host.chromeSuppressed = true;
            if (win)
                win.fullscreen = true;
        } else {
            Host.chromeSuppressed = root._wasSuppressed;
            if (win && !root._wasFullscreen)
                win.fullscreen = false;
        }
        root.full = on;
        root.forceActiveFocus();
    }

    function clock(ms) {
        if (!(ms > 0))
            return "0:00";

        const total = Math.floor(ms / 1000);
        const minutes = Math.floor(total / 60);
        const seconds = total % 60;
        return `${minutes}:${seconds < 10 ? "0" : ""}${seconds}`;
    }

    visible: root.message !== null
    focus: root.message !== null
    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Escape && root.full)
            root.setFull(false);
        else if (event.key === Qt.Key_Escape)
            root.lens.closeViewer();
        else if (event.key === Qt.Key_F)
            root.setFull(!root.full);
        else if (event.key === Qt.Key_Left)
            root.lens.viewerStep(-1);
        else if (event.key === Qt.Key_Right)
            root.lens.viewerStep(1);
        // Space plays a clip; on a picture it is the next one, as before.
        else if (event.key === Qt.Key_Space && root.hasPlayer)
            root.playing ? player.pause() : player.play();
        else if (event.key === Qt.Key_Space)
            root.lens.viewerStep(1);
        else if (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal)
            root.zoomAt(root.zoom * 1.25, frame.width / 2, frame.height / 2);
        else if (event.key === Qt.Key_Minus)
            root.zoomAt(root.zoom / 1.25, frame.width / 2, frame.height / 2);
        else if (event.key === Qt.Key_0)
            root.zoomAt(1, frame.width / 2, frame.height / 2);
        else if (event.key === Qt.Key_M)
            Prefs.videoSound = !Prefs.videoSound;
        else if (event.key === Qt.Key_K)
            root.lens.take(root.message, null);
        else
            return ;
        event.accepted = true;
    }
    onMessageChanged: {
        // Closing the viewer gives the app its chrome and its window back.
        if (!root.message)
            root.setFull(false);
        root.zoom = 1;
        frame.contentX = 0;
        frame.contentY = 0;
        root.wake();
        // The arrow keys are how a wall is walked; `focus: true` alone only
        // puts this in line for the keyboard.
        if (root.message)
            root.forceActiveFocus();

        // `heldFile` never asks; the asking is a step, not a paint.
        root.resumeAt = 0;
        root.stalled = false;
        if (root.message && (!root.moving || !root.streams))
            root.lens.fileOf(root.message);

    }

    /*
     * A BETTER FILE, OR MORE OF THE SAME ONE, AT THE SAME MOMENT.
     *
     * The url moves from the part-written quick variant to the finished one
     * and then to the original; each move keeps the position rather than
     * starting the clip again.
     */
    onPlayUrlChanged: root._open(root.playUrl, true)

    property string _openedFor: ""
    /// Clearing the source reports the OLD media "loaded" once more; the seek
    /// waits until the new file has actually been through loading.
    property bool _seekArmed: false
    /// The last position actually played. At a part-written file's end the
    /// player reports the clip's FULL length (the index knows it), so the
    /// reopen resumed at 2:00 of a clip that had played seven seconds.
    property real _lastPos: 0
    readonly property string _clipKey: root.message ? `${root.message.chatId || ""}:${root.message.id}` : ""

    function _open(url, keep) {
        // Only the same clip keeps its moment: stepping to the next one changes
        // its url too, and must not start it where the last one was.
        // Compared by id: the same message read twice is two JS wrappers.
        if (keep && root._openedFor === root._clipKey && String(player.source).length > 0 && root._lastPos > 0)
            root.resumeAt = root._lastPos;
        else if (root._openedFor !== root._clipKey)
            root._lastPos = 0;
        root._openedFor = root._clipKey;
        root._seekArmed = false;
        player.source = "";
        player.source = url;
    }

    // A part-written file ends where the download had got to. More arrived:
    // reopen it there.
    Connections {
        target: root.lens

        function onPartialRevisionChanged() {
            if (root.stalled && root.live && root.streams && root.lens.liveBytes(root.message) > root.stalledBytes + 256 * 1024) {
                root.stalled = false;
                root._open(root.playUrl, false);
            }
        }
    }

    MediaPlayer {
        id: player

        // Set by `_open`, never bound: a reopen has to be able to set the
        // same url again.
        // A clip in a chat is short and usually watched twice; looping is what
        // every messenger does with them — but not a part-written file, whose
        // end is only where the download has got to.
        loops: root.live ? 1 : MediaPlayer.Infinite
        // Steps of a frame or a seek we made, not the jump to the end.
        onPositionChanged: {
            const at = player.position;
            if (Math.abs(at - root._lastPos) < 2000 || root._lastPos === 0 && at < 2000)
                root._lastPos = at;
        }
        onSourceChanged: {
            if (String(source).length > 0)
                play();
        }
        onMediaStatusChanged: {
            if (mediaStatus === MediaPlayer.LoadingMedia)
                root._seekArmed = true;
            if (root._seekArmed && (mediaStatus === MediaPlayer.LoadedMedia || mediaStatus === MediaPlayer.BufferedMedia) && root.resumeAt > 0) {
                setPosition(root.resumeAt);
                root._lastPos = root.resumeAt;
                root.resumeAt = 0;
            }
            if ((mediaStatus === MediaPlayer.EndOfMedia || mediaStatus === MediaPlayer.InvalidMedia) && root.live) {
                root.resumeAt = Math.max(0, root._lastPos - 500);
                root.stalled = true;
                root.stalledBytes = root.lens.liveBytes(root.message);
            }
        }

        audioOutput: AudioOutput {
            muted: !Prefs.videoSound
            volume: Prefs.videoVolume
        }

    }

    // ── zoom ─────────────────────────────────────────────────────────────────

    /// Zoom to `to`, keeping the point under (x, y) — in the frame's own
    /// coordinates — where it is, which is what makes wheel zoom feel aimed.
    function zoomAt(to, x, y) {
        const next = Math.max(1, Math.min(root.maxZoom, to));
        if (Math.abs(next - root.zoom) < 0.001)
            return;
        const px = (frame.contentX + x) / Math.max(1, frame.contentWidth);
        const py = (frame.contentY + y) / Math.max(1, frame.contentHeight);
        root.zoom = next;
        // contentWidth/Height follow the zoom in the same frame.
        frame.contentX = Math.max(0, Math.min(frame.contentWidth - frame.width, px * frame.contentWidth - x));
        frame.contentY = Math.max(0, Math.min(frame.contentHeight - frame.height, py * frame.contentHeight - y));
    }

    /// Fitted, or the picture's own pixels (at least twice the fit, so a big
    /// photo that already nearly fits still visibly changes).
    function toggleZoom(x, y) {
        if (root.zoom > 1.01) {
            root.zoomAt(1, x, y);
            return;
        }
        root.zoomAt(Math.max(2, 1 / Math.max(0.01, frame.fitScale)), x, y);
    }

    // ── the bars come and go ─────────────────────────────────────────────────

    function wake() {
        root.chrome = true;
        idle.restart();
    }

    Timer {
        id: idle

        interval: 2600
        // Not while the pointer is on a bar, and not while nothing can be
        // seen yet: the bars are where "fetching" and the way back are.
        onTriggered: {
            if (barsHover.hovered || bottomHover.hovered || root.file.length === 0 && !root.hasPlayer)
                return;
            root.chrome = false;
        }
    }

    HoverHandler {
        id: anywhere

        onPointChanged: root.wake()
    }

    // ── the picture ──────────────────────────────────────────────────────────

    Rectangle {
        anchors.fill: parent
        color: "black"
    }

    // Right click anywhere is the menu; nothing under a viewer takes a click.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onWheel: wheel => wheel.accepted = true
        onClicked: mouse => {
            if (mouse.button !== Qt.RightButton)
                return;
            const at = mapToItem(null, mouse.x, mouse.y);
            root.contextRequested(root.message, at.x, at.y);
        }
    }

    Flickable {
        id: frame

        readonly property real mediaW: root.media && root.media.width > 0 ? root.media.width : 1280
        readonly property real mediaH: root.media && root.media.height > 0 ? root.media.height : 720
        /// The whole screen, picture's shape kept; a small picture is enlarged
        /// up to twice its size rather than shown as a stamp in the middle.
        readonly property real fitScale: Math.min(2, Math.min(frame.width / frame.mediaW, frame.height / frame.mediaH))
        readonly property real shownW: Math.round(frame.mediaW * frame.fitScale * root.zoom)
        readonly property real shownH: Math.round(frame.mediaH * frame.fitScale * root.zoom)

        anchors.fill: parent
        contentWidth: Math.max(width, frame.shownW)
        contentHeight: Math.max(height, frame.shownH)
        interactive: root.zoom > 1.01
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        Item {
            id: stage

            width: frame.contentWidth
            height: frame.contentHeight

            Shot {
                anchors.centerIn: parent
                width: frame.shownW
                height: frame.shownH
                visible: !root.moving
                fillMode: Image.PreserveAspectFit
                // The step from blur to thumbnail to file is most visible here.
                fade: 260
                placeholder: root.mini
                source: root.file.length > 0 ? root.file : root.thumb
            }

            Loader {
                anchors.centerIn: parent
                width: frame.shownW
                height: frame.shownH
                active: root.hasPlayer

                sourceComponent: Component {
                    VideoOutput {
                        id: output

                        anchors.fill: parent
                        fillMode: VideoOutput.PreserveAspectFit
                        Component.onCompleted: player.videoOutput = output
                    }
                }
            }

            // A clip whose file is still coming keeps its own poster up.
            Shot {
                anchors.centerIn: parent
                width: frame.shownW
                height: frame.shownH
                visible: root.moving && (!root.hasPlayer || root.stalled)
                fillMode: Image.PreserveAspectFit
                placeholder: root.mini
                source: root.thumb
            }
        }

        // A tap shows or hides the bars; two zoom. Escape or Back closes.
        TapHandler {
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onSingleTapped: root.chrome ? (root.chrome = false) : root.wake()
            onDoubleTapped: eventPoint => root.toggleZoom(eventPoint.position.x - frame.contentX, eventPoint.position.y - frame.contentY)
        }

        WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: event => {
                const steps = event.angleDelta.y / 120;
                if (steps === 0)
                    return;
                root.zoomAt(root.zoom * Math.pow(1.18, steps), event.x, event.y);
                root.wake();
            }
        }
    }

    // A paused clip says so in the middle, where the eye already is.
    Rectangle {
        anchors.centerIn: parent
        width: 64
        height: 64
        radius: 32
        visible: root.hasPlayer && !root.playing && !root.stalled
        color: "#99000000"

        MaterialSymbol {
            anchors.centerIn: parent
            text: "play_arrow"
            iconSize: 36
            color: "white"
        }

        TapHandler {
            onTapped: player.play()
        }
    }

    LoadingIndicator {
        anchors.centerIn: parent
        // `running`, not `visible`: the widget hides itself.
        running: (root.fetching && root.file.length === 0 && !root.hasPlayer) || root.stalled
    }

    PagePlaceholder {
        anchors.centerIn: parent
        width: parent.width * 0.6
        height: parent.height * 0.6
        // "failed", not "no file yet": a queued fetch is not a lost one.
        visible: root.message !== null && root.lens.fileStateOf(root.message) === "failed"
        icon: "cloud_off"
        title: "That file would not come down from Morse"
        description: "The thumbnail is what is on screen. Esc goes back."
        actionText: "Ask again"
        actionIcon: "refresh"
        onActionTriggered: root.lens.retryFile(root.message)
    }

    // ── previous / next, at the edges ────────────────────────────────────────

    Repeater {
        model: [-1, 1]

        delegate: Rectangle {
            required property int modelData

            anchors.verticalCenter: parent.verticalCenter
            x: modelData < 0 ? 16 : root.width - width - 16
            width: 48
            height: 48
            radius: 24
            color: edge.hovered ? "#cc000000" : "#77000000"
            opacity: root.chrome ? 1 : 0
            visible: opacity > 0 && (modelData < 0 ? root.lens.viewerIndex > 0 : root.lens.viewerIndex >= 0 && root.lens.viewerIndex < root.lens.viewerList.length - 1)

            Behavior on opacity {
                NumberAnimation {
                    duration: Appearance.animDur(180)
                }
            }

            MaterialSymbol {
                anchors.centerIn: parent
                text: parent.modelData < 0 ? "chevron_left" : "chevron_right"
                iconSize: 28
                color: "white"
            }

            HoverHandler {
                id: edge

                cursorShape: Qt.PointingHandCursor
            }

            TapHandler {
                onTapped: root.lens.viewerStep(parent.modelData)
            }
        }
    }

    // ── the top bar ──────────────────────────────────────────────────────────

    Item {
        id: topBar

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 72
        opacity: root.chrome ? 1 : 0
        visible: opacity > 0

        Behavior on opacity {
            NumberAnimation {
                duration: Appearance.animDur(180)
            }
        }

        HoverHandler {
            id: barsHover
        }

        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0; color: "#b0000000" }
                GradientStop { position: 1; color: "#00000000" }
            }
        }

        RowLayout {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            height: 56
            spacing: 6

            IconButton {
                icon: "arrow_back"
                tooltip: "Back · Esc"
                iconColor: "white"
                hoverColor: "#33ffffff"
                onClicked: root.lens.closeViewer()
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: -1

                StyledText {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    text: {
                        const of = root.lens.viewerList.length;
                        if (root.lens.viewerIndex >= 0 && of > 1)
                            return `${root.lens.viewerIndex + 1} of ${of}${root.lens.hasMore ? "+" : ""}`;
                        return root.message ? String(root.message.senderName || "") : "";
                    }
                    font.pixelSize: Appearance.font.pixelSize.normal
                    font.weight: Font.DemiBold
                    color: "white"
                }

                StyledText {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    text: {
                        if (!root.message)
                            return "";
                        const bits = [];
                        if (root.lens.viewerList.length > 1 && root.message.senderName)
                            bits.push(String(root.message.senderName));
                        bits.push(Fmt.when(root.message.date));
                        if (root.moving && root.hasPlayer)
                            bits.push(root.live ? "playing while it downloads" : root.file.length > 0 ? "original" : "480p, the original is coming");
                        else if (!root.moving && root.file.length === 0)
                            bits.push(root.fetching ? "fetching the file…" : "thumbnail");
                        if (root.zoom > 1.01)
                            bits.push(`${Math.round(root.zoom * frame.fitScale * 100)}%`);
                        return bits.join(" · ");
                    }
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: "#ccffffff"
                }
            }

            IconButton {
                visible: !root.lens.chatIsSecret
                icon: root.lens.isAdded(root.message) ? "check" : "add_photo_alternate"
                toggled: root.lens.isAdded(root.message)
                tooltip: root.lens.isAdded(root.message) ? "Already in your catalogue" : "Keep it in quarry · K"
                iconColor: "white"
                hoverColor: "#33ffffff"
                onClicked: root.lens.take(root.message, null)
            }

            IconButton {
                icon: root.full ? "fullscreen_exit" : "fullscreen"
                toggled: root.full
                tooltip: root.full ? "Leave full screen · F" : "Full screen · F"
                iconColor: "white"
                hoverColor: "#33ffffff"
                onClicked: root.setFull(!root.full)
            }

            IconButton {
                icon: "more_vert"
                tooltip: "Everything else"
                iconColor: "white"
                hoverColor: "#33ffffff"
                onClicked: {
                    const at = mapToItem(null, width / 2, height);
                    root.contextRequested(root.message, at.x, at.y);
                }
            }
        }
    }

    // ── the bottom: caption, the clip's controls, the strip ──────────────────

    Item {
        id: bottomBar

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: bottomColumn.implicitHeight + 48
        opacity: root.chrome ? 1 : 0
        visible: opacity > 0

        Behavior on opacity {
            NumberAnimation {
                duration: Appearance.animDur(180)
            }
        }

        HoverHandler {
            id: bottomHover
        }

        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0; color: "#00000000" }
                GradientStop { position: 1; color: "#c8000000" }
            }
        }

        ColumnLayout {
            id: bottomColumn

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            anchors.bottomMargin: 12
            spacing: 10

            // The words that came with it — the reason it was sent, often.
            StyledText {
                Layout.fillWidth: true
                Layout.maximumWidth: 760
                Layout.alignment: Qt.AlignHCenter
                visible: text.length > 0
                text: root.message ? String(root.message.text || "") : ""
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignHCenter
                font.family: Appearance.font.family.reading
                font.pixelSize: Appearance.font.pixelSize.small
                color: "white"
            }

            /*
             * THE BAR A CLIP HAS EVERYWHERE ELSE: where you are, how long it
             * is, pause, sound. The seek is issued when you let go rather than
             * on every pixel of the drag.
             */
            RowLayout {
                Layout.fillWidth: true
                visible: root.hasPlayer
                spacing: 10

                IconButton {
                    icon: root.playing ? "pause" : "play_arrow"
                    tooltip: root.playing ? "Pause · Space" : "Play · Space"
                    size: 34
                    iconColor: "white"
                hoverColor: "#33ffffff"
                    onClicked: root.playing ? player.pause() : player.play()
                }

                StyledText {
                    Layout.minimumWidth: 46
                    horizontalAlignment: Text.AlignRight
                    text: root.clock(scrubber.held ? scrubber.value : player.position)
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: "white"
                }

                StyledSlider {
                    id: scrubber

                    Layout.fillWidth: true
                    configuration: StyledSlider.Configuration.S
                    enabled: player.seekable
                    from: 0
                    to: Math.max(1, player.duration)
                    readout: root.clock(scrubber.value)
                    smoothValue: true
                    smoothPaused: !root.playing
                    smoothVelocity: 1000
                    onPressedChanged: {
                        if (pressed)
                            return;
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
                    Layout.minimumWidth: 46
                    text: player.duration > 0 ? root.clock(player.duration) : "--:--"
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: "#ccffffff"
                }

                IconButton {
                    icon: Prefs.videoSound ? "volume_up" : "volume_off"
                    tooltip: Prefs.videoSound ? "Mute · M" : "Unmute · M"
                    size: 34
                    iconColor: "white"
                hoverColor: "#33ffffff"
                    onClicked: Prefs.videoSound = !Prefs.videoSound
                }
            }

            /*
             * THE CHAT'S OTHER MEDIA, WITH WHERE YOU ARE IN THE MIDDLE.
             *
             * One slim row, as on the phone: the current one is the bright,
             * slightly larger frame, kept in the centre as you move.
             */
            ListView {
                id: strip

                Layout.fillWidth: true
                Layout.preferredHeight: 56
                visible: root.lens.viewerList.length > 1
                orientation: ListView.Horizontal
                spacing: 4
                clip: true
                model: root.lens.viewerList
                currentIndex: Math.max(0, root.lens.viewerIndex)
                highlightRangeMode: ListView.ApplyRange
                preferredHighlightBegin: width / 2 - 28
                preferredHighlightEnd: width / 2 + 28
                highlightMoveDuration: 220
                boundsBehavior: Flickable.StopAtBounds
                // A short strip sits in the middle, not against the left edge.
                leftMargin: Math.max(0, Math.round((width - contentWidth) / 2))

                delegate: Item {
                    id: cell

                    required property var modelData
                    required property int index
                    readonly property bool current: cell.index === root.lens.viewerIndex

                    width: cell.current ? 56 : 42
                    height: 56

                    Behavior on width {
                        NumberAnimation {
                            duration: Appearance.animDur(160)
                        }
                    }

                    Rectangle {
                        anchors.fill: parent
                        anchors.topMargin: cell.current ? 0 : 7
                        anchors.bottomMargin: cell.current ? 0 : 7
                        radius: 6
                        clip: true
                        color: "#22ffffff"
                        border.width: cell.current ? 2 : 0
                        border.color: "white"
                        opacity: cell.current ? 1 : 0.62

                        Shot {
                            anchors.fill: parent
                            anchors.margins: cell.current ? 2 : 0
                            fillMode: Image.PreserveAspectCrop
                            mipmap: true
                            fade: 120
                            placeholder: root.lens.miniOf(cell.modelData)
                            source: root.lens.realThumbOf(cell.modelData)
                        }

                        MaterialSymbol {
                            anchors.centerIn: parent
                            visible: Fmt.isMoving(cell.modelData.media)
                            text: "play_arrow"
                            iconSize: 16
                            color: "white"
                        }
                    }

                    TapHandler {
                        onTapped: root.lens.openViewerAt(cell.index)
                    }

                    HoverHandler {
                        cursorShape: Qt.PointingHandCursor
                    }
                }
            }
        }
    }
}
