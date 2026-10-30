import "../fmt.js" as Fmt
import QtQuick
import qs.modules.common
import qs.modules.widgets

/*
 * AN ALBUM, DRAWN AS ONE THING.
 *
 * Several pictures sent in one act, laid out the way Telegram lays them out:
 * every frame visible, touching, in the order they were sent. Two shapes:
 *
 *   flow — a bubble in a conversation: the width is given and rows of frames
 *          are justified to it by their own shapes, so the height follows.
 *   box  — a wall cell: width and height are both given, so the frames share
 *          the box (two halves; one large and two; a 2×2 with "+N").
 *
 * The wall used to show the first frame with a strip of three thumbnails
 * painted over its bottom quarter, and the conversation drew every frame as a
 * bubble of its own — eight photos sent together read as eight messages.
 */
Item {
    id: root

    required property var lens
    /// The album's messages, oldest first.
    property var items: []
    /// `true` sizes to a fixed box (wall); `false` flows to the width (chat).
    property bool box: false
    /// Ask for full files rather than thumbnails (a conversation on screen).
    property bool wantsFull: false
    property bool showKeep: true
    readonly property int gap: 2

    signal contextRequested(var message, real sceneX, real sceneY)

    // Shapes clamped, so a panorama or a metre-tall meme cannot become a sliver.
    function _aspect(message) {
        const m = message && message.media;
        const w = m ? Number(m.width || 0) : 0;
        const h = m ? Number(m.height || 0) : 0;
        return w > 0 && h > 0 ? Math.max(0.6, Math.min(1.8, w / h)) : 1;
    }

    // Frames per row: threes, with twos first to take up the remainder.
    function _rows(n) {
        if (n <= 2)
            return [n];
        if (n === 3)
            return root._aspect(root.items[0]) >= 1.2 ? [1, 2] : [3];
        const rows = Math.ceil(n / 3);
        const out = [];
        let short = rows * 3 - n;
        for (let r = 0; r < rows; r++) {
            out.push(short > 0 ? 2 : 3);
            short--;
        }
        return out;
    }

    readonly property var tiles: {
        const W = root.width;
        const n = root.items.length;
        const g = root.gap;
        if (W <= 0 || n === 0)
            return [];
        const out = [];
        if (root.box) {
            const H = root.height;
            const wide = W >= H;
            const put = (i, x, y, w, h) => out.push({ "i": i, "x": x, "y": y, "w": w, "h": h });
            if (n === 1) {
                put(0, 0, 0, W, H);
            } else if (n === 2) {
                if (wide) { put(0, 0, 0, (W - g) / 2, H); put(1, (W + g) / 2, 0, (W - g) / 2, H); }
                else { put(0, 0, 0, W, (H - g) / 2); put(1, 0, (H + g) / 2, W, (H - g) / 2); }
            } else if (n === 3) {
                if (wide) {
                    const big = Math.round((W - g) * 0.6);
                    put(0, 0, 0, big, H);
                    put(1, big + g, 0, W - big - g, (H - g) / 2);
                    put(2, big + g, (H + g) / 2, W - big - g, (H - g) / 2);
                } else {
                    const big = Math.round((H - g) * 0.6);
                    put(0, 0, 0, W, big);
                    put(1, 0, big + g, (W - g) / 2, H - big - g);
                    put(2, (W + g) / 2, big + g, (W - g) / 2, H - big - g);
                }
            } else {
                const w = (W - g) / 2, h = (H - g) / 2;
                put(0, 0, 0, w, h); put(1, w + g, 0, w, h);
                put(2, 0, h + g, w, h); put(3, w + g, h + g, w, h);
            }
            return out;
        }
        // Flow: each row as tall as its frames' shapes allow at this width.
        let y = 0, at = 0;
        for (const count of root._rows(n)) {
            const row = root.items.slice(at, at + count).map(root._aspect);
            const sum = row.reduce((a, b) => a + b, 0);
            const free = W - g * (count - 1);
            const h = Math.round(Math.max(80, Math.min(free / sum, W * 0.75)));
            // Widths scaled to fill the row exactly, whatever the clamp did.
            const raw = row.map(a => a * h);
            const scale = free / raw.reduce((a, b) => a + b, 0);
            let x = 0;
            raw.forEach((w, k) => {
                const ww = k === count - 1 ? W - x : Math.round(w * scale);
                out.push({ "i": at + k, "x": x, "y": y, "w": ww, "h": h });
                x += ww + g;
            });
            y += h + g;
            at += count;
        }
        return out;
    }

    implicitHeight: {
        let bottom = 0;
        for (const t of root.tiles)
            bottom = Math.max(bottom, t.y + t.h);
        return bottom;
    }

    Repeater {
        model: root.tiles

        delegate: Rectangle {
            id: tile

            required property var modelData
            readonly property var message: root.items[tile.modelData.i]
            readonly property var media: tile.message ? tile.message.media || null : null
            readonly property bool moving: Fmt.isMoving(tile.media)
            readonly property bool added: root.lens.isAdded(tile.message)
            /// A box shows four; the fourth says how many more are behind it.
            readonly property int more: root.box && tile.modelData.i === 3 ? root.items.length - 4 : 0

            x: tile.modelData.x
            y: tile.modelData.y
            width: tile.modelData.w
            height: tile.modelData.h
            radius: Appearance.rounding.small
            color: Appearance.colors.colLayer2
            clip: true

            Shot {
                anchors.fill: parent
                fillMode: Image.PreserveAspectCrop
                mipmap: true
                placeholder: root.lens.miniOf(tile.message)
                source: {
                    if (tile.moving)
                        return root.lens.realThumbOf(tile.message);
                    const full = root.wantsFull ? root.lens.wantFull(tile.message) : root.lens.heldFile(tile.message);
                    return full.length > 0 && !Fmt.isVideoPath(full) ? full : root.lens.realThumbOf(tile.message);
                }
            }

            FetchBadge {
                anchors.centerIn: parent
                scale: 0.7
                state: root.lens.fileStateOf(tile.message)
                onRetried: root.lens.retryFile(tile.message)
            }

            Rectangle {
                anchors.centerIn: parent
                width: 34
                height: 34
                radius: 17
                visible: tile.moving && tile.more <= 0
                color: Appearance.colors.colLayer0Base
                opacity: 0.85

                MaterialSymbol {
                    anchors.centerIn: parent
                    text: "play_arrow"
                    iconSize: 20
                    color: Appearance.colors.colOnLayer0
                }
            }

            Rectangle {
                anchors.fill: parent
                visible: tile.more > 0
                color: "#99000000"

                StyledText {
                    anchors.centerIn: parent
                    text: `+${tile.more + 1}`
                    font.pixelSize: Appearance.font.pixelSize.huge
                    font.weight: Font.DemiBold
                    color: "white"
                }
            }

            HoverHandler {
                id: hover

                cursorShape: Qt.PointingHandCursor
            }

            TapHandler {
                gesturePolicy: TapHandler.ReleaseWithinBounds
                onTapped: root.lens.openViewer(tile.message)
            }

            TapHandler {
                acceptedButtons: Qt.RightButton
                gesturePolicy: TapHandler.ReleaseWithinBounds
                onSingleTapped: eventPoint => root.contextRequested(tile.message, eventPoint.scenePosition.x, eventPoint.scenePosition.y)
            }

            Rectangle {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 5
                width: 26
                height: 26
                radius: 13
                visible: root.showKeep && !root.lens.chatIsSecret && tile.more <= 0 && (tile.added || hover.hovered) && tile.width >= 60
                color: tile.added ? Appearance.colors.colPrimaryContainer : Appearance.colors.colLayer0Base
                opacity: 0.9

                MaterialSymbol {
                    anchors.centerIn: parent
                    text: tile.added ? "check" : "add_photo_alternate"
                    iconSize: 15
                    color: tile.added ? Appearance.colors.colOnPrimaryContainer : Appearance.colors.colOnLayer0
                }

                TapHandler {
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: root.lens.take(tile.message, null)
                }
            }
        }
    }
}
