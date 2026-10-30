import qs.modules.common
import qs.modules.widgets
import QtQuick
import QtQuick.Layouts
import "../fmt.js" as Fmt

/*
 * A FORUM'S TOPICS, AS THINGS WITH A STATE — not a row of chips.
 *
 * A chip says a topic exists. What you actually choose between is: which one
 * has something new in it, what was last said there, which one is pinned, which
 * one is shut. Telegram gives every topic a colour and a count, and a reader
 * that throws both away makes you open each one to find out where the
 * conversation is.
 *
 * So each topic is a card: its colour down the side, its name, the last line
 * said in it, and an unread count that is the loudest thing on the card when it
 * is not zero. The one you are reading is filled rather than outlined, because
 * "where am I" should be answerable at a glance and not by reading labels.
 */
Rectangle {
    id: root

    required property var lens

    readonly property var topics: root.lens.topics
    readonly property bool inTopic: root.lens.thread.length > 0

    implicitHeight: root.topics.length > 0 ? 74 : 0
    visible: implicitHeight > 0
    color: Appearance.colors.colLayer0Base

    Behavior on implicitHeight {
        NumberAnimation {
            duration: Appearance.animDur(160)
            easing.type: Easing.OutCubic
        }
    }

    ListView {
        id: strip
        anchors.fill: parent
        anchors.leftMargin: 10
        anchors.rightMargin: 10
        anchors.topMargin: 7
        anchors.bottomMargin: 7
        orientation: ListView.Horizontal
        spacing: 8
        clip: true
        // The one you are in, brought into view — after a skin change or a
        // reopen the topic you were reading can be forty cards along.
        currentIndex: {
            for (let i = 0; i < root.topics.length; i++)
                if (String(root.topics[i].id) === root.lens.thread)
                    return i + 1;
            return 0;
        }
        highlightFollowsCurrentItem: true
        preferredHighlightBegin: 0
        preferredHighlightEnd: width
        highlightRangeMode: ListView.ApplyRange

        model: [
            {
                "id": "",
                "name": "All topics",
                "unread": 0,
                "iconColor": "",
                "pinned": false,
                "closed": false,
                "lastMessage": null
            }
        ].concat(root.topics)

        delegate: Rectangle {
            id: card
            required property var modelData
            readonly property bool here: String(card.modelData.id || "") === root.lens.thread
            readonly property int unread: Number(card.modelData.unread || 0)
            readonly property string preview: {
                const last = card.modelData.lastMessage;
                if (!last)
                    return card.modelData.id === "" ? "The whole forum, in one stream" : "";
                const text = String(last.text || "").replace(/\s+/g, " ").trim();
                if (text.length > 0)
                    return text;
                return last.media ? Fmt.mediaLabel(last.media) : "";
            }

            width: Math.min(230, Math.max(132, nameLabel.implicitWidth + 84))
            height: strip.height
            radius: 12
            color: card.here ? Appearance.colors.colPrimary : hover.hovered ? Appearance.colors.colLayer1Hover : Appearance.colors.colLayer1

            // Telegram's own colour for the topic, down the leading edge. The
            // general topic and the "all" card have none, and get the outline
            // instead of a stripe rather than a made-up colour.
            Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.margins: 6
                width: 3
                radius: 2
                visible: String(card.modelData.iconColor || "").length > 0
                color: {
                    const raw = String(card.modelData.iconColor || "");
                    if (raw.length === 0)
                        return "transparent";
                    return raw.indexOf("#") === 0 ? raw : `#${raw}`;
                }
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 10
                anchors.topMargin: 8
                anchors.bottomMargin: 8
                spacing: 1

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 5

                    MaterialSymbol {
                        visible: card.modelData.pinned === true || card.modelData.closed === true || card.modelData.id === ""
                        text: card.modelData.id === "" ? "forum" : card.modelData.closed === true ? "lock" : "push_pin"
                        iconSize: 13
                        color: card.here ? Appearance.colors.colOnPrimary : Appearance.colors.colSubtext
                    }

                    StyledText {
                        id: nameLabel
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        text: card.modelData.name || "Topic"
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        // Unread is said twice on purpose: a count you have to
                        // hunt for is a count nobody reads.
                        font.weight: card.unread > 0 ? Font.Bold : Font.Medium
                        color: card.here ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer1
                    }

                    Rectangle {
                        visible: card.unread > 0
                        implicitWidth: Math.max(18, unreadLabel.implicitWidth + 10)
                        implicitHeight: 16
                        radius: 8
                        color: card.here ? Appearance.colors.colOnPrimary : Appearance.colors.colPrimary

                        StyledText {
                            id: unreadLabel
                            anchors.centerIn: parent
                            text: card.unread > 99 ? "99+" : String(card.unread)
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            font.weight: Font.DemiBold
                            color: card.here ? Appearance.colors.colPrimary : Appearance.colors.colOnPrimary
                        }
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    maximumLineCount: 2
                    wrapMode: Text.WordWrap
                    visible: text.length > 0
                    text: card.preview
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: card.here ? Appearance.colors.colOnPrimary : Appearance.colors.colSubtext
                    opacity: card.here ? 0.85 : 1
                }
            }

            HoverHandler {
                id: hover
                cursorShape: Qt.PointingHandCursor
            }

            TapHandler {
                gesturePolicy: TapHandler.ReleaseWithinBounds
                onTapped: String(card.modelData.id || "").length === 0 ? root.lens.closeThread() : root.lens.openThread(card.modelData)
            }
        }
    }
}
