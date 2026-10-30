import "../fmt.js" as Fmt
import QtMultimedia
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.modules.common
import qs.modules.widgets
import qs.services

/*
 * A CHAT'S PICTURES, AS A WALL.
 *
 * This is the screen quarry exists for. Everything a chat has ever carried,
 * asked for as one server-side question (see Main.qml), drawn from thumbnails
 * that are already on this machine — no download until something is opened or
 * kept, so scrolling four years of a group chat costs nothing.
 */
GridView {
    id: root

    required property var lens
    // The chosen shape, not a fixed 200 — see `wallLayouts` on the lens. A
    // list is one column of short rows; the rest are square cells of its size.
    readonly property bool asList: root.lens.wallLayout === "compact"
    /// The wall keeps each picture's real shape, the way the gallery's does;
    /// grid and contact sheet are even squares at two sizes.
    readonly property bool keepsShape: root.lens.wallLayout === "wall"
    readonly property int columns: root.asList ? 1 : Math.max(2, Math.floor((root.width - 16) / Math.max(90, root.lens.wallCell)))

    signal contextRequested(var message, real sceneX, real sceneY)

    /*
     * One cell per THING POSTED, not per file.
     *
     * Four pictures sent together are one act — every Telegram client draws
     * them as one mosaic — so the model is the grouped one and a cell knows
     * how many frames are behind it. See `mediaGrouped` on the lens.
     */
    model: root.lens.mediaGrouped
    cellWidth: Math.floor((root.width - 16) / root.columns)
    cellHeight: root.asList ? 84 : root.keepsShape ? Math.round(root.cellWidth * 0.78) : root.cellWidth
    leftMargin: 8
    topMargin: 10
    // Room for the dock floating over the end of the list.
    bottomMargin: 24 + Host.bottomInset
    clip: true
    cacheBuffer: 900

    // Per chat AND per layout: the same wall at two tile sizes is two
    // different scroll positions, and restoring one into the other lands
    // somewhere arbitrary. See RememberScroll.
    RememberScroll {
        view: root
        key: `morse:media:${root.lens.chatId}:${root.lens.wallLayout}`
    }
    boundsBehavior: Flickable.StopAtBounds
    // Two screens from the end, ask for the next page. `nextFromId` is opaque
    // and handed straight back; nothing here reads it.
    onContentYChanged: {
        // Warming the next screen and asking for the next page are the same
        // event: two `onContentYChanged` handlers are not two behaviours, they
        // are one property set twice, and the component fails to exist at all.
        prefetch.restart();
        // Only once there is something to scroll: an empty or one-row wall is
        // always "near the end", and would walk the whole chat unasked.
        if (root.count > 0 && root.contentHeight > root.height && root.lens.hasMore && !root.lens.loadingMedia && contentY + height > contentHeight - height * 2)
            root.lens.loadMedia(false);

    }

    /*
     * Warm the next screen while this one is being looked at.
     *
     * Throttled to once every 250ms and bounded on the lens's side: a fling
     * through a thousand rows must warm what you are flying toward, not every
     * row you passed.
     */
    Timer {
        id: prefetch

        interval: 250
        onTriggered: {
            const groups = root.lens.mediaGrouped;
            if (groups.length === 0)
                return ;

            const perRow = Math.max(1, root.columns);
            const firstRow = Math.max(0, Math.floor(root.contentY / Math.max(1, root.cellHeight)));
            const from = firstRow * perRow;
            const ahead = [];
            for (let i = from; i < Math.min(groups.length, from + perRow * 6); i++) for (const message of groups[i].items) ahead.push(message)
            root.lens.prefetchThumbs(ahead);
        }
    }

    /*
     * AN EMPTY WALL IS A QUESTION THAT HAS AN ANSWER.
     *
     * This was one grey sentence in the middle of a blank grid: no glyph, no
     * motion at all while the first page was in flight, and — after choosing
     * "GIFs" in a chat that has none — nothing to press to get back to
     * everything, and no mention that a filter was the reason. Every other
     * empty state in quarry is a PagePlaceholder; so is this one now.
     */
    PagePlaceholder {
        // The viewport, not the content: see Conversation.qml.
        parent: root
        anchors.fill: parent
        anchors.margins: 24
        visible: root.count === 0 && root.lens.linkReady
        busy: root.lens.loadingMedia
        icon: root.lens.errorText.length > 0 ? "error" : root.lens.wallFilter === "photoAndVideo" ? "image_not_supported" : "filter_alt_off"
        title: {
            if (root.lens.loadingMedia)
                return "Asking for this chat's pictures…";

            if (root.lens.errorText.length > 0)
                return "Morse would not answer";

            if (root.lens.wallFilter === "photoAndVideo")
                return "Nothing of that kind in this chat";

            const chosen = root.lens.wallFilters.filter(f => f.id === root.lens.wallFilter)[0];
            return `No ${String(chosen ? chosen.label : "files").toLowerCase()} in this chat`;
        }
        description: root.lens.errorText
        // The filter is this screen's own doing, so this screen undoes it.
        actionText: !root.lens.loadingMedia && root.lens.wallFilter !== "photoAndVideo" ? "Show everything" : ""
        actionIcon: "photo_library"
        onActionTriggered: root.lens.setWallFilter("photoAndVideo")
    }

    /*
     * "IT ISN'T RUNNING" IS NOT AN ANSWER ON ITS OWN.
     *
     * This screen used to be one grey sentence — Morse isn't running, start
     * it and this fills itself in — with no way to start it and no hint of
     * what quarry had already tried. The lens starts the daemon by itself;
     * when that fails there is a reason, and when it has not happened yet
     * there is a button.
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
        id: cell

        required property var modelData
        /// The group's first frame is what a cell is "about"; the rest are the
        /// mosaic behind it and the pages of the viewer it opens.
        readonly property var group: cell.modelData
        readonly property var lead: cell.group.items[0]
        readonly property int frames: cell.group.items.length
        readonly property bool album: cell.frames > 1
        /// Drawn as a mosaic: a grid cell, not a list row.
        readonly property bool mosaic: cell.album && !root.asList
        readonly property var media: cell.lead.media || null
        readonly property bool added: root.lens.isAdded(cell.lead)
        readonly property bool moving: Fmt.isMoving(cell.media)
        /// Asked for only while the pointer is on it, so a wall of clips
        /// fetches nothing by scrolling past.
        readonly property string playing: hover.hovered ? root.lens.playFile(cell.lead) : ""

        width: root.cellWidth
        height: root.cellHeight

        Rectangle {
            anchors.fill: parent
            /*
             * TELEGRAM'S SHARED MEDIA IS A TIGHT GRID.
             *
             * Four pixels a side is an eight-pixel gutter between tiles, and
             * at a hundred tiles that is a lattice of background with pictures
             * in it. Telegram's shared-media grid leaves about two, so the
             * pictures touch and the grid reads as one sheet. The "wall"
             * layout keeps a little more, because its tiles are different
             * shapes and need the separation to stay legible.
             */
            anchors.margins: root.keepsShape ? 3 : 1
            radius: Appearance.rounding.small
            color: tap.pressed ? Appearance.colors.colLayer2Active : hover.hovered ? Appearance.colors.colLayer2Hover : Appearance.colors.colLayer2
            clip: true

            /*
             * SMOOTHING THE MINITHUMBNAIL WAS NEVER GOING TO BE ENOUGH.
             *
             * This drew the thirty-pixel blob itself, mipmapped and dimmed to
             * 0.75 to soften it — and it still read as a broken picture,
             * because bilinear filtering across a 6× magnification is hard
             * diagonal seams and the JPEG's own blocks are twenty pixels wide
             * by the time they land. The blob has to be BLURRED, at its own
             * size, before anything stretches it. Shot.qml does that, and
             * fades each better picture in over the last.
             */
            /*
             * THE LETTERBOX IS FILLED WITH THE PICTURE'S OWN BLUR.
             *
             * A GridView cell is one fixed shape, so "real shapes" means the
             * photograph is FITTED inside a 0.78 box — and a portrait
             * screenshot came out as a narrow strip between two bands of
             * colLayer2. Three portraits in a row and the wall read as grey
             * with pictures in it. The blob that stands in for the picture is
             * already decoded, and Shot already blurs it at forty pixels: with
             * a placeholder and no source, that IS the backdrop, at no cost.
             */
            Shot {
                anchors.fill: parent
                visible: root.keepsShape && !root.asList && !cell.mosaic
                opacity: 0.55
                fillMode: Image.PreserveAspectCrop
                mipmap: true
                placeholder: root.lens.miniOf(cell.lead)
            }

            Shot {
                id: picture

                visible: !cell.mosaic
                anchors.fill: parent
                anchors.rightMargin: root.asList ? parent.width - parent.height : 0
                // "Real shapes": the wall shows the whole picture, the grid
                // and the sheet fill their square — exactly the difference
                // those two layouts mean in the gallery.
                fillMode: root.keepsShape ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                mipmap: true
                placeholder: root.lens.miniOf(cell.lead)
                source: {
                    /*
                     * A DOWNLOADED FILE IS NOT ALWAYS A PICTURE.
                     *
                     * This handed whatever had been downloaded to an Image —
                     * and for a video that is an .mp4, which an Image cannot
                     * decode: `Error decoding: …/videos/tglwal.mp4: Unsupported
                     * image format`. So a clip showed its thumbnail happily
                     * until its file arrived and then went blank, which is why
                     * video "sometimes" failed to load: it depended entirely on
                     * whether the download had finished.
                     *
                     * Moving media keeps its thumbnail here; the player above
                     * is what shows the moving part.
                     */
                    const full = cell.moving ? "" : root.lens.heldFile(cell.lead);
                    return full.length > 0 && !Fmt.isVideoPath(full) ? full : root.lens.realThumbOf(cell.lead);
                }
            }

            FetchBadge {
                anchors.centerIn: parent
                scale: 0.8
                visible: shown && !cell.mosaic
                state: root.lens.fileStateOf(cell.lead)
                onRetried: root.lens.retryFile(cell.lead)
            }

            /*
             * AN ALBUM LOOKS LIKE AN ALBUM: every frame in the cell, sharing
             * it — see AlbumMosaic. It was the first frame with three
             * thumbnails painted over its bottom quarter.
             */
            AlbumMosaic {
                anchors.fill: parent
                visible: cell.mosaic
                lens: root.lens
                box: true
                // The cell's own keep button is for the album's lead.
                showKeep: false
                items: cell.mosaic ? cell.group.items : []
                onContextRequested: (message, x, y) => root.contextRequested(message, x, y)
            }

            Rectangle {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.topMargin: 6
                // Out from under the keep button, which claims this same corner
                // the moment the pointer enters the cell: an album's count was
                // drawn underneath a 28px circle.
                anchors.rightMargin: keep.visible ? keep.width + 10 : 6
                // A mosaic already shows its frames; the count is for list rows.
                visible: cell.album && !cell.mosaic
                width: countLabel.implicitWidth + 14
                height: 20
                radius: 10
                color: "#cc000000"

                RowLayout {
                    anchors.centerIn: parent
                    spacing: 3

                    MaterialSymbol {
                        text: "collections"
                        iconSize: 12
                        color: "white"
                    }

                    StyledText {
                        id: countLabel

                        text: String(cell.frames)
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: "white"
                    }

                }

            }

            // What it is, when the cell is a row rather than a square.
            Column {
                anchors.left: parent.left
                anchors.leftMargin: parent.height + 10
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                visible: root.asList
                spacing: 1

                StyledText {
                    width: parent.width
                    elide: Text.ElideRight
                    text: Fmt.mediaLabel(cell.media)
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colOnLayer1
                }

                StyledText {
                    width: parent.width
                    elide: Text.ElideRight
                    text: {
                        const bits = [];
                        if (cell.lead.senderName)
                            bits.push(String(cell.lead.senderName));

                        bits.push(Fmt.when(cell.lead.date));
                        if (cell.media && cell.media.size > 0)
                            bits.push(Fmt.size(cell.media.size));

                        return bits.join("  ·  ");
                    }
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: Appearance.colors.colSubtext
                }

            }

            // A file with no picture of its own still has a row: its kind and
            // its name, which is the whole of what a document is here.
            Column {
                anchors.centerIn: parent
                spacing: 4
                visible: !Fmt.isDrawable(cell.media)

                MaterialSymbol {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Fmt.mediaIcon(cell.media)
                    iconSize: 28
                    color: Appearance.colors.colOnLayer2
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: cell.width - 24
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideMiddle
                    text: Fmt.mediaLabel(cell.media)
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: Appearance.colors.colSubtext
                }

            }

            HoverHandler {
                id: hover

                cursorShape: Qt.PointingHandCursor
            }

            /*
             * A wall plays ONE clip: the one under the pointer.
             *
             * A grid of thirty cells all moving is a grid nobody can read, and
             * thirty decoders is not a wall, it is a load test. Hovering is
             * the ask, and it costs one player.
             */
            Loader {
                anchors.fill: parent
                active: hover.hovered && cell.moving && cell.playing.length > 0 && !cell.mosaic
                visible: active

                sourceComponent: Item {
                    Component.onCompleted: root.lens.playerOpened()
                    Component.onDestruction: root.lens.playerClosed()

                    VideoOutput {
                        id: output

                        anchors.fill: parent
                        fillMode: VideoOutput.PreserveAspectCrop
                    }

                    MediaPlayer {
                        source: cell.playing
                        videoOutput: output
                        loops: MediaPlayer.Infinite
                        Component.onCompleted: play()
                    }

                }

            }

            // A mosaic's frames open themselves.
            TapHandler {
                id: tap

                enabled: !cell.mosaic
                gesturePolicy: TapHandler.ReleaseWithinBounds
                onTapped: root.lens.openViewer(cell.lead)
            }

            TapHandler {
                enabled: !cell.mosaic
                acceptedButtons: Qt.RightButton
                gesturePolicy: TapHandler.ReleaseWithinBounds
                onSingleTapped: (eventPoint) => {
                    return root.contextRequested(cell.lead, eventPoint.scenePosition.x, eventPoint.scenePosition.y);
                }
            }

            Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.margins: 6
                height: 18
                width: label.implicitWidth + 16
                radius: 9
                visible: cell.moving && !cell.mosaic
                color: Appearance.colors.colLayer0Base
                opacity: 0.85

                Row {
                    id: label

                    anchors.centerIn: parent
                    spacing: 3

                    MaterialSymbol {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "play_arrow"
                        iconSize: 13
                        color: Appearance.colors.colOnLayer0
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: text.length > 0
                        text: cell.media ? Fmt.duration(cell.media.duration) : ""
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: Appearance.colors.colOnLayer0
                    }

                }

            }

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 20
                visible: hover.hovered
                color: Appearance.colors.colLayer0Base
                opacity: 0.9

                StyledText {
                    anchors.fill: parent
                    anchors.leftMargin: 6
                    anchors.rightMargin: 6
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    text: `${cell.lead.senderName || ""} · ${Fmt.when(cell.lead.date)}`
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: Appearance.colors.colOnLayer0
                }

            }

            Rectangle {
                id: keep

                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 6
                width: 28
                height: 28
                radius: 14
                visible: !root.lens.chatIsSecret && (cell.added || hover.hovered)
                color: cell.added ? Appearance.colors.colPrimaryContainer : Appearance.colors.colLayer0Base
                opacity: cell.added ? 0.95 : 0.85

                MaterialSymbol {
                    anchors.centerIn: parent
                    text: cell.added ? "check" : "add_photo_alternate"
                    iconSize: 16
                    color: cell.added ? Appearance.colors.colOnPrimaryContainer : Appearance.colors.colOnLayer0
                }

                HoverHandler {
                    id: keepHover

                    cursorShape: Qt.PointingHandCursor
                }

                TapHandler {
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: root.lens.take(cell.lead, null)
                }

                StyledToolTip {
                    visible: keepHover.hovered
                    text: cell.added ? "In your catalogue" : "Keep it in quarry"
                }

            }

            Behavior on color {
                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(cell)
            }

        }

    }

    // The page that is still coming, said at the bottom rather than as a
    // spinner over the pictures already there.
    footer: Item {
        width: root.width
        height: root.lens.loadingMedia ? 56 : 0

        // Appearing instantly shoved the last row up by 56 pixels in the
        // middle of the very flick that asked for the page.
        Behavior on height {
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(root)
        }

        LoadingIndicator {
            anchors.centerIn: parent
            visible: root.lens.loadingMedia
        }

    }

}
