import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtMultimedia
import "../thread.js" as Fmt
import Quickshell
import qs.modules.common
import qs.modules.widgets

/*
 * A SUBREDDIT AS A WALL.
 *
 * The card column is right for a conversation and wrong for a pile of
 * pictures — and a picture subreddit is a pile of pictures. r/wallpapers now
 * hands over 195 of them a page (the daemon reads galleries as of today, which
 * roughly doubled what a page yields), and scrolling that one card at a time
 * is not reading, it is queuing.
 *
 * Four shapes, the gallery's own, chosen per subreddit and remembered:
 *
 *   wall     real shapes — a picture keeps its aspect
 *   grid     even tiles
 *   sheet    a contact sheet, hundreds at a time
 *   compact  the facts as rows, for when the title is the point
 *
 * The thumbnails are Reddit's own previews, which are already the right size;
 * nothing here fetches a full picture to draw a tile.
 */
Item {
    id: root

    required property var lens
    readonly property bool asList: root.lens.layout === "compact"
    readonly property bool keepsShape: root.lens.keepsShape
    readonly property int columns: root.asList ? 1 : Math.max(2, Math.floor((root.width - 12) / Math.max(90, root.lens.layoutCell)))

    /// Reddit's preview URLs are HTML-escaped in the JSON, and a gallery's
    /// pictures live somewhere else entirely — one place that knows both.
    function pictureOf(post) {
        if (!post)
            return "";

        const unescape = (u) => {
            return String(u || "").replace(/&amp;/g, "&");
        };
        if (post.is_gallery && post.media_metadata && post.gallery_data) {
            const first = (post.gallery_data.items || [])[0];
            const entry = first ? post.media_metadata[first.media_id] : null;
            if (entry && entry.s)
                return unescape(entry.s.u || entry.s.gif || "");

        }
        const images = post.preview && post.preview.images ? post.preview.images : [];
        if (images.length > 0) {
            const sizes = images[0].resolutions || [];
            // The largest preview under 1080 — big enough for a wall tile,
            // small enough that a screen of them is not a download.
            for (let i = sizes.length - 1; i >= 0; i--) {
                if ((sizes[i].width || 0) <= 1080)
                    return unescape(sizes[i].url);

            }
            if (images[0].source)
                return unescape(images[0].source.url);

        }
        return unescape(post.url_overridden_by_dest || post.url || "");
    }

    /*
     * THE PICTURE'S OWN SHAPE.
     *
     * Reddit measures every preview, so a wall can be packed properly instead
     * of guessing. Falls back to 4:3 for the rare post with no measurement —
     * a wrong-but-plausible height reflows once when the picture lands, while
     * a zero height collapses the column.
     */
    function ratioOf(post) {
        const source = post && post.preview && post.preview.images && post.preview.images[0] ? post.preview.images[0].source : null;
        if (source && source.width > 0 && source.height > 0)
            return source.height / source.width;
        if (post && post.is_gallery && post.media_metadata && post.gallery_data) {
            const first = (post.gallery_data.items || [])[0];
            const entry = first ? post.media_metadata[first.media_id] : null;
            if (entry && entry.s && entry.s.x > 0 && entry.s.y > 0)
                return entry.s.y / entry.s.x;
        }
        return 0.75;
    }

    /*
     * MASONRY, NOT A GRID WITH GAPS IN IT.
     *
     * "Real shapes" was drawn as a GridView with uniform cells and the
     * picture fitted inside, which is not a wall — it is a grid with
     * letterboxing, and it looks exactly as wrong as it sounds: tall pictures
     * shrink into the middle of their cell, captions float away from what
     * they describe, and the rows line up while the pictures do not.
     *
     * A wall packs each picture at its own height into whichever column is
     * currently shortest. The packing is plain arithmetic over the shapes
     * above, redone when the width or the posts change, which at fifty to two
     * hundred posts costs nothing worth measuring.
     */
    readonly property var packed: {
        const count = Math.max(1, root.columns);
        const width = root.cellWidth;
        const columns = [];
        const heights = [];
        for (let i = 0; i < count; i++) {
            columns.push([]);
            heights.push(0);
        }
        for (const post of root.lens.pictures) {
            let shortest = 0;
            for (let i = 1; i < count; i++)
                if (heights[i] < heights[shortest])
                    shortest = i;
            columns[shortest].push(post);
            // The caption is part of the tile, so it is part of the packing.
            heights[shortest] += width * root.ratioOf(post) + 34;
        }
        return columns;
    }

    function framesOf(post) {
        return post && post.is_gallery && post.gallery_data ? (post.gallery_data.items || []).length : 0;
    }

    /*
     * THE TILE ARITHMETIC IS SHARED, NOT INHERITED.
     *
     * These were assignments when this file was a single GridView. It is now an
     * Item holding a masonry Flickable AND a grid, and `Item` has no cellWidth,
     * cellHeight, cacheBuffer, model or contentY — so those five lines were
     * load-time errors, which made the document unavailable and took both skins
     * down with it. The two inner views own their own model and paging; what
     * they share is the measurement, and that is what stays here.
     */
    readonly property real cellWidth: Math.floor((root.width - 12) / root.columns)
    readonly property real cellHeight: root.asList ? 76 : root.keepsShape ? Math.round(root.cellWidth * 0.75) : root.cellWidth
    readonly property int count: root.lens.pictures.length

    /// the view that scrolls right now — for autoscroll
    readonly property Flickable view: root.keepsShape ? masonry : grid

    clip: true

    StyledText {
        parent: root
        anchors.centerIn: parent
        visible: root.count === 0
        text: root.lens.loading ? "Asking reddit…" : "Nothing here with a picture in it."
        color: Appearance.colors.colSubtext
    }

    /*
     * REAL SHAPES — a column-packed wall, drawn only for `wall`.
     *
     * Every tile is its picture's own height, so nothing is letterboxed and a
     * caption sits under the thing it describes. See `packed` for how the
     * columns are filled.
     */
    Flickable {
        id: masonry

        anchors.fill: parent
        visible: root.keepsShape
        clip: true
        contentWidth: width
        contentHeight: walls.implicitHeight + 16
        boundsBehavior: Flickable.StopAtBounds

        onContentYChanged: {
            if (contentY + height > contentHeight - height)
                root.lens.more();
        }

        ScrollBar.vertical: StyledScrollBar {
            view: masonry
        }

        Row {
            id: walls

            width: parent.width
            spacing: 6
            padding: 6

            // the column count, not the columns: a new page must not rebuild
            // every tile (each column below is keyed by post and only grows)
            Repeater {
                model: root.packed.length

                delegate: Column {
                    id: wallColumn
                    required property int index

                    width: root.cellWidth
                    spacing: 6

                    Repeater {
                        model: ScriptModel { values: root.packed[wallColumn.index] ?? []; objectProp: "id" }

                        delegate: Rectangle {
                            id: brick

                            required property var modelData
                            readonly property int frames: root.framesOf(brick.modelData)

                            width: root.cellWidth
                            height: Math.round(root.cellWidth * root.ratioOf(brick.modelData)) + 30
                            radius: Appearance.rounding.small
                            clip: true
                            color: brickTap.pressed ? Appearance.colors.colLayer2Active : brickHover.hovered ? Appearance.colors.colLayer2Hover : Appearance.colors.colLayer2

                            Image {
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                height: Math.round(root.cellWidth * root.ratioOf(brick.modelData))
                                asynchronous: true
                                cache: true
                                smooth: true
                                fillMode: Image.PreserveAspectCrop
                                source: root.pictureOf(brick.modelData)

                                // a video or gif plays while the pointer is on it
                                RedditVideo {
                                    anchors.fill: parent
                                    visible: Fmt.videoUrl(brick.modelData).length > 0
                                    post: brick.modelData
                                    lens: root.lens
                                    mode: "hover"
                                    controls: false
                                    fillMode: VideoOutput.PreserveAspectCrop
                                }
                                sourceSize.width: Math.round(root.cellWidth * 1.5)
                                opacity: status === Image.Ready ? 1 : 0

                                Behavior on opacity {
                                    NumberAnimation {
                                        duration: 160
                                    }
                                }
                            }

                            Rectangle {
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.margins: 6
                                visible: brick.frames > 1
                                width: brickCount.implicitWidth + 16
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
                                        id: brickCount

                                        text: String(brick.frames)
                                        font.pixelSize: Appearance.font.pixelSize.smallest
                                        color: "white"
                                    }
                                }
                            }

                            // Under the picture, not over it: a caption on top
                            // of a photograph hides the part of it you were
                            // looking at.
                            StyledText {
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                anchors.margins: 7
                                elide: Text.ElideRight
                                text: brick.modelData.title || ""
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                color: Appearance.colors.colOnLayer2
                            }

                            HoverHandler {
                                id: brickHover

                                cursorShape: Qt.PointingHandCursor
                            }

                            TapHandler {
                                id: brickTap

                                gesturePolicy: TapHandler.ReleaseWithinBounds
                                onTapped: root.lens.openPost(brick.modelData)
                            }
                        }
                    }
                }
            }
        }
    }

    /*
     * EVEN TILES — the grid, the contact sheet and the compact rows, which
     * all want a uniform cell and differ only in how big it is.
     */
    GridView {
        id: grid

        anchors.fill: parent
        visible: !root.keepsShape
        clip: true
        cellWidth: root.cellWidth
        cellHeight: root.asList ? 76 : root.cellWidth
        cacheBuffer: 800
        model: ScriptModel { values: root.lens.pictures; objectProp: "id" }

        onContentYChanged: {
            if (contentY + height > contentHeight - height)
                root.lens.more();
        }

        ScrollBar.vertical: StyledScrollBar {
            view: grid
        }

        delegate: Item {
            id: cell

        required property var modelData
        readonly property int frames: root.framesOf(cell.modelData)

        width: root.cellWidth
        height: root.cellHeight

        Rectangle {
            anchors.fill: parent
            anchors.margins: root.keepsShape ? 3 : 2
            radius: Appearance.rounding.small
            clip: true
            color: tap.pressed ? Appearance.colors.colLayer2Active : hover.hovered ? Appearance.colors.colLayer2Hover : Appearance.colors.colLayer2

            Image {
                id: picture

                anchors.fill: parent
                anchors.rightMargin: root.asList ? parent.width - parent.height : 0
                asynchronous: true
                cache: true
                smooth: true
                mipmap: true
                fillMode: root.keepsShape ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                source: root.pictureOf(cell.modelData)

                RedditVideo {
                    anchors.fill: parent
                    visible: Fmt.videoUrl(cell.modelData).length > 0
                    post: cell.modelData
                    lens: root.lens
                    mode: "hover"
                    controls: false
                    fillMode: root.keepsShape ? VideoOutput.PreserveAspectFit : VideoOutput.PreserveAspectCrop
                }
                sourceSize.width: Math.round(parent.width * 1.5)
                opacity: status === Image.Ready ? 1 : 0

                Behavior on opacity {
                    NumberAnimation {
                        duration: 160
                    }

                }

            }

            // A gallery says how many it holds, the way an album does in the
            // Morse wall — "there are more of these behind it".
            Rectangle {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 6
                visible: cell.frames > 1 && !root.asList
                width: count.implicitWidth + 16
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
                        id: count

                        text: String(cell.frames)
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: "white"
                    }

                }

            }

            // The title, where there is room for it: over the picture in the
            // bigger layouts, beside it in a compact row, nowhere at all on a
            // contact sheet, which is the point of a contact sheet.
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: Math.min(52, parent.height * 0.4)
                visible: !root.asList && root.lens.layoutCell >= 200 && (hover.hovered || root.keepsShape)

                StyledText {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: 6
                    elide: Text.ElideRight
                    maximumLineCount: 2
                    wrapMode: Text.Wrap
                    text: cell.modelData.title || ""
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: "white"
                }

                gradient: Gradient {
                    GradientStop {
                        position: 0
                        color: "#00000000"
                    }

                    GradientStop {
                        position: 1
                        color: "#dd000000"
                    }

                }

            }

            RowLayout {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: parent.height + 10
                anchors.rightMargin: 10
                visible: root.asList
                spacing: 10

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: -1

                    StyledText {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        text: cell.modelData.title || ""
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: Appearance.colors.colOnLayer2
                    }

                    StyledText {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        text: {
                            const p = cell.modelData;
                            const bits = [`r/${p.subreddit || ""}`, `${p.score || 0} points`, `${p.num_comments || 0} comments`];
                            if (cell.frames > 1)
                                bits.push(`${cell.frames} pictures`);

                            return bits.join(" · ");
                        }
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: Appearance.colors.colSubtext
                    }

                }

            }

            HoverHandler {
                id: hover

                cursorShape: Qt.PointingHandCursor
            }

            TapHandler {
                id: tap

                gesturePolicy: TapHandler.ReleaseWithinBounds
                // Opening a picture opens its POST, not the file: the comments
                // are the half of reddit a gallery cannot show, and they are
                // why this lens exists at all.
                onTapped: root.lens.openPost(cell.modelData)
            }

        }

    }
    }
}
