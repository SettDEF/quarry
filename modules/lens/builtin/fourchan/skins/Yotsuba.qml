import qs.modules.lens
import qs.services
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtMultimedia
import "../post.js" as Post

/*
 * THE YOTSUBA SKIN — the board's own look, on purpose.
 *
 * EVERY COLOUR HERE IS A LITERAL, and that is the point of a skin rather than a
 * bug. The rest of quarry uses roles so it retints with the wallpaper; this
 * draws one specific site as that site draws itself, cream and maroon, posts as
 * rows rather than cards. A skin that had to use the app's palette could only
 * ever be the app with different padding.
 *
 * It shares no state with the default skin — both read the same lens, so
 * switching mid-thread lands on the same thread.
 */
LensSkin {
    id: root

    ground: "#FFFFEE"

    readonly property var lensRef: root.lens
    readonly property string bg: "#FFFFEE"
    readonly property string postBg: "#F0E0D6"
    readonly property string postBorder: "#D9BFB7"
    readonly property string link: "#34345C"
    readonly property string nameColor: "#117743"
    readonly property string subjectColor: "#CC1105"
    readonly property string textColor: "#800000"
    readonly property string bodyColor: "#000000"
    readonly property string face: "Arial"

    readonly property var richColors: ({
            "link": root.link,
            "quote": "#789922",
            "dim": "#707070",
            "code": "#000080",
            "spoiler": root.bodyColor,
            "text": root.bodyColor
        })

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── the board banner line ────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 46
            color: root.bg

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 10

                Text {
                    text: root.lensRef.canGoBack ? "[Back]" : "[Close]"
                    font.family: root.face
                    font.pixelSize: 13
                    color: root.link

                    /*

                     * A REAL TARGET, NOT A HANDLER ON A GLYPH.

                     *

                     * These were `TapHandler`s on bare `Text`, which is 13px tall and has

                     * no padding at all — and the surface behind the skin takes every

                     * button so nothing underneath a lens reacts, which is what the press

                     * landed on instead. A MouseArea with negative margins is both: an

                     * item that actually accepts the click, and a target you can hit.

                     */

                    MouseArea {

                        anchors.fill: parent

                        anchors.margins: -6

                        hoverEnabled: true

                        cursorShape: Qt.PointingHandCursor

                        onClicked: root.lensRef.canGoBack ? root.lensRef.back() : Lenses.close()

                    }
                }
                Text {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    text: root.lensRef.screenTitle
                    font.family: root.face
                    font.pixelSize: 22
                    font.bold: true
                    color: root.textColor
                }
                Text {
                    visible: root.lensRef.screen === "thread" || root.lensRef.screen === "images"
                    text: root.lensRef.bulkRunning ? `[Stop ${root.lensRef.bulkDone}/${root.lensRef.bulkTotal}]` : "[Add all images]"
                    font.family: root.face
                    font.pixelSize: 13
                    color: root.link

                    /*

                     * A REAL TARGET, NOT A HANDLER ON A GLYPH.

                     *

                     * These were `TapHandler`s on bare `Text`, which is 13px tall and has

                     * no padding at all — and the surface behind the skin takes every

                     * button so nothing underneath a lens reacts, which is what the press

                     * landed on instead. A MouseArea with negative margins is both: an

                     * item that actually accepts the click, and a target you can hit.

                     */

                    MouseArea {

                        anchors.fill: parent

                        anchors.margins: -6

                        hoverEnabled: true

                        cursorShape: Qt.PointingHandCursor

                        onClicked: root.lensRef.bulkRunning ? root.lensRef.cancelBulk() : root.lensRef.addThread()

                    }
                }
                Text {
                    text: "[Refresh]"
                    font.family: root.face
                    font.pixelSize: 13
                    color: root.link

                    /*

                     * A REAL TARGET, NOT A HANDLER ON A GLYPH.

                     *

                     * These were `TapHandler`s on bare `Text`, which is 13px tall and has

                     * no padding at all — and the surface behind the skin takes every

                     * button so nothing underneath a lens reacts, which is what the press

                     * landed on instead. A MouseArea with negative margins is both: an

                     * item that actually accepts the click, and a target you can hit.

                     */

                    MouseArea {

                        anchors.fill: parent

                        anchors.margins: -6

                        hoverEnabled: true

                        cursorShape: Qt.PointingHandCursor

                        onClicked: root.lensRef.refresh()

                    }
                }
                Repeater {
                    model: Lenses.skinsOf(root.lensRef.lensId)

                    delegate: Text {
                        required property var modelData
                        text: `[${modelData.name}]`
                        font.family: root.face
                        font.pixelSize: 13
                        font.bold: Lenses.skinOf(root.lensRef.lensId) === modelData.id
                        color: root.link

                        /*

                         * A REAL TARGET, NOT A HANDLER ON A GLYPH.

                         *

                         * These were `TapHandler`s on bare `Text`, which is 13px tall and has

                         * no padding at all — and the surface behind the skin takes every

                         * button so nothing underneath a lens reacts, which is what the press

                         * landed on instead. A MouseArea with negative margins is both: an

                         * item that actually accepts the click, and a target you can hit.

                         */

                        MouseArea {

                            anchors.fill: parent

                            anchors.margins: -6

                            hoverEnabled: true

                            cursorShape: Qt.PointingHandCursor

                            onClicked: Lenses.setSkin(root.lensRef.lensId, modelData.id)

                        }
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: root.postBorder
        }

        // ── whichever screen ─────────────────────────────────────────────────
        Flickable {
            id: scroller
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: stack.implicitHeight + 24
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            ScrollBar.vertical: ScrollBar {}

            Column {
                id: stack
                x: 10
                y: 8
                width: scroller.width - 20
                spacing: 6

                // Boards: the site's own index line, one row of links.
                Flow {
                    width: parent.width
                    spacing: 8
                    visible: root.lensRef.screen === "boards"

                    Repeater {
                        model: root.lensRef.boards

                        delegate: Text {
                            required property var modelData
                            text: `[ /${modelData.board}/ ${modelData.title} ]`
                            font.family: root.face
                            font.pixelSize: 13
                            color: root.link

                            /*

                             * A REAL TARGET, NOT A HANDLER ON A GLYPH.

                             *

                             * These were `TapHandler`s on bare `Text`, which is 13px tall and has

                             * no padding at all — and the surface behind the skin takes every

                             * button so nothing underneath a lens reacts, which is what the press

                             * landed on instead. A MouseArea with negative margins is both: an

                             * item that actually accepts the click, and a target you can hit.

                             */

                            MouseArea {

                                anchors.fill: parent

                                anchors.margins: -6

                                hoverEnabled: true

                                cursorShape: Qt.PointingHandCursor

                                onClicked: root.lensRef.showCatalog(modelData.board)

                            }
                        }
                    }
                }

                Text {
                    visible: root.lensRef.screen === "boards"
                    text: "Boards are chosen in the Quarry skin."
                    font.family: root.face
                    font.pixelSize: 12
                    color: "#707070"
                }

                // Catalogue: OP thumbnails wrapped, the way the site's own
                // catalogue lays them out.
                Flow {
                    width: parent.width
                    spacing: 6
                    visible: root.lensRef.screen === "catalog"

                    Repeater {
                        model: root.lensRef.screen === "catalog" ? root.lensRef.visibleThreads : []

                        delegate: Column {
                            id: tile
                            required property var modelData
                            width: 180
                            spacing: 2

                            Image {
                                width: 180
                                height: 140
                                asynchronous: true
                                fillMode: Image.PreserveAspectCrop
                                source: root.lensRef.hasImage(tile.modelData) ? root.lensRef.pictureFor(tile.modelData, false) : ""

                                TapHandler {
                                    acceptedButtons: Qt.RightButton
                                    gesturePolicy: TapHandler.ReleaseWithinBounds
                                    onSingleTapped: eventPoint => postMenu.openFor(tile.modelData, eventPoint.scenePosition.x, eventPoint.scenePosition.y)
                                }
                                sourceSize.width: tile.modelData.tn_w || 250
                                sourceSize.height: tile.modelData.tn_h || 250

                                /*

                                 * A REAL TARGET, NOT A HANDLER ON A GLYPH.

                                 *

                                 * These were `TapHandler`s on bare `Text`, which is 13px tall and has

                                 * no padding at all — and the surface behind the skin takes every

                                 * button so nothing underneath a lens reacts, which is what the press

                                 * landed on instead. A MouseArea with negative margins is both: an

                                 * item that actually accepts the click, and a target you can hit.

                                 */

                                MouseArea {

                                    anchors.fill: parent

                                    anchors.margins: -6

                                    hoverEnabled: true

                                    cursorShape: Qt.PointingHandCursor

                                    onClicked: root.lensRef.showThread(tile.modelData.no, tile.modelData.sub || "")

                                }
                            }
                            Text {
                                width: 180
                                text: `R: ${tile.modelData.replies || 0} / I: ${tile.modelData.images || 0}`
                                font.family: root.face
                                font.pixelSize: 11
                                font.bold: true
                                color: root.bodyColor
                            }
                            Text {
                                width: 180
                                wrapMode: Text.Wrap
                                maximumLineCount: 4
                                elide: Text.ElideRight
                                text: Post.plain(tile.modelData.sub).length > 0 ? Post.plain(tile.modelData.sub) : Post.plain(tile.modelData.com)
                                font.family: root.face
                                font.pixelSize: 11
                                color: root.bodyColor
                            }
                        }
                    }
                }

                /*
                 * Thread: posts as rows on the board's own paper — and what
                 * you hid stays hidden, whichever skin hid it.
                 *
                 * The "images" screen is the same thread here: this skin
                 * already draws every file inline, so a separate wall would be
                 * the same page with the words taken out, and an empty page is
                 * what it did before.
                 */
                Repeater {
                    model: root.lensRef.screen === "thread" || root.lensRef.screen === "images" ? root.lensRef.visiblePosts : []

                    delegate: Rectangle {
                        id: reply
                        required property var modelData
                        required property int index

                        readonly property bool isOp: reply.index === 0
                        readonly property bool open: postState.expanded

                        width: stack.width
                        height: inner.implicitHeight + 12
                        color: reply.isOp ? "transparent" : root.postBg
                        border.width: reply.isOp ? 0 : 1
                        border.color: root.postBorder

                        QtObject {
                            id: postState
                            property bool expanded: false
                        }

                        Column {
                            id: inner
                            x: 6
                            y: 6
                            width: parent.width - 12
                            spacing: 3

                            Row {
                                spacing: 6

                                Text {
                                    visible: Post.plain(reply.modelData.sub).length > 0
                                    text: Post.plain(reply.modelData.sub)
                                    font.family: root.face
                                    font.pixelSize: 13
                                    font.bold: true
                                    color: root.subjectColor
                                }
                                Text {
                                    text: Post.plain(reply.modelData.name) || "Anonymous"
                                    font.family: root.face
                                    font.pixelSize: 13
                                    font.bold: true
                                    color: root.nameColor
                                }
                                Text {
                                    text: `No.${reply.modelData.no}`
                                    font.family: root.face
                                    font.pixelSize: 12
                                    color: root.bodyColor
                                }
                                Repeater {
                                    model: (root.lensRef.backlinks[reply.modelData.no] || []).slice(0, 8)

                                    delegate: Text {
                                        required property var modelData
                                        text: `>>${modelData}`
                                        font.family: root.face
                                        font.pixelSize: 12
                                        color: root.link

                                        /*

                                         * A REAL TARGET, NOT A HANDLER ON A GLYPH.

                                         *

                                         * These were `TapHandler`s on bare `Text`, which is 13px tall and has

                                         * no padding at all — and the surface behind the skin takes every

                                         * button so nothing underneath a lens reacts, which is what the press

                                         * landed on instead. A MouseArea with negative margins is both: an

                                         * item that actually accepts the click, and a target you can hit.

                                         */

                                        MouseArea {

                                            anchors.fill: parent

                                            anchors.margins: -6

                                            hoverEnabled: true

                                            cursorShape: Qt.PointingHandCursor

                                            onClicked: root.lensRef.goToPost(modelData)

                                        }
                                    }
                                }
                            }

                            // The file line, with the way into the catalogue
                            // where the site puts its own file links.
                            Row {
                                spacing: 6
                                visible: root.lensRef.hasImage(reply.modelData)

                                Text {
                                    text: `File: ${Post.plain(reply.modelData.filename)}${reply.modelData.ext} (${Post.size(reply.modelData.fsize)}, ${reply.modelData.w}x${reply.modelData.h})`
                                    font.family: root.face
                                    font.pixelSize: 12
                                    color: root.link
                                }
                                Text {
                                    text: root.lensRef.isAdded(reply.modelData) ? "[in quarry]" : "[add to quarry]"
                                    font.family: root.face
                                    font.pixelSize: 12
                                    font.bold: true
                                    color: root.lensRef.isAdded(reply.modelData) ? root.nameColor : root.link

                                    /*

                                     * A REAL TARGET, NOT A HANDLER ON A GLYPH.

                                     *

                                     * These were `TapHandler`s on bare `Text`, which is 13px tall and has

                                     * no padding at all — and the surface behind the skin takes every

                                     * button so nothing underneath a lens reacts, which is what the press

                                     * landed on instead. A MouseArea with negative margins is both: an

                                     * item that actually accepts the click, and a target you can hit.

                                     */

                                    MouseArea {

                                        anchors.fill: parent

                                        anchors.margins: -6

                                        hoverEnabled: true

                                        cursorShape: Qt.PointingHandCursor

                                        onClicked: root.lensRef.addImage(reply.modelData, null)

                                    }
                                }
                            }

                            Item {
                                visible: root.lensRef.hasImage(reply.modelData)
                                width: media.width
                                height: media.height

                                Item {
                                    id: media
                                    readonly property real scaleDown: Math.min(1, (inner.width) / Math.max(1, reply.modelData.w || 1), 700 / Math.max(1, reply.modelData.h || 1))
                                    width: reply.open ? Math.round((reply.modelData.w || 1) * scaleDown) : Math.min(180, reply.modelData.tn_w || 180)
                                    height: reply.open ? Math.round((reply.modelData.h || 1) * scaleDown) : (reply.modelData.tn_w > 0 ? Math.min(180, reply.modelData.tn_w) * (reply.modelData.tn_h / reply.modelData.tn_w) : 180)

                                    Image {
                                        anchors.fill: parent
                                        asynchronous: true
                                        fillMode: Image.PreserveAspectFit
                                        visible: !(reply.open && root.lensRef.isVideo(reply.modelData))
                                        source: root.lensRef.pictureFor(reply.modelData, reply.open && !root.lensRef.isVideo(reply.modelData))
                                        sourceSize.width: (reply.open ? reply.modelData.w : reply.modelData.tn_w) || 0
                                        sourceSize.height: (reply.open ? reply.modelData.h : reply.modelData.tn_h) || 0
                                    }

                                    Loader {
                                        anchors.fill: parent
                                        active: reply.open && root.lensRef.isVideo(reply.modelData)
                                        sourceComponent: Component {
                                            Item {
                                                VideoOutput {
                                                    id: out
                                                    anchors.fill: parent
                                                    fillMode: VideoOutput.PreserveAspectFit
                                                }
                                                MediaPlayer {
                                                    // The daemon's copy, not the CDN's: see Main.qml.
                                                    source: root.lensRef.fullFor(reply.modelData)
                                                    videoOutput: out
                                                    loops: MediaPlayer.Infinite
                                                    audioOutput: AudioOutput {
                                                        muted: true
                                                    }
                                                    Component.onCompleted: play()
                                                }
                                            }
                                        }
                                    }

                                    HoverHandler {
                                        cursorShape: Qt.PointingHandCursor
                                    }
                                    TapHandler {
                                        gesturePolicy: TapHandler.ReleaseWithinBounds
                                        // Expanded already: the next step is the
                                        // file itself, full size.
                                        onTapped: reply.open ? root.lensRef.openViewer(reply.modelData) : postState.expanded = true
                                    }
                                    TapHandler {
                                        acceptedButtons: Qt.RightButton
                                        gesturePolicy: TapHandler.ReleaseWithinBounds
                                        onSingleTapped: eventPoint => postMenu.openFor(reply.modelData, eventPoint.scenePosition.x, eventPoint.scenePosition.y)
                                    }
                                }
                            }

                            Text {
                                width: inner.width
                                visible: text.length > 0
                                textFormat: Text.RichText
                                wrapMode: Text.Wrap
                                font.family: root.face
                                font.pixelSize: 13
                                color: root.bodyColor
                                text: Post.toRich(reply.modelData.com, root.richColors, root.lensRef.spoilersShown)
                                onLinkActivated: link => {
                                    if (link.indexOf("post:") === 0)
                                        root.lensRef.goToPost(parseInt(link.slice(5), 10));
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // The same two as the default skin: this one draws the site's furniture,
    // not its own versions of these.
    PostMenu {
        id: postMenu
        lens: root.lensRef
    }

    Viewer {
        anchors.fill: parent
        z: 50
        lens: root.lensRef
        onContextRequested: (post, x, y) => postMenu.openFor(post, x, y)
    }
}
