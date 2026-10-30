import qs.modules.common
import qs.modules.widgets
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../post.js" as Post

/*
 * ONE THREAD, READ RATHER THAN SCRAPED.
 *
 * Posts in order, each with its text, its greentext, its quotes and its
 * picture. Quote links go to the post they name, and every post shows who
 * answered it — a thread is a conversation, and a list of pictures with the
 * replies stripped out is not the same object.
 */
ListView {
    id: root

    required property var lens
    signal contextRequested(var post, real sceneX, real sceneY)

    /// The palette the comment translation writes into its CSS. Greentext is
    /// the one literal colour in this skin: it is the site's own convention and
    /// a role-coloured "greentext" that is not green says nothing.
    readonly property var richColors: ({
            "link": Post.hex(Appearance.colors.colPrimary),
            "quote": "#789922",
            "dim": Post.hex(Appearance.colors.colOnLayer1Inactive),
            "code": Post.hex(Appearance.colors.colSecondary),
            "spoiler": Post.hex(Appearance.colors.colOnLayer1),
            "text": Post.hex(Appearance.colors.colOnLayer1)
        })

    model: root.lens.visiblePosts
    spacing: 8
    topMargin: 12
    bottomMargin: 24
    leftMargin: 14
    rightMargin: 14
    clip: true
    cacheBuffer: 1200
    boundsBehavior: Flickable.StopAtBounds

    ScrollBar.vertical: StyledScrollBar {
        view: root
    }

    // A quote link asked to go somewhere; find it and put it on screen.
    Connections {
        target: root.lens
        function onFocusPostChanged() {
            const wanted = root.lens.focusPost;
            if (!(wanted > 0))
                return;
            for (let i = 0; i < root.lens.posts.length; i++) {
                if (root.lens.posts[i].no === wanted) {
                    root.positionViewAtIndex(i, ListView.Center);
                    return;
                }
            }
        }
    }

    delegate: Rectangle {
        id: card
        required property var modelData
        required property int index

        readonly property bool isOp: card.index === 0
        readonly property var replies: root.lens.backlinks[card.modelData.no] || []
        readonly property bool focused: root.lens.focusPost === card.modelData.no

        width: root.width - root.leftMargin - root.rightMargin
        implicitHeight: body.implicitHeight + 20
        height: implicitHeight
        radius: Appearance.rounding.normal
        color: card.focused ? Appearance.colors.colSecondaryContainer : card.isOp ? Appearance.colors.colLayer2 : Appearance.colors.colLayer1

        Behavior on color {
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(card)
        }

        // The whole post, not only its picture: copying a link, going to the
        // site and hiding are things you do to a post.
        TapHandler {
            acceptedButtons: Qt.RightButton
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onSingleTapped: eventPoint => root.contextRequested(card.modelData, eventPoint.scenePosition.x, eventPoint.scenePosition.y)
        }

        ColumnLayout {
            id: body
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 10
            spacing: 6

            // ── who, when, and the post's own number ─────────────────────────
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                StyledText {
                    text: Post.plain(card.modelData.sub)
                    visible: text.length > 0
                    font.pixelSize: Appearance.font.pixelSize.small
                    font.weight: Font.DemiBold
                    color: Appearance.colors.colPrimary
                }
                StyledText {
                    text: Post.plain(card.modelData.name) || "Anonymous"
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    font.weight: Font.DemiBold
                    color: Appearance.colors.colOnLayer1
                }
                StyledText {
                    text: `No.${card.modelData.no}`
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: Appearance.colors.colSubtext
                }
                StyledText {
                    text: Post.age(card.modelData.time)
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: Appearance.colors.colSubtext
                }
                Item {
                    Layout.fillWidth: true
                }
                // Who answered this. The site puts these here and they are how
                // a thread stays followable past twenty posts.
                Repeater {
                    model: card.replies.slice(0, 8)

                    delegate: StyledText {
                        required property var modelData
                        text: `>>${modelData}`
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: Appearance.colors.colPrimary

                        HoverHandler {
                            id: backHover
                            cursorShape: Qt.PointingHandCursor
                        }
                        TapHandler {
                            gesturePolicy: TapHandler.ReleaseWithinBounds
                            onTapped: root.lens.goToPost(modelData)
                        }
                    }
                }
                StyledText {
                    visible: card.replies.length > 8
                    text: `+${card.replies.length - 8}`
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: Appearance.colors.colSubtext
                }
            }

            // A post with no file builds nothing at all.
            Loader {
                active: root.lens.hasImage(card.modelData)
                visible: active
                sourceComponent: PostImage {
                    lens: root.lens
                    post: card.modelData
                    availableWidth: card.width - 20
                    maxExpandedHeight: root.height - 80
                    onContextRequested: (post, x, y) => root.contextRequested(post, x, y)
                }
            }

            // ── the words ────────────────────────────────────────────────────
            Text {
                Layout.fillWidth: true
                visible: text.length > 0
                textFormat: Text.RichText
                wrapMode: Text.Wrap
                font.family: Appearance.font.family.reading
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colOnLayer1
                text: Post.toRich(card.modelData.com, root.richColors, root.lens.spoilersShown)
                onLinkActivated: link => {
                    if (link.indexOf("post:") === 0)
                        root.lens.goToPost(parseInt(link.slice(5), 10));
                }

                HoverHandler {
                    cursorShape: parent.hoveredLink.length > 0 ? Qt.PointingHandCursor : Qt.IBeamCursor
                }
            }
        }
    }

    // Nothing to read, said rather than left blank.
    StyledText {
        anchors.centerIn: parent
        visible: root.count === 0 && !root.lens.fetching
        text: root.lens.errorText.length > 0 ? root.lens.errorText : "Nothing here."
        color: Appearance.colors.colSubtext
    }
}
