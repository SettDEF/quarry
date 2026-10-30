import qs.modules.common
import qs.modules.widgets
import qs.modules.gallery
import QtQuick
import QtQuick.Layouts
import "../thread.js" as Fmt

/*
 * A POST AND WHAT WAS SAID UNDER IT.
 *
 * The comment tree is one flat ListView — see thread.js. Depth is an indent
 * plus a guide line per ancestor, which is what makes a deep chain readable and
 * collapsing cheap: a folded subtree stops producing rows rather than sitting
 * off-screen with its text still laid out.
 *
 * Written once for both skins; the palette is the only difference between them.
 */
Item {
    id: root

    required property var lens
    property color card: Appearance.colors.colLayer1
    property color ink: Appearance.colors.colOnLayer1
    property color dim: Appearance.colors.colSubtext
    property color accent: Appearance.colors.colPrimary
    property color guide: Appearance.colors.colOutlineVariant
    property real cardRadius: 17

    readonly property var post: root.lens.post
    /// Reddit measures every preview, so the frame can be the picture's own
    /// shape. It was a fixed 0.62 slab across the full window instead, which is
    /// where the letterboxing came from: at 1400px the box was 1400×420 and a
    /// photograph fitted to its height with a dark bar either side of it.
    readonly property real postRatio: Fmt.ratioOf(root.post)
    /// The moving picture, when there is one — see `videoUrl`.
    readonly property string postVideo: Fmt.videoUrl(root.post)
    readonly property string postImage: Fmt.imageUrl(root.post)
    /*
     * AS MUCH ROOM AS THE SCREEN CAN GIVE IT.
     *
     * It was capped at a flat 520px, which on a tall window left a small
     * picture floating in a page of nothing. The media is the post; the limit
     * is the VIEW, so a portrait photograph or a phone video fills the height
     * available and a wide one still stops at the column's width.
     */
    readonly property real mediaHeight: {
        const byWidth = Math.round(list.width * root.postRatio);
        const byHeight = Math.round(list.height * 0.82);
        return Math.max(220, Math.min(byWidth, byHeight));
    }

    /*
     * The app's own list: `StyledListView` carries the scrollbar, the momentum
     * settings and item reuse. A plain ListView had NO scrollbar at all, so a
     * nine-hundred-comment thread gave no sense of where in it you were.
     */
    StyledListView {
        id: list

        // Full width, deliberately: a measured column was tried here and the
        // window is the reading width this screen wants.
        anchors.fill: parent
        clip: true
        spacing: 2
        model: root.lens.commentRows

        // ── the post itself ──────────────────────────────────────────────────
        header: Column {
            width: list.width
            spacing: 8
            bottomPadding: 10

            Rectangle {
                width: parent.width
                height: postBody.implicitHeight + 24
                radius: root.cardRadius
                color: root.card

                ColumnLayout {
                    id: postBody
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 12
                    spacing: 6

                    StyledText {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: root.post ? (root.post.title || "") : ""
                        font.pixelSize: Appearance.font.pixelSize.larger
                        font.weight: Font.DemiBold
                        color: root.ink
                    }

                    StyledText {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        /*
                         * THE LINE THAT SAYS WHO AND WHERE IS ALSO HOW YOU GET
                         * THERE.
                         *
                         * It was one dead string. The community and the person
                         * are the two things anybody wants to follow out of a
                         * post, so they are links here — `openSub` and
                         * `openUser` — and the numbers stay plain, because a
                         * score is not somewhere you can go.
                         *
                         * (The old filter dropped anything under three
                         * characters to lose an empty "r/". It also ate every
                         * age: "5m", "4h", "3d".)
                         */
                        text: {
                            if (!root.post)
                                return "";
                            const sub = root.post.subreddit ? `<a href="sub:${root.post.subreddit}">r/${root.post.subreddit}</a>` : "";
                            const who = root.post.author && root.post.author !== "[deleted]" ? `<a href="user:${root.post.author}">u/${root.post.author}</a>` : "";
                            const bits = [sub, who, Fmt.ago(root.post.created_utc), `${Fmt.count(root.post.score)} points`, `${Fmt.count(root.post.num_comments)} comments`];
                            return bits.filter(bit => bit.length > 0).join("  ·  ");
                        }
                        textFormat: Text.StyledText
                        linkColor: root.accent
                        onLinkActivated: (link) => {
                            return link.indexOf("user:") === 0 ? root.lens.openUser(link.slice(5)) : root.lens.openSub(link.slice(4));
                        }
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: root.dim

                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.NoButton
                            cursorShape: parent.hoveredLink.length > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                        }

                    }

                    // The picture or the clip, whichever the post is. Tapping
                    // it takes it into the catalogue — the lens's whole reason
                    // to exist beside a picture engine.
                    Rectangle {
                        readonly property real frameHeight: root.mediaHeight

                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredWidth: Math.min(postBody.width, Math.round(frameHeight / root.postRatio))
                        Layout.preferredHeight: frameHeight
                        visible: root.post && (root.postImage.length > 0 || root.postVideo.length > 0)
                        radius: 10
                        clip: true
                        // Only ever seen while the picture is in flight, so it
                        // follows the card rather than being a hardcoded grey.
                        color: ColorUtils.mix(root.card, "black", 0.55)

                        // a video plays here, with sound (it is what you opened)
                        RedditVideo {
                            anchors.fill: parent
                            visible: root.postVideo.length > 0
                            post: root.post
                            lens: root.lens
                            mode: "open"
                        }

                        Image {
                            visible: root.postVideo.length === 0
                            anchors.fill: parent
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            // Nothing asked for a size, so a 4000px source was
                            // decoded in full to fill a 700px frame.
                            sourceSize.width: Math.round(parent.width * 1.5)
                            source: root.post ? Fmt.imageUrl(root.post) : ""
                        }

                        Rectangle {
                            anchors.fill: parent
                            visible: root.post && root.post.over_18 === true && Prefs.blurNsfw && !pictureHover.hovered
                            color: "#dd000000"
                            StyledText {
                                anchors.centerIn: parent
                                text: "NSFW — hover to see it"
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: "white"
                            }
                        }

                        HoverHandler {
                            id: pictureHover
                        }
                    }

                    StyledText {
                        Layout.fillWidth: true
                        visible: text.length > 0
                        wrapMode: Text.WordWrap
                        /*
                         * A REDDIT POST IS MARKDOWN.
                         *
                         * Drawn as plain text, every link in a self post read
                         * as `[the words](https://…)` and every quote as a
                         * literal `>`. The API is asked with `raw_json=1`, so
                         * what arrives is the markdown itself rather than HTML
                         * entities, which is exactly what this wants.
                         */
                        textFormat: Text.MarkdownText
                        linkColor: root.accent
                        onLinkActivated: (link) => {
                            return root.lens.openExternally(link);
                        }
                        text: root.post ? String(root.post.selftext || "") : ""
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: root.ink

                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.NoButton
                            cursorShape: parent.hoveredLink.length > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                        }

                    }

                    /*
                     * WHAT YOU CAN DO WITH THIS POST, WHERE THE POST IS.
                     *
                     * All four already existed — two in the overflow menu
                     * behind ⋮, two only as functions nothing called — which
                     * meant that the obvious things to want here (the person
                     * who posted it, the site it came from, the picture into
                     * the catalogue) each took a hunt through a menu that also
                     * listed every other lens's verbs.
                     */
                    Row {
                        Layout.fillWidth: true
                        Layout.topMargin: 4
                        spacing: 6

                        Repeater {
                            model: [{
                                "id": "user",
                                "label": root.post && root.post.author ? `u/${root.post.author}` : "",
                                "icon": "person"
                            }, {
                                "id": "sub",
                                "label": root.post && root.post.subreddit ? `r/${root.post.subreddit}` : "",
                                "icon": "tag"
                            }, {
                                "id": "site",
                                "label": "Open on reddit",
                                "icon": "public"
                            }, {
                                "id": "copy",
                                "label": "Copy link",
                                "icon": "link"
                            }, {
                                "id": "keep",
                                "label": "Take the picture",
                                "icon": "library_add"
                            }]

                            delegate: RippleButton {
                                required property var modelData

                                visible: String(modelData.label).length > 0 && (modelData.id !== "keep" || (root.post && Fmt.imageUrl(root.post).length > 0))
                                implicitHeight: 30
                                implicitWidth: actionLabel.implicitWidth + actionIcon.width + 24
                                buttonRadius: Appearance.rounding.full
                                colBackground: ColorUtils.mix(root.card, root.ink, 0.88)
                                onClicked: {
                                    if (modelData.id === "user")
                                        root.lens.openUser(root.post.author);
                                    else if (modelData.id === "sub")
                                        root.lens.openSub(root.post.subreddit);
                                    else if (modelData.id === "site")
                                        root.lens.showSite();
                                    else if (modelData.id === "copy")
                                        root.lens.copyLink();
                                    else
                                        root.lens.takePicture(root.post);
                                }

                                Row {
                                    anchors.centerIn: parent
                                    spacing: 5

                                    MaterialSymbol {
                                        id: actionIcon

                                        anchors.verticalCenter: parent.verticalCenter
                                        text: parent.parent.modelData.icon
                                        iconSize: 15
                                        color: root.dim
                                    }

                                    StyledText {
                                        id: actionLabel

                                        anchors.verticalCenter: parent.verticalCenter
                                        text: parent.parent.modelData.label
                                        font.pixelSize: Appearance.font.pixelSize.smallest
                                        color: root.ink
                                    }

                                }

                            }

                        }

                    }

                }
            }

            // How the comments are ordered — the site's own words for it.
            Row {
                spacing: 6

                Repeater {
                    model: ["confidence", "top", "new", "controversial", "old"]

                    delegate: RippleButton {
                        required property var modelData

                        /*
                         * `root.card` on top of the lens ground is two tones
                         * that differ by almost nothing, and `rounding.small`
                         * on a 26px button is not a pill either — so five
                         * unselected sorts were a line of prose. A rounded,
                         * tinted chip is visibly a control whether or not it is
                         * the one chosen. Not PillTab: that paints from the
                         * Material palette only, and this lens has a skin.
                         */
                        implicitHeight: 30
                        implicitWidth: sortLabel.implicitWidth + 26
                        buttonRadius: Appearance.rounding.full
                        toggled: root.lens.commentSort === modelData
                        colBackground: ColorUtils.mix(root.card, root.ink, 0.88)
                        colBackgroundToggled: root.accent
                        onClicked: root.lens.chooseCommentSort(modelData)

                        StyledText {
                            id: sortLabel
                            anchors.centerIn: parent
                            text: root.lens.commentSortLabel[parent.modelData] || parent.modelData
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            color: root.lens.commentSort === parent.modelData ? Appearance.colors.colOnPrimary : root.dim
                        }
                    }
                }
            }

            // Why there are no comments, when there are none.
            StyledText {
                width: parent.width
                visible: !root.lens.commentsLoading && root.lens.commentRows.length === 0
                horizontalAlignment: Text.AlignHCenter
                topPadding: 20
                text: root.lens.commentsError.length > 0 ? root.lens.commentsError : "Nobody has said anything yet"
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: root.lens.commentsError.length > 0 ? Appearance.colors.colError : root.dim
            }

            LoadingIndicator {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: root.lens.commentsLoading
                running: root.lens.commentsLoading
            }
        }

        // ── one comment, or a stub for the rest of a chain ───────────────────
        delegate: Item {
            id: rowItem
            required property var modelData
            width: list.width
            implicitHeight: body.implicitHeight + 14

            // A 1px line at half opacity on colLayer0, with 14px of indent
            // behind it — under one character wide — disappeared, and the tree
            // rendered as a flat list.
            readonly property real indentStep: 22
            readonly property real indent: Math.min(rowItem.modelData.depth, 8) * rowItem.indentStep

            // One guide per ancestor level, so a deep reply reads as attached
            // to something rather than floating at a margin.
            Repeater {
                model: Math.min(rowItem.modelData.depth, 8)

                delegate: Rectangle {
                    required property int index

                    // The line you are actually reading along is picked out in
                    // the accent, so a deep chain says which of the five guides
                    // beside it is its own.
                    readonly property bool own: index === rowItem.modelData.depth - 1

                    x: (index * rowItem.indentStep) + 8
                    y: 0
                    width: 2
                    radius: 1
                    height: rowItem.height
                    color: own ? root.accent : root.guide
                    opacity: own ? 0.6 : 0.4
                }
            }

            ColumnLayout {
                id: body
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: rowItem.indent + 14
                anchors.rightMargin: 8
                anchors.topMargin: 6
                spacing: 2

                // A stub: how much more there is, and one tap to fetch it.
                RippleButton {
                    // "3 more replies" was a button the full width of the
                    // column — it read as a section, not as something to press.
                    Layout.fillWidth: false
                    visible: rowItem.modelData.kind === "more"
                    implicitHeight: 28
                    implicitWidth: stubLabel.implicitWidth + 28
                    buttonRadius: Appearance.rounding.full
                    colBackground: ColorUtils.mix(root.card, root.accent, 0.85)
                    onClicked: root.lens.loadMore(rowItem.modelData)

                    StyledText {
                        id: stubLabel

                        anchors.centerIn: parent
                        text: root.lens.loadingStub === rowItem.modelData.id ? "Fetching the rest…" : `${rowItem.modelData.count || "more"} more replies`
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: root.accent
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    visible: rowItem.modelData.kind === "comment"
                    spacing: 6

                    StyledText {
                        // The name of somebody who said something is the way to
                        // what else they have said.
                        text: `<a href="user:${rowItem.modelData.author || ""}">${rowItem.modelData.author || ""}</a>`
                        textFormat: Text.StyledText
                        linkColor: rowItem.modelData.op ? root.accent : root.ink
                        onLinkActivated: (link) => {
                            return root.lens.openUser(link.slice(5));
                        }
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        font.weight: Font.DemiBold
                        color: rowItem.modelData.op ? root.accent : root.ink

                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.NoButton
                            cursorShape: parent.hoveredLink.length > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                        }

                    }
                    StyledText {
                        visible: rowItem.modelData.op
                        text: "OP"
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: root.accent
                    }
                    /*
                     * "128 · 4h" at 10px in the subtext tone was not readable
                     * as a score: no unit, no weight, no colour, nothing to
                     * separate the number from the age beside it. `colUpvote`
                     * was added to the palette for this row — "Reddit's own
                     * semantics: upvote warm" — and then never wired up.
                     */
                    MaterialSymbol {
                        visible: !rowItem.modelData.scoreHidden
                        text: "arrow_upward"
                        iconSize: 12
                        color: Appearance.colors.colUpvote
                    }

                    StyledText {
                        text: rowItem.modelData.scoreHidden ? "—" : Fmt.count(rowItem.modelData.score)
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        font.weight: Font.DemiBold
                        color: Appearance.colors.colUpvote
                    }

                    StyledText {
                        text: Fmt.ago(rowItem.modelData.created)
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: root.dim
                    }

                    Item {
                        Layout.fillWidth: true
                    }

                    // Fold this chain away. Hidden when there is nothing under
                    // it: a control that cannot do anything is worse than none.
                    StyledText {
                        visible: rowItem.modelData.collapsed
                        text: `${rowItem.modelData.replies} folded`
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: root.accent
                    }

                    IconButton {
                        visible: rowItem.modelData.replies > 0
                        icon: rowItem.modelData.collapsed ? "unfold_more" : "unfold_less"
                        tooltip: rowItem.modelData.collapsed ? "Open this chain" : "Fold this chain"
                        size: 24
                        iconSize: 15
                        // Transparent at rest behind a 15px thin-stroke glyph,
                        // pushed to the far edge of the row, is a control you
                        // have to already know is there. The skins paint
                        // everything else themselves; this one was still taking
                        // its hover from the Material palette.
                        toggled: rowItem.modelData.collapsed
                        iconColor: rowItem.modelData.collapsed ? root.accent : root.dim
                        hoverColor: ColorUtils.mix(root.card, root.ink, 0.88)
                        onClicked: root.lens.toggleCollapse(rowItem.modelData.id)
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    /*
                     * Collapsing folds the REPLIES away — see `walk` in
                     * thread.js, which stops recursing; the comment itself is
                     * still a row. Hiding its body as well meant that folding
                     * a chain erased the very thing you had just read and put
                     * a count in its place. The count moved up to the header
                     * row, beside the control that produced it.
                     */
                    visible: rowItem.modelData.kind === "comment"
                    wrapMode: Text.WordWrap
                    // Reddit `body` IS markdown — links, quotes, lists and
                    // code all arrive as syntax, and drawn plainly they were
                    // read as syntax too.
                    textFormat: Text.MarkdownText
                    linkColor: root.accent
                    onLinkActivated: (link) => {
                        return root.lens.openExternally(link);
                    }
                    text: rowItem.modelData.body || ""
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: root.ink

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        cursorShape: parent.hoveredLink.length > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                    }

                }
            }
        }
    }

    // Here from the first frame; the window's injector only adds one on its next scan.
    Momentum {
        flickable: list
    }

}
