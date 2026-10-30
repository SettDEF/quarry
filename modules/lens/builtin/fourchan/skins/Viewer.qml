import qs.modules.common
import qs.modules.widgets
import QtQuick
import QtMultimedia
import QtQuick.Effects
import "../post.js" as Post

/*
 * ONE FILE, FULL SIZE, OVER THE WHOLE LENS.
 *
 * The thumbnail on a post is 250px of a picture that is often 4000, and a .webm
 * expanded inline is a stamp. This is the other half: the ORIGINAL file —
 * `<tim><ext>` off i.4cdn.org, fetched through the daemon like everything else
 * so the CDN is asked once and the file is kept — drawn to fill the view, with
 * the arrow keys walking the pictures on the screen you opened it from.
 *
 * Click toggles fit and 1:1, and at 1:1 the picture drags. A video plays,
 * loops, and takes its sound from the app's own preferences rather than
 * inventing a second set.
 */
Item {
    id: root

    required property var lens
    /// Raised when a row wants the post menu; the skin owns the one instance.
    signal contextRequested(var post, real sceneX, real sceneY)

    readonly property var post: root.lens.viewing
    readonly property bool isVideo: root.post ? root.lens.isVideo(root.post) : false
    readonly property string file: root.post ? root.lens.fullFor(root.post) : ""
    readonly property bool fetching: root.post ? root.lens.isFetching(root.post) : false
    readonly property real ratio: root.post && root.post.h > 0 ? root.post.w / root.post.h : 1

    /// The same promise the thumbnails make: a board the site does not call
    /// worksafe is covered until you say otherwise, full size included.
    property bool revealed: false
    readonly property bool blurred: root.lens.boardAdult && Prefs.blurNsfw && !root.revealed

    visible: root.post !== null

    // Nothing behind the viewer reacts, including the thread it is drawn over.
    MouseArea {
        id: sink
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onWheel: wheel => wheel.accepted = true
        onClicked: mouse => {
            if (mouse.button !== Qt.RightButton)
                return;
            const at = sink.mapToItem(null, mouse.x, mouse.y);
            root.contextRequested(root.post, at.x, at.y);
        }
    }

    Rectangle {
        anchors.fill: parent
        // Nearly opaque rather than opaque: the thread underneath is still
        // where you were, and a viewer that hides that reads as a new screen.
        color: Qt.rgba(Appearance.colors.colLayer0.r, Appearance.colors.colLayer0.g, Appearance.colors.colLayer0.b, 0.97)
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape) {
            root.lens.closeViewer();
        } else if (event.key === Qt.Key_Left) {
            root.lens.viewerStep(-1);
        } else if (event.key === Qt.Key_Right) {
            root.lens.viewerStep(1);
        } else if (event.key === Qt.Key_Space) {
            // On a clip, Space means what it means everywhere else.
            if (root.isVideo)
                return;
            root.lens.viewerStep(1);
        } else if (event.key === Qt.Key_A) {
            root.lens.addImage(root.post, null);
        } else if (event.key === Qt.Key_C) {
            root.lens.copyImageLink(root.post);
        } else {
            return;
        }
        event.accepted = true;
    }

    // ── the picture ──────────────────────────────────────────────────────────
    property bool oneToOne: false
    onPostChanged: {
        root.oneToOne = false;
        root.revealed = false;
        frame.contentX = 0;
        frame.contentY = 0;
        /*
         * FOCUS IS TAKEN AND GIVEN BACK.
         *
         * `focus: post !== null` took the keyboard from LensHost's surface on
         * open and merely RELEASED it on close — the surface's own binding
         * never re-asserts, so Escape stopped closing the lens for the rest of
         * the session after one picture had been opened.
         */
        if (root.post)
            root.forceActiveFocus();
        else if (root.parent)
            root.parent.forceActiveFocus();
    }

    Flickable {
        id: frame
        anchors.fill: parent
        anchors.topMargin: 52
        anchors.bottomMargin: 56
        contentWidth: Math.max(width, picture.width)
        contentHeight: Math.max(height, picture.height)
        interactive: root.oneToOne
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        readonly property real fitScale: {
            const w = frame.width / Math.max(1, root.post ? root.post.w : 1);
            const h = frame.height / Math.max(1, root.post ? root.post.h : 1);
            // Never blown up past its own pixels: an upscaled JPEG is not more
            // of the picture, it is the same picture with softer edges.
            return Math.min(1, Math.min(w, h));
        }
        readonly property real scale_: root.oneToOne ? 1 : frame.fitScale

        Item {
            id: picture
            width: Math.max(frame.width, Math.round((root.post ? root.post.w : 1) * frame.scale_))
            height: Math.max(frame.height, Math.round((root.post ? root.post.h : 1) * frame.scale_))

            Image {
                id: still
                anchors.centerIn: parent
                width: Math.round((root.post ? root.post.w : 1) * frame.scale_)
                height: Math.round((root.post ? root.post.h : 1) * frame.scale_)
                // A video still draws its poster while the file comes down —
                // an empty frame for the length of a 6 MB fetch reads as broken.
                visible: !root.isVideo || root.file.length === 0
                asynchronous: true
                // The thumbnail first so there is never a blank frame, then the
                // file itself the moment it lands.
                source: root.file.length > 0 ? root.file : (root.post ? root.lens.local(root.lens.thumbUrl(root.post)) : "")
                fillMode: Image.PreserveAspectFit
                smooth: true
                mipmap: !root.oneToOne
                // Decoded at the size it is drawn. At 1:1 that is the file's
                // own size, which is the whole point of 1:1.
                sourceSize.width: Math.round(width)
                sourceSize.height: Math.round(height)

                layer.enabled: root.blurred
                layer.effect: MultiEffect {
                    blurEnabled: true
                    blur: 1.0
                    blurMax: 64
                    autoPaddingEnabled: false
                }
            }

            Loader {
                anchors.centerIn: parent
                width: Math.round((root.post ? root.post.w : 1) * frame.scale_)
                height: Math.round((root.post ? root.post.h : 1) * frame.scale_)
                // A video is built only once its file is here: pointing a
                // player at the CDN is what got this lens rate-limited.
                active: root.isVideo && root.file.length > 0 && !root.blurred
                sourceComponent: Component {
                    Item {
                        VideoOutput {
                            id: output
                            anchors.fill: parent
                            fillMode: VideoOutput.PreserveAspectFit
                        }
                        MediaPlayer {
                            id: player
                            source: root.file
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
        }

        TapHandler {
            enabled: !root.isVideo || root.blurred
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: {
                if (root.blurred) {
                    root.revealed = true;
                    return;
                }
                root.oneToOne = !root.oneToOne;
            }
        }
    }

    LoadingIndicator {
        anchors.centerIn: parent
        // `running`, not `visible`: the widget hides itself, and overriding
        // `visible` leaves its animation turning for the life of the skin.
        running: root.fetching && root.file.length === 0
    }

    StyledText {
        anchors.centerIn: parent
        width: parent.width * 0.6
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        visible: root.post !== null && !root.fetching && root.file.length === 0
        text: "That file would not come down — it may have been pruned. Esc goes back."
        color: Appearance.colors.colSubtext
    }

    // ── chrome ───────────────────────────────────────────────────────────────
    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 52
        color: Appearance.colors.colLayer0Base

        Row {
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            IconButton {
                icon: "arrow_back"
                tooltip: "Back to the thread · Esc"
                onClicked: root.lens.closeViewer()
            }
        }

        Column {
            anchors.centerIn: parent
            spacing: -2

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.post ? root.lens.fileName(root.post) : ""
                font.pixelSize: Appearance.font.pixelSize.small
                font.weight: Font.DemiBold
                color: Appearance.colors.colOnLayer0
            }
            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: {
                    if (!root.post)
                        return "";
                    const size = `${root.post.w}×${root.post.h} · ${Post.size(root.post.fsize)}`;
                    if (root.file.length === 0)
                        return root.fetching ? `${size} · fetching the full file…` : `${size} · could not be fetched`;
                    return root.oneToOne ? `${size} · full size` : `${size} · fit`;
                }
                font.pixelSize: Appearance.font.pixelSize.smallest
                color: Appearance.colors.colSubtext
            }
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4

            IconButton {
                icon: root.lens.isAdded(root.post) ? "check" : "add_photo_alternate"
                toggled: root.lens.isAdded(root.post)
                tooltip: root.lens.isAdded(root.post) ? "Already in your catalogue" : "Take it into quarry · A"
                onClicked: root.lens.addImage(root.post, null)
            }
            IconButton {
                icon: "more_vert"
                tooltip: "Everything else"
                onClicked: {
                    const at = mapToItem(null, width / 2, height);
                    root.contextRequested(root.post, at.x, at.y);
                }
            }
            IconButton {
                icon: "close"
                tooltip: "Close · Esc"
                onClicked: root.lens.closeViewer()
            }
        }
    }

    // ── where you are in the thread's pictures ───────────────────────────────
    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 56
        color: Appearance.colors.colLayer0Base

        Row {
            anchors.centerIn: parent
            spacing: 10

            IconButton {
                icon: "chevron_left"
                enabled: root.lens.viewerIndex > 0
                tooltip: "Previous picture · ←"
                onClicked: root.lens.viewerStep(-1)
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: root.lens.viewerIndex >= 0 ? `${root.lens.viewerIndex + 1} of ${root.lens.viewerList.length}` : ""
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colSubtext
            }
            IconButton {
                icon: "chevron_right"
                enabled: root.lens.viewerIndex >= 0 && root.lens.viewerIndex < root.lens.viewerList.length - 1
                tooltip: "Next picture · →"
                onClicked: root.lens.viewerStep(1)
            }
        }
    }
}
