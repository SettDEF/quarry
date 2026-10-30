import "../fmt.js" as Fmt
import QtMultimedia
import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import qs.modules.common
import qs.modules.widgets
import qs.services

/*
 * ONE CONVERSATION, READ.
 *
 * Bubbles, oldest at the top, yours on the right. A message carrying a picture
 * draws it at a readable size and opens full size on a click; a message that is
 * only a file says what it is. Service lines — "joined the group" — are centred
 * captions rather than bubbles, because nobody said them.
 *
 * Nothing here can write: no composer, no reactions, no read marks. This lens
 * does not even tell Telegram the chat is open (see Main.qml), so what is drawn
 * is what was fetched, and the refresh button is how it moves.
 */
ListView {
    id: root

    required property var lens

    // `link`: the href under the pointer, "" when the click was not on one.
    signal contextRequested(var message, real sceneX, real sceneY, string link)

    model: root.lens.messages

    /*
     * A CHANNEL IS A FEED, NOT A CONVERSATION.
     *
     * Every post in a channel is the channel's, so drawn as a chat they all hung
     * off the left edge with half the pane empty, each under the channel's own
     * name, each a different width. Telegram draws a channel as one column of
     * posts the same width, with no author line; so does this. The skin
     * centres the column (see Quarry.qml).
     */
    readonly property bool channel: !!root.lens.chat && String(root.lens.chat.kind || "") === "channel"
    // The gap is each row's own (see `gap`), so an album's folded rows take none.
    spacing: 0
    topMargin: 12
    // Room for the dock floating over the end of the list.
    bottomMargin: 24 + Host.bottomInset
    leftMargin: 14
    rightMargin: 14
    clip: true
    cacheBuffer: 1200
    boundsBehavior: Flickable.StopAtBounds
    // Index 0 is the newest, and it belongs at the bottom.
    verticalLayoutDirection: ListView.VerticalBottomToTop

    /*
     * BACK LANDS WHERE YOU LEFT, not at the newest message.
     *
     * Following a link out of a chat and coming back used to reopen it at the
     * bottom, so the thing you were reading was gone and you had to find it
     * again — in a channel with ninety thousand messages that is not a search
     * anyone wants to repeat. Keyed by chat, so each one keeps its own place.
     *
     * Prefs caps this at 200 keys, so a Telegram account with hundreds of
     * chats cannot grow the settings file without bound.
     */
    RememberScroll {
        view: root
        key: `morse:chat:${root.lens.chatId}`
    }

    // A message arriving while you read older ones leaves you where you were.
    KeepPlace {
        view: root
        items: root.lens.messages
    }

    StyledText {
        // Parented to the view, not its content: a child declared in a view
        // lands in `contentItem`, where "centred" means centred on the rows.
        parent: root
        anchors.centerIn: parent
        visible: root.count === 0 && root.lens.linkReady
        text: root.lens.loadingMessages ? "Reading…" : (root.lens.errorText.length > 0 ? root.lens.errorText : "Nothing here.")
        color: Appearance.colors.colSubtext
    }

    /*
     * "NOTHING HERE." WAS A LIE ABOUT THE CHAT.
     *
     * A conversation with no messages and a link that is not ready are two
     * completely different facts, and this screen said the first one for
     * both. Opened while Morse was signed out, a chat full of messages read
     * "Nothing here." — describing the chat, when the truth was about the
     * connection: quarry had not been told anything about that chat at all.
     */
    PagePlaceholder {
        parent: root
        anchors.fill: parent
        anchors.margins: 24
        visible: root.count === 0 && !root.lens.linkReady
        icon: root.lens.linkState === "absent" ? "chat_bubble" : "sync"
        title: root.lens.linkReason
        description: root.lens.linkDetail
        busy: root.lens.linkState === "starting" || root.lens.linkState === "connecting"
        actionText: root.lens.linkState === "absent" ? "Start Morse" : ""
        actionIcon: "play_arrow"
        onActionTriggered: root.lens.startLink()
    }

    ScrollBar.vertical: StyledScrollBar {
        view: root
    }

    delegate: Item {
        id: row

        required property var modelData
        required property int index
        readonly property bool outgoing: row.modelData.outgoing === true
        readonly property bool service: row.modelData.service === true
        readonly property var media: row.modelData.media || null
        readonly property bool drawable: Fmt.isDrawable(row.media)
        readonly property bool hasPicture: row.media !== null && row.drawable
        /*
         * AN ALBUM IS ONE BUBBLE.
         *
         * Its frames arrive as consecutive messages sharing an `albumId`. The
         * newest of them (the lowest index — the one at the bottom) draws the
         * whole album as a mosaic; the rest fold to nothing. Telegram does the
         * same: eight photos sent together are one thing somebody said.
         */
        readonly property string albumId: row.modelData.albumId ? String(row.modelData.albumId) : ""
        readonly property var albumRun: {
            if (row.albumId.length === 0 || !row.hasPicture)
                return null;
            const all = root.lens.messages;
            const same = m => m && m.albumId && String(m.albumId) === row.albumId;
            let lo = row.index, hi = row.index;
            while (same(all[lo - 1]))
                lo--;
            while (same(all[hi + 1]))
                hi++;
            return hi > lo ? { "lo": lo, "hi": hi } : null;
        }
        readonly property bool folded: row.albumRun !== null && row.index !== row.albumRun.lo
        readonly property bool isAlbum: row.albumRun !== null && !row.folded
        /// The album's messages oldest first, the order they were sent.
        readonly property var albumItems: row.isAlbum ? root.lens.messages.slice(row.albumRun.lo, row.albumRun.hi + 1).reverse() : []
        /// An album's words live on whichever frame carried them.
        readonly property string captionText: {
            if (!row.isAlbum)
                return String(row.modelData.text || "");
            const said = row.albumItems.map(m => String(m.text || "")).filter(t => t.length > 0);
            return said.join("\n");
        }
        readonly property int gap: row.folded ? 0 : 6
        /// Whose name sits above the bubble, and whether words sit under the
        /// picture — both decide where the bubble's padding is allowed to be.
        /// The message BELOW this one on screen: index+1 is the older one,
        /// because the model is newest-first and the list is laid out bottom
        /// to top.
        // Past an album's folded rows, which are not on screen.
        readonly property var older: root.lens.messages[(row.isAlbum ? row.albumRun.hi : row.index) + 1] || null
        /// A new day starts at this message — see `day` in fmt.js for why a
        /// conversation needs saying at all.
        readonly property bool startsDay: {
            if (!row.older)
                return true;

            const here = new Date(Number(row.modelData.date || 0) * 1000);
            const before = new Date(Number(row.older.date || 0) * 1000);
            return here.toDateString() !== before.toDateString();
        }
        /*
         * ONE NAME OVER A RUN, NOT ONE OVER EACH LINE.
         *
         * Six messages from the same person printed that person's name six
         * times. A name is worth drawing when the speaker CHANGES — or when
         * the day does, because the run above is then a different sitting.
         */
        readonly property bool showsSender: !root.channel && !row.outgoing && String(row.modelData.senderName || "").length > 0 && (row.startsDay || row.older === null || row.older.outgoing === true || row.older.service === true || String(row.older.senderName || "") !== String(row.modelData.senderName || ""))
        readonly property bool hasCaption: row.captionText.length > 0
        /*
         * THE PICTURE'S OWN SHAPE, WHICH IS TELEGRAM'S WHOLE RULE.
         *
         * This used to be `width: parent.width` and `height: min(320, …)`
         * with PreserveAspectCrop — a fixed slot that the picture was CUT to
         * fit. Anything tall lost its top and bottom: a phone screenshot
         * arrived as a band from the middle, which is exactly the part of a
         * screenshot nobody is sending you.
         *
         * Telegram never does that. A photo is fitted, whole, into a box —
         * wide ones hit the width limit, tall ones hit the height limit and
         * become NARROW rather than a slice of themselves — and the bubble is
         * then drawn around whatever shape came out. The only pictures it
         * crops are the ones so extreme (a panorama, a metre-tall meme) that
         * fitting would leave a sliver a hundred pixels wide.
         */
        readonly property real shotRatio: {
            const m = row.media;
            const w = m ? Number(m.width || 0) : 0;
            const h = m ? Number(m.height || 0) : 0;
            return w > 0 && h > 0 ? h / w : 0.62;
        }
        readonly property int shotMaxW: root.channel ? row.width : Math.max(160, Math.min(Math.round(root.width * 0.6), 560))
        readonly property int shotMaxH: root.channel ? 600 : 520
        /// An album gets the full picture width: its frames share it.
        readonly property int albumW: Math.max(220, row.shotMaxW)
        readonly property int shotMinW: 140
        readonly property int shotW: {
            // A channel post is the column's width; a tall picture is fitted
            // inside it rather than narrowing the post.
            if (root.channel)
                return row.width;
            if (row.shotMaxW * row.shotRatio <= row.shotMaxH)
                return row.shotMaxW;

            return Math.max(row.shotMinW, Math.round(row.shotMaxH / row.shotRatio));
        }
        readonly property int shotH: Math.min(row.shotMaxH, Math.round(row.shotW * row.shotRatio))
        /// True only for the extremes the box cannot hold whole.
        readonly property bool shotCropped: !root.channel && row.shotW * row.shotRatio > row.shotH + 1
        readonly property bool moving: Fmt.isMoving(row.media)
        /*
         * ON SCREEN, NOT MERELY EXISTING.
         *
         * A ListView keeps a screen of delegates alive on either side, so
         * "this delegate is built" is not "you can see it". A dozen players
         * running above and below the viewport is the stutter this whole guard
         * exists to prevent. `contentY` is read so it recomputes while
         * scrolling, and a small margin keeps a clip from restarting when it
         * is half off the edge.
         */
        readonly property bool onScreen: {
            if (!row.moving)
                return false;

            root.contentY;
            const top = row.mapToItem(root, 0, 0).y;
            return top + row.height > -80 && top < root.height + 80;
        }
        /// What plays here, "" when nothing should. Covered means covered: a
        /// clip inside a spoiler does not start until the spoiler is opened.
        readonly property string playing: row.onScreen && !(row.hasSpoiler && !row.spoilerShown) ? root.lens.playFile(row.modelData) : ""
        readonly property bool hasSpoiler: {
            const runs = row.modelData.entities || [];
            for (let i = 0; i < runs.length; i++) if (String(runs[i].kind) === "spoiler") {
                return true;
            }
            return false;
        }
        property bool spoilerShown: false

        // The oldest few coming into existence IS the ask for older ones —
        // which holds whichever way the list is laid out, where a contentY
        // threshold does not.
        Component.onCompleted: {
            if (row.index >= root.count - 3)
                root.lens.loadOlder();

        }
        width: root.width - root.leftMargin - root.rightMargin
        implicitHeight: row.folded ? 0 : (row.service ? caption.implicitHeight + 10 : bubble.implicitHeight + 2) + (row.startsDay ? dayMark.height + 8 : 0) + row.gap
        height: implicitHeight
        visible: !row.folded

        // ── a line about the chat, not a message in it ───────────────────────
        StyledText {
            id: caption

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            // Centred in what is left under the day mark, not in the whole row
            // — otherwise the first service line of a day sits on top of it.
            anchors.verticalCenterOffset: row.startsDay ? Math.round((dayMark.height + 8) / 2) : 0
            visible: row.service
            width: parent.width * 0.8
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: {
                const what = String(row.modelData.text || "");
                const who = String(row.modelData.senderName || "");
                // The daemon sends a predicate for the ones that need a name in
                // front, and a whole sentence (capitalised) for the ones that
                // do not.
                return who.length > 0 && what.length > 0 && what[0] === what[0].toLowerCase() ? `${who} ${what}` : what;
            }
            font.pixelSize: Appearance.font.pixelSize.smallest
            color: Appearance.colors.colSubtext
        }

        // ── which day the messages under this line belong to ────────────────
        Rectangle {
            id: dayMark

            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            visible: row.startsDay
            width: dayText.implicitWidth + 20
            height: visible ? 22 : 0
            radius: Appearance.rounding.full
            color: Appearance.colors.colLayer1

            StyledText {
                id: dayText

                anchors.centerIn: parent
                text: Fmt.day(row.modelData.date)
                font.pixelSize: Appearance.font.pixelSize.smallest
                font.weight: Font.DemiBold
                color: Appearance.colors.colSubtext
            }

        }

        Rectangle {
            id: bubble

            anchors.top: dayMark.bottom
            anchors.topMargin: row.startsDay ? 8 : 0
            visible: !row.service
            anchors.right: row.outgoing ? parent.right : undefined
            anchors.left: row.outgoing ? undefined : parent.left
            // NOT from `body.implicitWidth`: the column inside is anchored to
            // this width, so reading its implicit size here is a binding that
            // writes what it reads — Qt breaks one of the two at random and
            // bubbles size wrongly until something scrolls.
            /*
             * A message that is a picture is as wide as the picture — the
             * bubble is drawn around it, not the other way round. EXCEPT when
             * there are words under it: a tall photo fits the box at `shotMinW`
             * = 140, and a caption was being wrapped into a column six words
             * wide and twenty lines deep. Telegram widens the bubble to the
             * caption and leaves the photograph its own size.
             */
            readonly property int textFloor: Math.min(row.width * 0.5, 280)

            /*
             * Words: as wide as their longest line, up to the cap — measured
             * from the text with FontMetrics, not from `body`, for the reason
             * above. A fixed width was fine in a 520px column; across the whole
             * pane "ok" got a bubble 750 pixels wide.
             */
            readonly property int textCap: Math.min(parent.width * 0.75, 860)
            readonly property int textW: {
                let widest = 0;
                for (const line of row.captionText.split("\n"))
                    widest = Math.max(widest, words.advanceWidth(line));
                const name = row.showsSender ? words.advanceWidth(String(row.modelData.senderName || "")) : 0;
                // The clock row under the words needs about 90px of its own.
                return Math.min(bubble.textCap, Math.ceil(Math.max(widest, name, 90)) + 24);
            }

            width: root.channel ? row.width : row.isAlbum ? row.albumW : row.hasPicture ? (row.hasCaption ? Math.max(row.shotW, bubble.textFloor) : row.shotW) : row.media !== null ? Math.max(bubble.textW, 240) : bubble.textW
            implicitHeight: body.implicitHeight + body.anchors.topMargin + body.anchors.bottomMargin
            height: implicitHeight
            radius: Appearance.rounding.normal
            color: row.outgoing ? Appearance.colors.colSecondaryContainer : Appearance.colors.colLayer1

            FontMetrics {
                id: words

                font.family: Appearance.font.family.reading
                font.pixelSize: Appearance.font.pixelSize.small
            }

            TapHandler {
                acceptedButtons: Qt.RightButton
                gesturePolicy: TapHandler.ReleaseWithinBounds
                onSingleTapped: (eventPoint) => {
                    return root.contextRequested(row.modelData, eventPoint.scenePosition.x, eventPoint.scenePosition.y, message.hovered);
                }
            }

            TapHandler {
                enabled: row.hasSpoiler && !row.spoilerShown
                gesturePolicy: TapHandler.ReleaseWithinBounds
                onTapped: row.spoilerShown = true
            }

            Column {
                /*
                 * NAMED BECAUSE THE BUBBLE MEASURES ITSELF FROM IT.
                 *
                 * `bubble.implicitHeight` above and the picture's flush `x`
                 * below both read `body`. The id went missing when the message
                 * text was named for the hover-underline binding, so both of
                 * those threw a ReferenceError, every bubble kept the
                 * Rectangle's default height of zero, and the conversation drew
                 * as a stack of two-pixel slivers.
                 */
                id: body

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                /*
                 * A PICTURE IS FLUSH WITH THE BUBBLE; WORDS ARE NOT.
                 *
                 * Telegram insets text by ten pixels and lets a photo run
                 * corner to corner — the padding under a photo belongs to the
                 * caption, and a photo with no caption has none at all. The
                 * inset only survives where something is actually drawn in it.
                 */
                anchors.topMargin: row.hasPicture && !row.showsSender ? 0 : 8
                // The padding under a photo belongs to the caption — but the
                // time and the reactions are drawn under it too, and at zero
                // they sat on the bubble's own edge with their descenders
                // inside the corner radius. The clock is words.
                anchors.bottomMargin: row.hasPicture && !row.hasCaption ? 4 : 8
                spacing: 4

                StyledText {
                    width: parent.width
                    // `showsSender`, not the condition restated: the two had
                    // already drifted, and this one is the run rule.
                    visible: row.showsSender
                    elide: Text.ElideRight
                    text: row.modelData.senderName || ""
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    font.weight: Font.DemiBold
                    color: Appearance.colors.colPrimary
                }

                // ── the picture ──────────────────────────────────────────────
                AlbumMosaic {
                    x: -body.anchors.leftMargin
                    visible: row.isAlbum
                    width: row.albumW
                    height: visible ? implicitHeight : 0
                    lens: root.lens
                    items: row.albumItems
                    wantsFull: row.onScreen
                    onContextRequested: (message, x, y) => root.contextRequested(message, x, y, "")
                }

                Item {
                    // Flush: the column's ten pixels of padding are for words.
                    x: -body.anchors.leftMargin
                    visible: row.hasPicture && !row.isAlbum
                    // The picture's own width, not the bubble's — a captioned
                    // bubble is wider than its photograph now.
                    width: row.shotW
                    height: visible ? row.shotH : 0

                    Rectangle {
                        anchors.fill: parent
                        radius: Appearance.rounding.small
                        color: Appearance.colors.colLayer2
                        clip: true
                        /*
                         * A SPOILER COVERS THE PICTURE, NOT ONLY THE WORDS.
                         *
                         * Only the caption was blurred. The photograph under it
                         * was drawn sharp — so a message somebody deliberately
                         * hid was the one thing on screen you could not miss.
                         */
                        layer.enabled: row.hasSpoiler && !row.spoilerShown

                        layer.effect: MultiEffect {
                            blurEnabled: true
                            blur: 1
                            blurMax: 64
                            autoPaddingEnabled: false
                        }

                        // The picture and its stand-in, which cross-fade
                        // rather than swap — see Shot.qml for why a stretched
                        // minithumbnail has to be blurred before it is shown.
                        Shot {
                            anchors.fill: parent
                            // The box is already the picture's own shape, so
                            // "crop" and "fit" agree — except on the extremes,
                            // where the box was clamped and cropping is what
                            // Telegram does too.
                            fillMode: row.shotCropped ? Image.PreserveAspectCrop : Image.PreserveAspectFit
                            placeholder: root.lens.miniOf(row.modelData)
                            source: {
                                /*
                                 * PICTURES ONLY — an Image cannot decode an mp4.
                                 *
                                 * The same fault as the media wall had: a clip
                                 * whose file had arrived was handed to an Image
                                 * and drew nothing, while the identical clip
                                 * before its download drew its thumbnail. The
                                 * player below is what shows a moving one.
                                 */
                                if (row.moving)
                                    return root.lens.realThumbOf(row.modelData);

                                // On screen: ask for the real file. Off screen: whatever is
                                // already here. See `wantFull` — a photograph you are looking
                                // at is worth its own download; one you scrolled past is not.
                                const full = row.onScreen ? root.lens.wantFull(row.modelData) : root.lens.heldFile(row.modelData);
                                if (full.length > 0 && !Fmt.isVideoPath(full))
                                    return full;

                                const held = root.lens.heldFile(row.modelData);
                                return held.length > 0 && !Fmt.isVideoPath(held) ? held : root.lens.realThumbOf(row.modelData);
                            }
                        }

                        /*
                         * Built when the clip is on screen and torn down when
                         * it is not — `active` is the whole of the resource
                         * management here. Muted by having no audio output at
                         * all, which is also one less object per clip.
                         */
                        Loader {
                            anchors.fill: parent
                            active: row.playing.length > 0
                            visible: active

                            sourceComponent: Item {
                                // Counted so the "only on screen" rule can be
                                // measured rather than believed.
                                Component.onCompleted: root.lens.playerOpened()
                                Component.onDestruction: root.lens.playerClosed()

                                VideoOutput {
                                    id: output

                                    anchors.fill: parent
                                    fillMode: VideoOutput.PreserveAspectCrop
                                }

                                MediaPlayer {
                                    source: row.playing
                                    videoOutput: output
                                    loops: MediaPlayer.Infinite
                                    Component.onCompleted: play()
                                }

                            }

                        }

                        // Coming, or given up — see FetchBadge. Hidden the
                        // moment a usable file lands.
                        FetchBadge {
                            anchors.centerIn: parent
                            state: root.lens.fileStateOf(row.modelData)
                            visible: shown && !(row.moving && row.playing.length === 0)
                            onRetried: root.lens.retryFile(row.modelData)
                        }

                        HoverHandler {
                            id: shotHover

                            cursorShape: Qt.PointingHandCursor
                        }

                        TapHandler {
                            // While it is covered the bubble's reveal handler
                            // gets the tap. Opening a spoiler full size on the
                            // first click is the one thing this must not do.
                            enabled: !(row.hasSpoiler && !row.spoilerShown)
                            gesturePolicy: TapHandler.ReleaseWithinBounds
                            onTapped: root.lens.openViewer(row.modelData)
                        }

                        // The badge says "this moves". Once it IS moving, it
                        // would only be covering the picture.
                        Rectangle {
                            anchors.centerIn: parent
                            width: 46
                            height: 46
                            radius: 23
                            visible: row.moving && row.playing.length === 0
                            color: Appearance.colors.colLayer0Base
                            opacity: 0.85

                            MaterialSymbol {
                                anchors.centerIn: parent
                                text: "play_arrow"
                                iconSize: 24
                                color: Appearance.colors.colOnLayer0
                            }

                        }

                        // On a pill: pale text straight on a picture is
                        // unreadable on half of them.
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 10
                            visible: row.moving && row.playing.length === 0 && root.lens.tooBigToAutoplay(row.modelData)
                            width: clipInfo.implicitWidth + 20
                            height: 24
                            radius: 12
                            color: Appearance.colors.colLayer0Base
                            opacity: 0.88

                            StyledText {
                                id: clipInfo

                                anchors.centerIn: parent
                                // How long, before how big: a 1.8 GB clip that
                                // is forty minutes is a film, not an error.
                                text: [row.media && row.media.duration > 0 ? Fmt.duration(row.media.duration) : "", Fmt.size(row.media ? row.media.size : 0), "tap to play"].filter(t => t.length > 0).join(" · ")
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                color: Appearance.colors.colOnLayer0
                            }
                        }

                        Rectangle {
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: 6
                            width: 28
                            height: 28
                            radius: 14
                            // Nothing still covered can be filed into the
                            // catalogue by hovering it.
                            visible: !root.lens.chatIsSecret && !(row.hasSpoiler && !row.spoilerShown) && (shotHover.hovered || keepHover.hovered || root.lens.isAdded(row.modelData))
                            color: root.lens.isAdded(row.modelData) ? Appearance.colors.colPrimaryContainer : Appearance.colors.colLayer0Base
                            opacity: 0.9

                            MaterialSymbol {
                                anchors.centerIn: parent
                                text: root.lens.isAdded(row.modelData) ? "check" : "add_photo_alternate"
                                iconSize: 16
                                color: root.lens.isAdded(row.modelData) ? Appearance.colors.colOnPrimaryContainer : Appearance.colors.colOnLayer0
                            }

                            HoverHandler {
                                id: keepHover

                                cursorShape: Qt.PointingHandCursor
                            }

                            TapHandler {
                                gesturePolicy: TapHandler.ReleaseWithinBounds
                                onTapped: root.lens.take(row.modelData, null)
                            }

                            StyledToolTip {
                                visible: keepHover.hovered
                                text: root.lens.isAdded(row.modelData) ? "In your catalogue" : "Keep it in quarry"
                            }

                        }

                    }

                }

                // ── a file that is not a picture: a card you can act on ───────
                Rectangle {
                    id: fileCard
                    visible: row.media !== null && !row.drawable
                    width: Math.min(360, fileRow.implicitWidth + 24)
                    height: visible ? 56 : 0
                    radius: Appearance.rounding.normal
                    color: fileHover.hovered ? Appearance.colors.colLayer2Hover : Appearance.colors.colLayer2

                    HoverHandler {
                        id: fileHover
                        cursorShape: Qt.PointingHandCursor
                    }

                    // Click: open it in its own app (downloaded first if need be).
                    TapHandler {
                        gesturePolicy: TapHandler.ReleaseWithinBounds
                        onTapped: root.lens.openFile(row.modelData)
                    }

                    Row {
                        id: fileRow
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 10

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 36
                            height: 36
                            radius: 18
                            color: Appearance.colors.colPrimaryContainer

                            MaterialSymbol {
                                anchors.centerIn: parent
                                text: Fmt.mediaIcon(row.media)
                                iconSize: 20
                                color: Appearance.colors.colOnPrimaryContainer
                            }
                        }

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 0

                            StyledText {
                                width: Math.min(implicitWidth, 200)
                                elide: Text.ElideMiddle
                                text: (row.media && row.media.name) || Fmt.mediaLabel(row.media)
                                font.pixelSize: Appearance.font.pixelSize.small
                                color: Appearance.colors.colOnLayer1
                            }

                            StyledText {
                                text: {
                                    const parts = [];
                                    if (row.media && row.media.size > 0)
                                        parts.push(Fmt.size(row.media.size));
                                    if (row.media && row.media.duration > 0)
                                        parts.push(Fmt.duration(row.media.duration));
                                    parts.push(root.lens.heldFile(row.modelData).length > 0 ? "downloaded" : "click to open");
                                    return parts.join(" · ");
                                }
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                color: Appearance.colors.colSubtext
                            }
                        }

                        IconButton {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: !root.lens.chatIsSecret
                            icon: "download"
                            tooltip: "Save to Downloads"
                            onClicked: root.lens.saveFile(row.modelData)
                        }

                        IconButton {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: !root.lens.chatIsSecret
                            icon: "folder_open"
                            tooltip: "Show in folder"
                            onClicked: root.lens.showFile(row.modelData)
                        }
                    }
                }

                // ── the words ────────────────────────────────────────────────
                StyledText {
                    /*
                     * LINKS ARE MARKED UP — AND ONLY LINKS.
                     *
                     * Morse's protocol is right that building markup out of a
                     * stranger's message is not a client's job. But a link that
                     * cannot be pressed is a message you have to retype by
                     * hand. So exactly one thing is turned into markup, found
                     * by a pattern rather than by trusting the sender's
                     * entities, and everything else stays the plain text it
                     * arrived as.
                     */
                    id: message

                    /// Which link the pointer is on, so only that one is
                    /// underlined. See the builder above.
                    property string hovered: ""

                    /*
                     * A WALL OF TEXT IS STILL A WALL.
                     *
                     * Telegram allows 4096 characters in one message, and a
                     * pasted article arrives as a single bubble taller than the
                     * window: four flicks to get past it, with the messages
                     * either side of it gone. Cut at eighteen lines — about a
                     * screenful — with the rest one click away.
                     */
                    property bool expanded: false

                    width: parent.width
                    visible: text.length > 0
                    wrapMode: Text.Wrap
                    maximumLineCount: message.expanded ? 100000 : 18
                    elide: Text.ElideRight
                    textFormat: Text.StyledText
                    text: {
                        const plain = row.captionText;
                        const escaped = plain.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
                        return escaped.replace(/(https?:\/\/[^\s<]+|t\.me\/[^\s<]+)/g, (match) => {
                            const href = match.indexOf("http") === 0 ? match : `https://${match}`;
                            /*
                             * UNDERLINED ONLY WHERE THE POINTER IS.
                             *
                             * Qt underlines every `<a>` by default, which in
                             * a chat means a wall of messages full of ruled
                             * blue text. A link is still obviously a link
                             * from its colour; the underline is what says
                             * "this one, the one you are about to click".
                             *
                             * `hovered` is set from `onLinkHovered` rather
                             * than read from `hoveredLink` directly: this
                             * text is REBUILT when it changes, and reading
                             * the property the rebuild affects is a loop.
                             */
                            const here = href === message.hovered;
                            return `<a href="${href}" style="text-decoration: ${here ? "underline" : "none"}">${match}</a>`;
                        });
                    }
                    onLinkHovered: (link) => {
                        return message.hovered = link;
                    }
                    linkColor: Appearance.colors.colPrimary
                    // `t.me` goes to the chat it names rather than to a browser
                    // showing a page the account cannot use — see openLink.
                    onLinkActivated: (url) => {
                        return root.lens.openLink(url);
                    }
                    layer.enabled: row.hasSpoiler && !row.spoilerShown
                    font.family: Appearance.font.family.reading
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: row.outgoing ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1

                    /*
                     * SHIFT-CLICK GOES STRAIGHT TO YOUR BROWSER.
                     *
                     * `onLinkActivated` is given the href and nothing else —
                     * no modifiers — so the keyboard state has to be read from
                     * a press. This area takes the press only when shift is
                     * down over a link; every other click falls through to the
                     * Text, which activates the link as before.
                     *
                     * Middle-click does the same thing, because that is the
                     * other gesture everyone already has in their hands.
                     */
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                        propagateComposedEvents: true
                        cursorShape: parent.hoveredLink.length > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor

                        onPressed: (mouse) => {
                            const link = parent.hoveredLink;
                            const wanted = (mouse.modifiers & Qt.ShiftModifier) !== 0
                                || mouse.button === Qt.MiddleButton;
                            if (link.length === 0 || !wanted) {
                                // Not ours: let the Text have it.
                                mouse.accepted = false;
                                return ;
                            }
                            root.lens.openLink(link, true);
                            mouse.accepted = true;
                        }
                    }

                    // A spoiler run is text the sender chose to hide, and
                    // drawing it plainly reveals it — so `layer.enabled` above
                    // covers the words until the bubble is clicked. The comment
                    // explaining that binding used to sit ten lines below it.
                    layer.effect: MultiEffect {
                        blurEnabled: true
                        blur: 1
                        blurMax: 32
                        autoPaddingEnabled: false
                    }

                }

                StyledText {
                    // `truncated` is the Text's own answer, so this appears
                    // exactly when something was actually cut and never when a
                    // message happened to be seventeen lines long.
                    visible: message.truncated || message.expanded
                    text: message.expanded ? "Show less" : "Show more"
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    font.weight: Font.DemiBold
                    color: Appearance.colors.colPrimary

                    HoverHandler {
                        cursorShape: Qt.PointingHandCursor
                    }

                    TapHandler {
                        gesturePolicy: TapHandler.ReleaseWithinBounds
                        onTapped: message.expanded = !message.expanded
                    }

                }

                Row {
                    width: parent.width
                    spacing: 6
                    layoutDirection: row.outgoing ? Qt.RightToLeft : Qt.LeftToRight

                    StyledText {
                        text: Fmt.when(row.modelData.date)
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: Appearance.colors.colSubtext
                    }

                    StyledText {
                        visible: (row.modelData.editedAt || 0) > 0
                        text: "edited"
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: Appearance.colors.colSubtext
                    }

                    Repeater {
                        model: row.modelData.reactions || []

                        delegate: StyledText {
                            required property var modelData

                            text: `${modelData.emoji} ${modelData.count}`
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            color: modelData.chosen === true ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                        }

                    }

                }

            }

        }

    }

}
