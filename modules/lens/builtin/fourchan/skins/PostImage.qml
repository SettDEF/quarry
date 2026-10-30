import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick
import QtMultimedia
import QtQuick.Effects
import "../post.js" as Post

/*
 * ONE POST'S FILE: thumbnail, expanded, and the way into the catalogue.
 *
 * Clicking the thumbnail expands it in place, which is how the site itself
 * behaves and the reason threads are readable at all — you do not lose your
 * place to look at a picture. A .webm expands into a player instead, streamed
 * from the file host rather than downloaded first.
 *
 * "Add to quarry" is here and nowhere else: it is an action on a picture, so it
 * lives on the picture.
 */
Item {
    id: root

    required property var lens
    required property var post
    /// Width available if this expands. Height is capped so a tall image never
    /// pushes the rest of the thread off the bottom of the world.
    property real availableWidth: 640
    property real maxExpandedHeight: 720
    property int thumbLimit: 180
    property bool expandable: true
    property bool showFileLine: true

    /// The skin owns the one post menu; a picture only says where it was asked
    /// for.
    signal contextRequested(var post, real sceneX, real sceneY)

    readonly property bool isVideo: root.lens.isVideo(root.post)
    readonly property bool added: root.lens.isAdded(root.post)
    readonly property bool adult: root.lens.boardAdult

    property bool expanded: false
    property bool revealed: false
    readonly property bool blurred: root.adult && Prefs.blurNsfw && !root.revealed && !hover.hovered

    readonly property real thumbW: Math.min(root.thumbLimit, root.post.tn_w || root.thumbLimit)
    readonly property real thumbH: root.post.tn_w > 0 ? root.thumbW * (root.post.tn_h / root.post.tn_w) : root.thumbLimit

    readonly property real fullScale: Math.min(1, root.availableWidth / Math.max(1, root.post.w), root.maxExpandedHeight / Math.max(1, root.post.h))
    readonly property real fullW: Math.round((root.post.w || 1) * root.fullScale)
    readonly property real fullH: Math.round((root.post.h || 1) * root.fullScale)

    // The file line is usually wider than a thumbnail; letting it set the
    // width is the difference between "flower.jpg · 1200×900 · 340 kB" and
    // "flo…0 kB".
    implicitWidth: Math.max(root.expanded ? root.fullW : root.thumbW, root.showFileLine ? fileLine.width : 0)
    implicitHeight: (root.expanded ? root.fullH : root.thumbH) + (root.showFileLine ? fileLine.height + 2 : 0)

    Behavior on implicitWidth {
        animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(root)
    }
    Behavior on implicitHeight {
        animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(root)
    }

    StyledText {
        id: fileLine
        visible: root.showFileLine
        height: visible ? implicitHeight : 0
        width: Math.min(root.availableWidth, implicitWidth)
        elide: Text.ElideMiddle
        font.pixelSize: Appearance.font.pixelSize.smallest
        color: Appearance.colors.colSubtext
        text: `${Post.plain(root.post.filename)}${root.post.ext} · ${root.post.w}×${root.post.h} · ${Post.size(root.post.fsize)}`
    }

    Rectangle {
        id: frame
        anchors.top: root.showFileLine ? fileLine.bottom : parent.top
        anchors.topMargin: root.showFileLine ? 2 : 0
        width: root.expanded ? root.fullW : root.thumbW
        height: root.expanded ? root.fullH : root.thumbH
        radius: Appearance.rounding.small
        color: Appearance.colors.colLayer2
        clip: true

        HoverHandler {
            id: hover
            cursorShape: root.expandable ? Qt.PointingHandCursor : Qt.ArrowCursor
        }
        /*
         * Three steps, each the obvious next one: covered → shown, thumbnail →
         * expanded in place, expanded → the file itself at full size. The
         * middle step is how the site reads a thread; the last one is what a
         * 4000px picture is actually for, and it was missing.
         */
        TapHandler {
            enabled: root.expandable
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: {
                if (root.blurred) {
                    root.revealed = true;
                    return;
                }
                if (!root.expanded)
                    root.expanded = true;
                else
                    root.lens.openViewer(root.post);
            }
        }

        TapHandler {
            acceptedButtons: Qt.RightButton
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onSingleTapped: eventPoint => root.contextRequested(root.post, eventPoint.scenePosition.x, eventPoint.scenePosition.y)
        }

        Image {
            id: picture
            anchors.fill: parent
            asynchronous: true
            cache: !root.expanded
            fillMode: Image.PreserveAspectFit
            source: root.lens.pictureFor(root.post, root.expanded && !root.isVideo)
            // Decoded at the size it is drawn, not the size of the file: a
            // 3024×4032 photograph shown 700px wide costs 48 MB of pixels to
            // hold at full size and looks identical.
            sourceSize.width: Math.round(frame.width)
            sourceSize.height: Math.round(frame.height)
            visible: !(root.expanded && root.isVideo)

            layer.enabled: root.blurred
            layer.effect: MultiEffect {
                blurEnabled: true
                blur: 1.0
                blurMax: 48
                autoPaddingEnabled: false
            }
        }

        // The player is built only once a video has actually been opened.
        Loader {
            anchors.fill: parent
            active: root.expanded && root.isVideo
            sourceComponent: Component {
                Item {
                    VideoOutput {
                        id: output
                        anchors.fill: parent
                        fillMode: VideoOutput.PreserveAspectFit
                    }
                    MediaPlayer {
                        id: player
                        // The daemon's copy: streaming from i.4cdn.org direct is
                        // what earned this lens a 429 in the first place.
                        source: root.lens.fullFor(root.post)
                        videoOutput: output
                        loops: MediaPlayer.Infinite
                        audioOutput: AudioOutput {
                            muted: !Prefs.videoSound
                            volume: Prefs.videoVolume
                        }
                        Component.onCompleted: play()
                    }
                    TapHandler {
                        gesturePolicy: TapHandler.ReleaseWithinBounds
                        onTapped: player.playbackState === MediaPlayer.PlayingState ? player.pause() : player.play()
                    }
                }
            }
        }

        // Covered, said quietly — the blur is already the message.
        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.margins: 6
            width: 22
            height: 22
            radius: 11
            color: Appearance.colors.colLayer0Base
            opacity: 0.82
            visible: root.blurred

            MaterialSymbol {
                anchors.centerIn: parent
                text: "visibility_off"
                iconSize: 14
                color: Appearance.colors.colOnLayer0
            }
        }

        Rectangle {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: 6
            width: 26
            height: 18
            radius: 9
            visible: root.isVideo && !root.expanded
            color: Appearance.colors.colLayer0Base
            opacity: 0.85

            MaterialSymbol {
                anchors.centerIn: parent
                text: "play_arrow"
                iconSize: 14
                color: Appearance.colors.colOnLayer0
            }
        }

        // Straight to full size from the thumbnail: the expanded step is for
        // reading the thread, not for looking at the picture.
        Rectangle {
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.margins: 6
            width: 28
            height: 28
            radius: 14
            visible: !root.blurred && (hover.hovered || fullHover.hovered)
            opacity: fullHover.hovered ? 1 : 0.8
            color: Appearance.colors.colLayer0Base

            MaterialSymbol {
                anchors.centerIn: parent
                text: root.isVideo ? "play_circle" : "open_in_full"
                iconSize: 17
                color: Appearance.colors.colOnLayer0
            }

            HoverHandler {
                id: fullHover
                cursorShape: Qt.PointingHandCursor
            }
            TapHandler {
                gesturePolicy: TapHandler.ReleaseWithinBounds
                onTapped: root.lens.openViewer(root.post)
            }
            StyledToolTip {
                visible: fullHover.hovered
                text: root.isVideo ? "Play it full size" : "Open it full size"
            }
        }

        // ── into the catalogue ───────────────────────────────────────────────
        Rectangle {
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 6
            width: 30
            height: 30
            radius: 15
            visible: root.added || hover.hovered || addHover.hovered
            opacity: root.added ? 0.95 : (addHover.hovered ? 1 : 0.8)
            color: root.added ? Appearance.colors.colPrimaryContainer : Appearance.colors.colLayer0Base

            Behavior on opacity {
                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(root)
            }

            MaterialSymbol {
                anchors.centerIn: parent
                text: root.added ? "check" : "add_photo_alternate"
                iconSize: 18
                color: root.added ? Appearance.colors.colOnPrimaryContainer : Appearance.colors.colOnLayer0
            }

            HoverHandler {
                id: addHover
                cursorShape: Qt.PointingHandCursor
            }
            TapHandler {
                gesturePolicy: TapHandler.ReleaseWithinBounds
                onTapped: root.lens.addImage(root.post, null)
            }
            StyledToolTip {
                visible: addHover.hovered
                text: root.added ? "In your catalogue" : "Add to quarry"
            }
        }
    }
}
