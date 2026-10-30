import qs.modules.common
import Quickshell
import qs.modules.widgets
import QtQuick
import QtQuick.Layouts
import "../thread.js" as Thread

/*
 * A COLUMN OF POSTS, WRITTEN ONCE.
 *
 * Both skins show the same rows in the same order with the same behaviour; only
 * the colours and the corner radius differ, so those are parameters and the
 * rest is shared. A second copy of a list is a second place for "load the next
 * page near the bottom" to be subtly wrong.
 */
StyledListView {
    id: root

    required property var lens
    property color card: Appearance.colors.colLayer1
    property color ink: Appearance.colors.colOnLayer1
    property color dim: Appearance.colors.colSubtext
    property color accent: Appearance.colors.colPrimary
    property real cardRadius: 17

    clip: true
    spacing: 8
    // keyed by post: a new page adds rows, it does not rebuild the list
    model: ScriptModel { values: root.lens.posts; objectProp: "id" }

    // The next page is asked for before you reach the end; the lens refuses a
    // second ask while one is out, so this can be eager.
    onContentYChanged: {
        if (contentY + height > contentHeight - height)
            root.lens.more();
    }

    delegate: Rectangle {
        id: row
        required property var modelData
        width: root.width
        height: 96
        radius: root.cardRadius
        color: hover.hovered ? Appearance.colors.colLayer1Hover : root.card

        readonly property string thumb: Thread.thumbUrl(row.modelData)

        RowLayout {
            anchors.fill: parent
            anchors.margins: 10
            spacing: 12

            // The score, up the side, the way the site has always had it.
            ColumnLayout {
                Layout.preferredWidth: 46
                spacing: 0

                MaterialSymbol {
                    Layout.alignment: Qt.AlignHCenter
                    text: "arrow_upward"
                    iconSize: 16
                    color: root.accent
                }
                StyledText {
                    Layout.alignment: Qt.AlignHCenter
                    text: Thread.count(row.modelData.score)
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    font.weight: Font.DemiBold
                    color: root.ink
                }
            }

            Rectangle {
                Layout.preferredWidth: 104
                Layout.fillHeight: true
                radius: 8
                clip: true
                color: "#1a1a1a"
                visible: row.thumb.length > 0

                Image {
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    source: row.thumb
                }

                // A picture nobody has agreed to see yet — the app's own rule,
                // applied to a lens that fetches its own images.
                Rectangle {
                    anchors.fill: parent
                    visible: row.modelData.over_18 === true && Prefs.blurNsfw && !hover.hovered
                    color: "#cc000000"
                    StyledText {
                        anchors.centerIn: parent
                        text: "NSFW"
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: "white"
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 2

                StyledText {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    maximumLineCount: 2
                    wrapMode: Text.WordWrap
                    text: row.modelData.title || ""
                    font.pixelSize: Appearance.font.pixelSize.small
                    font.weight: Font.DemiBold
                    color: root.ink
                }

                Item {
                    Layout.fillHeight: true
                }

                StyledText {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    /*
                     * The community and the person are where you go next; the
                     * numbers are not places. Same rule as the post screen.
                     *
                     * (The old filter dropped anything under three characters
                     * to lose an empty "r/", and ate every age with it: "4h",
                     * "3d", "9m".)
                     */
                    text: {
                        const sub = row.modelData.subreddit ? `<a href="sub:${row.modelData.subreddit}">r/${row.modelData.subreddit}</a>` : "";
                        const who = row.modelData.author && row.modelData.author !== "[deleted]" ? `<a href="user:${row.modelData.author}">u/${row.modelData.author}</a>` : "";
                        const bits = [sub, who, Thread.ago(row.modelData.created_utc), `${Thread.count(row.modelData.num_comments)} comments`];
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
            }

            // Straight into the catalogue, for a post that is a picture.
            IconButton {
                visible: Thread.imageUrl(row.modelData).length > 0
                icon: "library_add"
                tooltip: "Take this picture into quarry"
                size: 34
                onClicked: root.lens.takePicture(row.modelData)
            }
        }

        HoverHandler {
            id: hover
            cursorShape: Qt.PointingHandCursor
        }

        TapHandler {
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: root.lens.openPost(row.modelData)
        }
    }

    footer: Item {
        width: root.width
        height: root.lens.loading ? 60 : 0

        LoadingIndicator {
            anchors.centerIn: parent
            running: root.lens.loading
        }
    }
}
