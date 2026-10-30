import QtQuick
import QtQuick.Layouts
import QtMultimedia
import qs.modules.common
import qs.modules.widgets
import "../thread.js" as Fmt

/*
 * THEATER — one picture or video at a time, as big as the pane allows.
 *
 * For the subreddits that are a pile of pictures, read one by one: arrow keys,
 * the wheel or a click on either side step; a gallery is stepped through
 * frame by frame before the next post. Videos play with sound. Auto-advance
 * moves on by itself (a video when it ends, a picture after a few seconds).
 * Everything that is not the picture fades out while you are not moving the
 * pointer; F hides it for good, Esc brings it back.
 *
 * The next and previous pictures are already decoded when you get there, and
 * the next page is asked for before the last post.
 */
FocusScope {
    id: root
    required property var lens

    readonly property var items: root.lens.pictures
    property int index: 0
    property int frame: 0
    property bool auto: false
    property int autoSeconds: 6
    property bool bare: false               // F: no chrome at all
    property bool idle: false

    readonly property var p: root.items.length > 0 ? root.items[Math.min(root.index, root.items.length - 1)] : null
    readonly property var gallery: Fmt.galleryUrls(root.p)
    readonly property string video: Fmt.videoUrl(root.p)
    readonly property string picture: root.gallery.length > 0 ? root.gallery[Math.min(root.frame, root.gallery.length - 1)] : Fmt.imageUrl(root.p)
    readonly property bool chrome: !root.bare && !root.idle

    function step(d) {
        // a gallery first, frame by frame
        if (root.gallery.length > 1) {
            const f = root.frame + d;
            if (f >= 0 && f < root.gallery.length) { root.frame = f; return; }
        }
        const i = root.index + d;
        if (i < 0 || i >= root.items.length) return;
        root.index = i;
        root.frame = d < 0 ? 0 : 0;
        if (root.items.length - root.index < 4) root.lens.more();
    }
    function nudge() { root.idle = false; idleTimer.restart(); }

    onIndexChanged: { root.nudge(); autoTimer.restart(); }
    onItemsChanged: if (root.index >= root.items.length) root.index = Math.max(0, root.items.length - 1)
    onVisibleChanged: if (visible) { root.forceActiveFocus(); root.nudge(); }

    Keys.onPressed: (e) => {
        if (e.key === Qt.Key_Right || e.key === Qt.Key_Down || e.key === Qt.Key_J || e.key === Qt.Key_PageDown) { root.step(1); e.accepted = true; }
        else if (e.key === Qt.Key_Left || e.key === Qt.Key_Up || e.key === Qt.Key_K || e.key === Qt.Key_PageUp) { root.step(-1); e.accepted = true; }
        else if (e.key === Qt.Key_Home) { root.index = 0; root.frame = 0; e.accepted = true; }
        else if (e.key === Qt.Key_A) { root.auto = !root.auto; e.accepted = true; }
        else if (e.key === Qt.Key_F) { root.bare = !root.bare; e.accepted = true; }
        else if (e.key === Qt.Key_Escape && root.bare) { root.bare = false; e.accepted = true; }
        else if (e.key === Qt.Key_Return || e.key === Qt.Key_C) { if (root.p) root.lens.openPost(root.p); e.accepted = true; }
        root.nudge();
    }

    Timer { id: idleTimer; interval: 2200; onTriggered: root.idle = true }
    // auto-advance: pictures on a timer; a video moves on when it ends (below)
    Timer {
        id: autoTimer
        interval: root.autoSeconds * 1000
        running: root.auto && root.visible && root.video.length === 0
        onTriggered: root.step(1)
    }

    Rectangle { anchors.fill: parent; color: "black"; radius: 12 }

    // neighbours, decoded ahead so a step is instant
    Repeater {
        model: [-1, 1, 2]
        delegate: Image {
            required property int modelData
            readonly property var q: root.items[root.index + modelData] ?? null
            visible: false
            asynchronous: true
            sourceSize.width: Math.round(root.width * 1.5)
            source: q && Fmt.videoUrl(q).length === 0 ? (Fmt.galleryUrls(q)[0] ?? Fmt.imageUrl(q)) : ""
        }
    }

    // ── the picture ──
    Image {
        id: pic
        anchors.fill: parent
        visible: root.video.length === 0
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        sourceSize.width: Math.round(root.width * 1.5)
        source: visible ? root.picture : ""
        opacity: status === Image.Ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 140 } }
    }
    // ── or the video ──
    Loader {
        anchors.fill: parent
        active: root.video.length > 0 && root.visible
        sourceComponent: RedditVideo {
            post: root.p
            lens: root.lens
            mode: "open"
            controls: root.chrome
        }
    }
    // a video moves on when it has played once (auto only)
    Timer {
        interval: 500; repeat: true
        running: root.auto && root.visible && root.video.length > 0
        property real last: 0
        onTriggered: {
            const d = root.p?.secure_media?.reddit_video?.duration ?? 0;
            last += 0.5;
            if (d > 0 && last >= d + 0.5) { last = 0; root.step(1); }
        }
        onRunningChanged: last = 0
    }

    Text {
        anchors.centerIn: parent
        visible: root.items.length === 0
        text: root.lens.loading ? "Asking reddit…" : "Nothing here with a picture in it."
        color: "#aaffffff"
        font.pixelSize: Appearance.font.pixelSize.normal
    }

    // the two halves step (the video keeps its own controls at the bottom)
    MouseArea {
        anchors { fill: parent; bottomMargin: 56 }
        hoverEnabled: true
        cursorShape: root.chrome ? Qt.PointingHandCursor : Qt.BlankCursor
        onPositionChanged: root.nudge()
        onClicked: (m) => { root.forceActiveFocus(); root.step(m.x < width / 3 ? -1 : 1); }
        onWheel: (w) => { if (Math.abs(w.angleDelta.y) >= 60 || Math.abs(w.pixelDelta.y) > 30) root.step(w.angleDelta.y < 0 || w.pixelDelta.y < 0 ? 1 : -1); }
    }

    // ── chrome: title, place, controls ──
    Item {
        anchors.fill: parent
        opacity: root.chrome ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 260 } }

        Rectangle {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: 92; radius: 12
            gradient: Gradient { GradientStop { position: 0; color: "#cc000000" } GradientStop { position: 1; color: "transparent" } }
        }
        ColumnLayout {
            anchors { left: parent.left; right: tools.left; top: parent.top; margins: 16 }
            spacing: 2
            Text {
                Layout.fillWidth: true
                text: root.p ? (root.p.title ?? "") : ""
                elide: Text.ElideRight
                color: "white"
                font.pixelSize: Appearance.font.pixelSize.normal
                font.weight: Font.DemiBold
            }
            Text {
                Layout.fillWidth: true
                text: root.p ? [`r/${root.p.subreddit}`, `u/${root.p.author}`, Fmt.ago(root.p.created_utc), `↑ ${Fmt.count(root.p.score)}`, `${Fmt.count(root.p.num_comments)} comments`].join("  ·  ") : ""
                elide: Text.ElideRight
                color: "#ccffffff"
                font.pixelSize: Appearance.font.pixelSize.smaller
            }
        }
        Row {
            id: tools
            anchors { right: parent.right; top: parent.top; margins: 10 }
            spacing: 4
            component Tool: Rectangle {
                id: tl
                property string icon
                property string tip
                property bool on: false
                signal clicked()
                width: 36; height: 36; radius: 18
                color: tl.on ? Appearance.colors.colPrimary : th.hovered ? "#44ffffff" : "#22ffffff"
                MaterialSymbol { anchors.centerIn: parent; text: tl.icon; iconSize: 19; color: tl.on ? Appearance.colors.colOnPrimary : "white" }
                HoverHandler { id: th; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: { tl.clicked(); root.nudge(); } }
                StyledToolTip { text: tl.tip; shown: th.hovered }
            }
            Tool { icon: root.auto ? "pause" : "play_arrow"; on: root.auto; tip: root.auto ? "Stop auto-advance (A)" : "Auto-advance (A)"; onClicked: root.auto = !root.auto }
            Tool { icon: "chat_bubble"; tip: "Open with comments (Enter)"; onClicked: if (root.p) root.lens.openPost(root.p) }
            Tool { icon: "library_add"; tip: "Take this picture into quarry"; visible: root.video.length === 0; onClicked: if (root.p) root.lens.takePicture(root.p) }
            Tool { icon: "fullscreen"; tip: "Hide everything but the picture (F, Esc back)"; onClicked: root.bare = true }
        }

        // where you are
        Rectangle {
            anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: root.video.length > 0 ? 52 : 14 }
            implicitWidth: place.implicitWidth + 20; implicitHeight: 26; radius: 13
            color: "#99000000"
            Text {
                id: place
                anchors.centerIn: parent
                text: `${root.index + 1} / ${root.items.length}${root.lens.hasMore ? "+" : ""}` + (root.gallery.length > 1 ? `   ·   picture ${root.frame + 1} of ${root.gallery.length}` : "")
                color: "white"
                font.family: Appearance.font.family.monospace
                font.pixelSize: Appearance.font.pixelSize.smallest
            }
        }
        // side arrows
        Repeater {
            model: [-1, 1]
            delegate: Rectangle {
                required property int modelData
                anchors.verticalCenter: parent.verticalCenter
                x: modelData < 0 ? 14 : parent.width - width - 14
                width: 44; height: 44; radius: 22
                color: ah.hovered ? "#66000000" : "#33000000"
                MaterialSymbol { anchors.centerIn: parent; text: parent.modelData < 0 ? "chevron_left" : "chevron_right"; iconSize: 26; color: "white" }
                HoverHandler { id: ah; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: { root.step(parent.modelData); root.forceActiveFocus(); } }
            }
        }
    }

    // nobody agreed to see it yet
    Rectangle {
        anchors.fill: parent
        radius: 12
        visible: !!root.p && root.p.over_18 === true && Prefs.blurNsfw && !nsfwPeek.hovered
        color: "#f0101010"
        Text { anchors.centerIn: parent; text: "NSFW — hover to see it"; color: "white"; font.pixelSize: Appearance.font.pixelSize.small }
        HoverHandler { id: nsfwPeek }
    }
}
