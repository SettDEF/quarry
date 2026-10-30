import QtQuick
import QtMultimedia
import qs.modules.common
import qs.modules.widgets
import qs.services
import "../thread.js" as Fmt

/*
 * A REDDIT VIDEO, WHEREVER A POST SHOWS ITS PICTURE.
 *
 * The still is always there underneath (it is what you see while the stream
 * opens, and all you see when the video may not play). The player itself is
 * only CREATED while it is allowed to play — a card scrolled past costs an
 * Image, not a decoder.
 *
 * Who may play:
 *   mode "auto"  — the feed: asks PlayGate for a slot, ranked by distance from
 *                  the middle of `viewport`, so the few posts you are looking
 *                  at move and the rest hold still (the gallery's own rule)
 *   mode "hover" — the wall: plays while the pointer is on it
 *   mode "open"  — an opened post: plays, with sound
 *
 * Sound: reddit keeps it in a separate stream; `hls_url` carries both and
 * Qt's FFmpeg backend reads it (see thread.js videoUrl). Only ONE video has
 * sound at a time — the one whose token is the lens's `soundToken`; the
 * speaker button hands it over. Feed videos start muted, as on the site.
 */
Item {
    id: root

    required property var post
    property var lens: null
    property string mode: "auto"          // auto | hover | open
    property Item viewport: null          // for "auto": the list it scrolls in
    property bool controls: true
    property int fillMode: VideoOutput.PreserveAspectFit

    readonly property string source: Fmt.videoUrl(root.post)
    readonly property bool isVideo: root.source.length > 0
    /// a "gif": a silent loop, no sound button
    readonly property bool isGif: !!root.post && (root.post.preview?.reddit_video_preview?.is_gif === true
                                   || (!root.post.secure_media?.reddit_video && !root.post.media?.reddit_video && root.isVideo))
    readonly property string token: root.post ? `reddit:${root.post.id ?? root.post.name ?? root.source}` : ""
    readonly property bool hasSound: !!root.lens && root.lens.soundToken === root.token && !root.isGif

    // ── may it play? ──
    property real priority: 1e9
    // The one autoplay switch (the Autoplay extension / Settings) covers lenses too.
    readonly property bool wantsAuto: root.mode === "auto" && root.isVideo && root.visible && Prefs.autoplayInView
    readonly property bool allowed: root.isVideo && (
        root.mode === "open" ? true
        : root.mode === "hover" ? hover.hovered
        : (root.wantsAuto && PlayGate.holds(root.token)))
    property bool userPaused: false
    readonly property bool playing: root.allowed && !root.userPaused

    function rank() {
        if (!root.viewport || !root.wantsAuto) return;
        const p = root.mapToItem(root.viewport, 0, root.height / 2);
        const d = Math.abs(p.y - root.viewport.height / 2);
        // off screen: no claim at all
        if (p.y + root.height / 2 < 0 || p.y - root.height / 2 > root.viewport.height) { PlayGate.release(root.token); return; }
        // "All in view" (slots 0): only once enough of it shows, as on the wall.
        if (Prefs.autoplaySlots === 0 && root.height > 0) {
            const shown = Math.min(p.y + root.height / 2, root.viewport.height) - Math.max(p.y - root.height / 2, 0);
            if (shown / root.height * 100 < Prefs.autoplayThreshold) { PlayGate.release(root.token); return; }
        }
        root.priority = d;
        PlayGate.claim(root.token, d);
        // Autoscroll waits on it here as on the wall: playing, and its centre at the middle.
        if (Scripts.scrollSpeed !== 0 && PlayGate.holds(root.token) && d < Prefs.snapTolerance)
            Scripts.snapTo(root.token, p.y - root.viewport.height / 2, Number(root.post?.secure_media?.reddit_video?.duration ?? 0));
    }
    onWantsAutoChanged: if (root.wantsAuto) root.rank(); else PlayGate.release(root.token)
    Connections {
        target: root.viewport
        enabled: root.wantsAuto
        ignoreUnknownSignals: true
        function onContentYChanged() { rankLater.restart(); }
        function onHeightChanged() { rankLater.restart(); }
    }
    Timer { id: rankLater; interval: 60; onTriggered: root.rank() }
    // an opened post plays with sound, as on the site
    Component.onCompleted: {
        if (root.wantsAuto) Qt.callLater(root.rank);
        if (root.mode === "open" && root.lens && root.isVideo && !root.isGif) root.lens.soundToken = root.token;
    }
    onTokenChanged: if (root.mode === "open" && root.lens && root.isVideo && !root.isGif) root.lens.soundToken = root.token
    Component.onDestruction: PlayGate.release(root.token)

    // ── the still ──
    Image {
        id: still
        anchors.fill: parent
        fillMode: root.fillMode === VideoOutput.PreserveAspectCrop ? Image.PreserveAspectCrop : Image.PreserveAspectFit
        asynchronous: true
        sourceSize.width: Math.round(Math.max(1, root.width) * 1.5)
        source: root.post ? Fmt.imageUrl(root.post) : ""
        opacity: player.item && player.item.started ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 160 } }
    }

    // ── the player, only while it may play ──
    Loader {
        id: player
        anchors.fill: parent
        active: root.playing || (root.allowed && root.userPaused)
        sourceComponent: Item {
            property bool started: mp.position > 0
            property alias mp: mp
            MediaPlayer {
                id: mp
                source: root.source
                loops: MediaPlayer.Infinite
                videoOutput: vo
                audioOutput: AudioOutput { muted: !root.hasSound }
                Component.onCompleted: if (root.playing) play()
            }
            VideoOutput { id: vo; anchors.fill: parent; fillMode: root.fillMode }
            Connections {
                target: root
                function onPlayingChanged() { if (root.playing) mp.play(); else mp.pause(); }
            }
        }
    }

    // ── what it is, before it plays ──
    Rectangle {
        visible: root.isVideo && !(player.item && player.item.started) && root.width > 120
        anchors { left: parent.left; bottom: parent.bottom; margins: 10 }
        implicitWidth: badge.implicitWidth + 16; implicitHeight: 24; radius: 12
        color: "#aa000000"
        Row {
            id: badge
            anchors.centerIn: parent
            spacing: 4
            MaterialSymbol { anchors.verticalCenter: parent.verticalCenter; text: root.isGif ? "gif_box" : "play_arrow"; iconSize: 15; color: "white"; fill: 1 }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: !root.isGif && (root.post?.secure_media?.reddit_video?.duration ?? 0) > 0
                text: { const s = root.post?.secure_media?.reddit_video?.duration ?? 0; return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`; }
                font.pixelSize: Appearance.font.pixelSize.smallest; color: "white"
            }
        }
    }

    // ── controls: on hover, or always in an opened post ──
    Item {
        id: bar
        visible: root.controls && root.isVideo && player.item !== null
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 44
        opacity: hover.hovered || root.userPaused ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 140 } }
        Rectangle {
            anchors.fill: parent
            gradient: Gradient { GradientStop { position: 0; color: "transparent" } GradientStop { position: 1; color: "#bb000000" } }
        }
        Row {
            anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
            spacing: 2
            IconButton {
                size: 32
                icon: root.userPaused ? "play_arrow" : "pause"
                tooltip: root.userPaused ? "Play" : "Pause"
                onClicked: root.userPaused = !root.userPaused
            }
            IconButton {
                visible: !root.isGif && !!root.lens
                size: 32
                icon: root.hasSound ? "volume_up" : "volume_off"
                tooltip: root.hasSound ? "Mute" : "Sound on (mutes any other)"
                onClicked: root.lens.soundToken = root.hasSound ? "" : root.token
            }
        }
        // where it is, and a click to go there
        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 84; rightMargin: 12; bottomMargin: 20 }
            height: 4; radius: 2
            color: "#55ffffff"
            readonly property var mp: player.item ? player.item.mp : null
            Rectangle {
                height: parent.height; radius: 2
                width: parent.mp && parent.mp.duration > 0 ? parent.width * parent.mp.position / parent.mp.duration : 0
                color: "white"
            }
            MouseArea {
                anchors { fill: parent; topMargin: -8; bottomMargin: -8 }
                cursorShape: Qt.PointingHandCursor
                onClicked: (m) => { const mp = parent.mp; if (mp && mp.duration > 0) mp.position = mp.duration * Math.max(0, Math.min(1, m.x / width)); }
            }
        }
    }

    HoverHandler { id: hover }
}
