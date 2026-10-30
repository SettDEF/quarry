import QtQuick
import QtQuick.Effects

/*
 * A PICTURE ARRIVING, THE WAY TELEGRAM DOES IT.
 *
 * Every picture in this lens comes in up to three steps: the minithumbnail
 * that travelled with the message (about thirty pixels of JPEG, free), the
 * real thumbnail (a few kilobytes, fetched), then the file itself. The steps
 * are the same as before — what was wrong was how they were DRAWN.
 *
 * A thirty-pixel JPEG stretched across three hundred is not a blur. It is
 * thirty pixels, magnified: hard diagonal seams where bilinear filtering
 * interpolates, and the JPEG's own 8×8 blocks blown up to twenty pixels each.
 * Telegram never shows that. It blurs the tiny image FIRST, while it is still
 * tiny, and only then stretches it — so what you see is a smooth field of
 * colour in roughly the right places, which is exactly what a placeholder
 * should be.
 *
 * That is what this does, and the trick is `layer.textureSize`: the blur runs
 * on a buffer forty pixels across, where a modest radius covers a huge part of
 * the picture and costs almost nothing, and the GPU's own filtering does the
 * stretching on the way out.
 *
 * The other half is not flinching. Each step CROSS-FADES into the last one
 * that loaded, so a picture never flashes back to its smudge on the way to
 * being sharp — which is what a plain `source:` swap does, because an Image
 * whose source changes is an Image with nothing in it until the new one
 * decodes.
 */
Item {
    id: shot

    /// The minithumbnail: a `data:` URL that came with the message, or "".
    property string placeholder: ""
    /// The best picture available right now — thumbnail, then file.
    property string source: ""
    /// A clip's file is not a picture. A clip sent as a document reached here
    /// as its .mp4 and drew "Unsupported image format" over its own poster.
    readonly property string _picture: /\.(mp4|webm|mkv|mov|m4v|avi|ogv)(\?|$)/i.test(shot.source) ? "" : shot.source
    property int fillMode: Image.PreserveAspectCrop
    /// Set for pictures drawn much smaller than they are (wall tiles).
    property bool mipmap: false
    /// How long the real picture takes to replace what is under it.
    property int fade: 200
    readonly property bool loaded: real.status === Image.Ready
    readonly property int status: real.status
    /// The last source that actually decoded, kept so the NEXT one has
    /// something to fade up from instead of the blur.
    property string _held: ""
    /// The blur buffer: the item's own shape, forty pixels on its long edge.
    readonly property size _buffer: {
        const w = Math.max(1, shot.width);
        const h = Math.max(1, shot.height);
        const scale = 40 / Math.max(w, h);
        return Qt.size(Math.max(8, Math.round(w * scale)), Math.max(8, Math.round(h * scale)));
    }

    clip: true

    // ── step one: the smudge, blurred while it is still small ────────────────
    Item {
        id: stage

        anchors.fill: parent
        visible: shot.placeholder.length > 0 && real.opacity < 0.99 && cover.opacity < 0.99
        /*
         * The blur happens HERE, on a buffer forty pixels across — and the
         * buffer is a FIXED size, not a fraction of the item. That is what
         * makes a tile in the wall and a photograph filling the screen look
         * like the same effect: blur is measured in pixels, so a fraction
         * would be a soft wash on a 120px tile and a barely-there smear on a
         * 1200px one. Forty is also about what the minithumbnail actually
         * contains, so nothing is blurred that was never there.
         */
        layer.enabled: true
        layer.smooth: true
        layer.textureSize: shot._buffer

        Image {
            anchors.fill: parent
            // Drawn past the edges so the rim of the buffer is picture rather
            // than the picture's own boundary — a blur samples outwards, and
            // at an edge there is nothing out there to sample.
            anchors.margins: shot.fillMode === Image.PreserveAspectCrop ? -Math.round(Math.max(1, Math.max(stage.width, stage.height) * 0.06)) : 0
            source: shot.placeholder
            fillMode: shot.fillMode
            smooth: true
            asynchronous: true
            // Left at its natural thirty pixels on purpose: decoding it at the
            // cell's size would magnify the blocks before anything blurs them.
            sourceSize.width: 0
            sourceSize.height: 0
        }

        layer.effect: MultiEffect {
            blurEnabled: true
            blur: 1
            blurMax: 64
            // No padding: the blur clamps at the edges instead of fading into
            // transparency, so a picture does not arrive inside a dark frame.
            autoPaddingEnabled: false
        }

    }

    // ── step two: whatever loaded last, holding the place ────────────────────
    Image {
        id: cover

        anchors.fill: parent
        asynchronous: true
        smooth: true
        mipmap: shot.mipmap
        fillMode: shot.fillMode
        source: shot._held
        visible: shot._held.length > 0
        opacity: source.toString().length > 0 && status === Image.Ready ? 1 : 0
        sourceSize.width: Math.round(shot.width)
        sourceSize.height: Math.round(shot.height)

        Behavior on opacity {
            NumberAnimation {
                duration: shot.fade
                easing.type: Easing.OutCubic
            }

        }

    }

    // ── step three: the real thing, fading up over both ──────────────────────
    Image {
        id: real

        anchors.fill: parent
        asynchronous: true
        smooth: true
        mipmap: shot.mipmap
        fillMode: shot.fillMode
        source: shot._picture
        opacity: status === Image.Ready ? 1 : 0
        sourceSize.width: Math.round(shot.width)
        sourceSize.height: Math.round(shot.height)
        onStatusChanged: {
            // Remember it only once it is on screen: a source that never
            // decoded is not something to fall back to.
            if (status === Image.Ready)
                shot._held = real.source.toString();

        }

        Behavior on opacity {
            NumberAnimation {
                duration: shot.fade
                easing.type: Easing.OutCubic
            }

        }

    }

}
