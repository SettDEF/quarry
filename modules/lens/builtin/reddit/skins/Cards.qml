import qs.modules.common
import Quickshell
import qs.modules.widgets
import QtQuick
import QtQuick.Layouts
import "../thread.js" as Thread

/*
 * A SUBREDDIT AS CARDS — the way Rodded reads one.
 *
 * The compact list ("Posts") is for skimming titles; this is for reading the
 * feed: every post at full width with its media IN the card — a picture at its
 * own shape, a gallery you can step through, a video that plays as it reaches
 * the middle of the view (muted, the speaker hands the sound over). Clicking
 * anywhere but the media opens the post and its comments.
 */
StyledListView {
    id: root

    required property var lens
    property color card: Appearance.colors.colLayer1
    property color ink: Appearance.colors.colOnLayer1
    property color dim: Appearance.colors.colSubtext
    property color accent: Appearance.colors.colPrimary

    clip: true
    spacing: 12
    // keyed by post: a new page adds rows, it does not rebuild the list
    model: ScriptModel { values: root.lens.posts; objectProp: "id" }
    readonly property real column: Math.min(root.width, 760)

    onContentYChanged: {
        if (contentY + height > contentHeight - height * 1.5)
            root.lens.more();
    }

    delegate: Item {
        id: cardItem
        required property var modelData
        required property int index
        width: root.width
        height: body.implicitHeight + 28

        readonly property var p: cardItem.modelData
        readonly property var gallery: Thread.galleryUrls(cardItem.p)
        readonly property string video: Thread.videoUrl(cardItem.p)
        readonly property string picture: cardItem.gallery.length > 0 ? "" : Thread.imageUrl(cardItem.p)
        readonly property bool hasMedia: cardItem.video.length > 0 || cardItem.gallery.length > 0 || cardItem.picture.length > 0
        readonly property real ratio: Math.max(0.35, Math.min(1.6, Thread.ratioOf(cardItem.p)))
        readonly property bool nsfwHidden: cardItem.p.over_18 === true && Prefs.blurNsfw && !mediaHover.hovered
        property int frame: 0

        // autoscroll: a video reaching the middle holds the feed while it plays (once)
        property bool dwelled: false
        Connections {
            target: root
            enabled: root.lens.autoscroll && cardItem.video.length > 0 && !cardItem.dwelled
            function onContentYChanged() {
                const mid = cardItem.mapToItem(root, 0, cardItem.height / 2).y;
                if (Math.abs(mid - root.height / 2) < 40) {
                    cardItem.dwelled = true;
                    const d = cardItem.p?.secure_media?.reddit_video?.duration ?? 8;
                    root.lens.dwellUntil = Date.now() + Math.min(20, Math.max(4, d)) * 1000;
                }
            }
        }

        Rectangle {
            id: bg
            anchors.horizontalCenter: parent.horizontalCenter
            width: root.column
            height: parent.height - 12
            radius: 18
            color: cardHover.hovered ? Appearance.colors.colLayer1Hover : root.card
            Behavior on color { ColorAnimation { duration: 120 } }

            HoverHandler { id: cardHover }
            TapHandler {
                gesturePolicy: TapHandler.ReleaseWithinBounds
                onTapped: root.lens.openPost(cardItem.p)
            }

            ColumnLayout {
                id: body
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 16 }
                spacing: 10

                // who and where
                StyledText {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    text: {
                        const sub = cardItem.p.subreddit ? `<a href="sub:${cardItem.p.subreddit}"><b>r/${cardItem.p.subreddit}</b></a>` : "";
                        const who = cardItem.p.author && cardItem.p.author !== "[deleted]" ? `<a href="user:${cardItem.p.author}">u/${cardItem.p.author}</a>` : "";
                        return [sub, who, Thread.ago(cardItem.p.created_utc)].filter(b => b.length > 0).join("  ·  ");
                    }
                    textFormat: Text.StyledText
                    linkColor: root.ink
                    onLinkActivated: (link) => link.indexOf("user:") === 0 ? root.lens.openUser(link.slice(5)) : root.lens.openSub(link.slice(4))
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: root.dim
                    HoverHandler { cursorShape: parent.hoveredLink.length > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor }
                }

                // the title, with its flair and marks
                Flow {
                    Layout.fillWidth: true
                    spacing: 6
                    StyledText {
                        width: Math.min(implicitWidth, parent.width)
                        wrapMode: Text.WordWrap
                        text: cardItem.p.title || ""
                        font.pixelSize: Appearance.font.pixelSize.normal + 1
                        font.weight: Font.DemiBold
                        color: root.ink
                    }
                    Repeater {
                        model: [
                            cardItem.p.link_flair_text ? { t: cardItem.p.link_flair_text, c: root.accent } : null,
                            cardItem.p.over_18 ? { t: "NSFW", c: Appearance.m3colors.m3error } : null,
                            cardItem.p.spoiler ? { t: "Spoiler", c: root.dim } : null,
                            cardItem.p.stickied ? { t: "Pinned", c: Appearance.colors.colUpvote } : null
                        ].filter(x => x)
                        delegate: Rectangle {
                            required property var modelData
                            implicitWidth: fl.implicitWidth + 14; implicitHeight: 22; radius: 11
                            color: Qt.alpha(modelData.c, 0.16)
                            StyledText { id: fl; anchors.centerIn: parent; text: parent.modelData.t; font.pixelSize: Appearance.font.pixelSize.smallest; font.weight: Font.DemiBold; color: parent.modelData.c }
                        }
                    }
                }

                // a text post: the start of what it says
                StyledText {
                    visible: !cardItem.hasMedia && (cardItem.p.selftext ?? "").length > 0
                    Layout.fillWidth: true
                    text: cardItem.p.selftext ?? ""
                    textFormat: Text.MarkdownText
                    wrapMode: Text.Wrap
                    maximumLineCount: 6
                    elide: Text.ElideRight
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: root.ink
                    opacity: 0.85
                }

                // ── the media, in the card ──
                Rectangle {
                    id: media
                    visible: cardItem.hasMedia
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(width * cardItem.ratio, root.height * 0.72)
                    radius: 12
                    clip: true
                    color: ColorUtils.mix(root.card, "black", 0.55)

                    // a video (or a gif): plays near the middle of the view
                    RedditVideo {
                        anchors.fill: parent
                        visible: cardItem.video.length > 0
                        post: cardItem.p
                        lens: root.lens
                        mode: "auto"
                        viewport: root
                    }
                    // one picture
                    Image {
                        anchors.fill: parent
                        visible: cardItem.video.length === 0 && cardItem.picture.length > 0
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        sourceSize.width: Math.round(parent.width * 1.5)
                        source: visible ? cardItem.picture : ""
                    }
                    // a gallery: one frame at a time, arrows and a count
                    Image {
                        id: galleryImage
                        anchors.fill: parent
                        visible: cardItem.video.length === 0 && cardItem.gallery.length > 0
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        sourceSize.width: Math.round(parent.width * 1.5)
                        source: visible ? cardItem.gallery[Math.min(cardItem.frame, cardItem.gallery.length - 1)] : ""
                    }
                    Repeater {
                        model: cardItem.gallery.length > 1 && cardItem.video.length === 0 ? [-1, 1] : []
                        delegate: Rectangle {
                            required property int modelData
                            readonly property bool can: modelData < 0 ? cardItem.frame > 0 : cardItem.frame < cardItem.gallery.length - 1
                            visible: can && mediaHover.hovered
                            anchors.verticalCenter: parent.verticalCenter
                            x: modelData < 0 ? 10 : parent.width - width - 10
                            width: 36; height: 36; radius: 18
                            color: "#aa000000"
                            MaterialSymbol { anchors.centerIn: parent; text: parent.modelData < 0 ? "chevron_left" : "chevron_right"; iconSize: 22; color: "white" }
                            TapHandler { onTapped: cardItem.frame += parent.modelData }
                        }
                    }
                    Rectangle {
                        visible: cardItem.gallery.length > 1 && cardItem.video.length === 0
                        anchors { right: parent.right; top: parent.top; margins: 10 }
                        implicitWidth: frameCount.implicitWidth + 14; implicitHeight: 22; radius: 11
                        color: "#aa000000"
                        StyledText { id: frameCount; anchors.centerIn: parent; text: `${cardItem.frame + 1} / ${cardItem.gallery.length}`; font.pixelSize: Appearance.font.pixelSize.smallest; color: "white" }
                    }
                    // nobody agreed to see it yet
                    Rectangle {
                        anchors.fill: parent
                        visible: cardItem.nsfwHidden
                        color: "#ee101010"
                        StyledText { anchors.centerIn: parent; text: "NSFW — hover to see it"; font.pixelSize: Appearance.font.pixelSize.smaller; color: "white" }
                    }
                    HoverHandler { id: mediaHover }
                    // the media is not "open the post": it has its own controls
                    TapHandler { gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: {} }
                }

                // a link post: where it goes
                StyledText {
                    visible: !cardItem.hasMedia && !cardItem.p.is_self && (cardItem.p.domain ?? "").length > 0
                    text: "↗ " + (cardItem.p.domain ?? "")
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: root.accent
                }

                // the numbers, and what you can do
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    component Pill: Rectangle {
                        id: pill
                        property string icon
                        property string label
                        property color tint: root.ink
                        implicitWidth: pr.implicitWidth + 20; implicitHeight: 30; radius: 15
                        color: Qt.alpha(root.ink, 0.06)
                        Row {
                            id: pr
                            anchors.centerIn: parent; spacing: 5
                            MaterialSymbol { anchors.verticalCenter: parent.verticalCenter; text: pill.icon; iconSize: 16; color: pill.tint }
                            StyledText { anchors.verticalCenter: parent.verticalCenter; text: pill.label; font.pixelSize: Appearance.font.pixelSize.smaller; font.weight: Font.DemiBold; color: root.ink }
                        }
                    }
                    Pill { icon: "arrow_upward"; label: Thread.count(cardItem.p.score); tint: Appearance.colors.colUpvote }
                    Pill { icon: "chat_bubble"; label: Thread.count(cardItem.p.num_comments) }
                    Item { Layout.fillWidth: true }
                    IconButton {
                        visible: cardItem.picture.length > 0 || cardItem.gallery.length > 0
                        icon: "library_add"
                        tooltip: "Take this picture into quarry"
                        size: 32
                        onClicked: root.lens.takePicture(cardItem.p)
                    }
                }
            }
        }
    }

    footer: Item {
        width: root.width
        height: root.lens.loading ? 60 : 0
        LoadingIndicator { anchors.centerIn: parent; running: root.lens.loading }
    }
}
