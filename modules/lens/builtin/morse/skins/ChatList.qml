import "../fmt.js" as Fmt
import Qt5Compat.GraphicalEffects
import QtQuick
import QtQuick.Controls
import qs.modules.common
import qs.modules.widgets
import qs.services

/*
 * THE CHATS, AS CARDS.
 *
 * The rail carries the same list — this screen is what you land on, and what a
 * chat looks like before you are in it: who or what it is, when it last said
 * something, and how much of it you have not read. The last message itself is
 * NOT drawn here: a wall of previews is a wall of somebody's private words, on
 * a screen that is one keystroke from a screenshot.
 */
ListView {
    id: root

    required property var lens

    model: root.lens.visibleChats
    // Rows that touch, like every chat client's: a gap between sixty cards
    // is sixty stripes of background.
    spacing: 2
    topMargin: 8
    // Room for the dock floating over the end of the list.
    bottomMargin: 24 + Host.bottomInset
    leftMargin: 8
    rightMargin: 8
    clip: true
    cacheBuffer: 800
    boundsBehavior: Flickable.StopAtBounds

    // Back from a chat lands where you were in the list, per folder; a
    // filtered list is a search, not a place.
    RememberScroll {
        view: root
        key: root.lens.chatFilter.length > 0 ? "" : `morse:chats:${root.lens.folderId}`
    }

    // The list refreshes on every message in every chat; it stays put.
    KeepPlace {
        view: root
        items: root.lens.visibleChats
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

    StyledText {
        // The placeholder below says it, and offers a way out.

        parent: root
        anchors.centerIn: parent
        width: parent.width - 80
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        visible: root.count === 0
        text: {
            if (!root.lens.linkReady)
                return "";

            if (root.lens.loadingChats || root.lens.searchingChats)
                return "Asking Morse…";

            if (root.lens.chatFilter.length > 0)
                return "No chat by that name.";

            return root.lens.errorText.length > 0 ? root.lens.errorText : "No chats.";
        }
        color: Appearance.colors.colSubtext
    }

    ScrollBar.vertical: StyledScrollBar {
        view: root
    }

    delegate: Rectangle {
        id: card

        required property var modelData
        required property int index
        readonly property int unread: card.modelData.unread || 0
        readonly property bool muted: card.modelData.muted === true
        // The chat open beside the list (Quarry.qml `split`), or the one you
        // came back from.
        readonly property bool current: root.lens.screen !== "chats" && String(card.modelData.id) === root.lens.chatId

        // The last few coming into existence is the ask for the next page.
        Component.onCompleted: {
            if (card.index >= root.count - 3)
                root.lens.loadMoreChats();

        }
        width: root.width - root.leftMargin - root.rightMargin
        height: 64
        radius: Appearance.rounding.normal
        color: tap.pressed ? Appearance.colors.colLayer1Active : card.current ? (hover.hovered ? Appearance.colors.colSecondaryContainerHover : Appearance.colors.colSecondaryContainer) : hover.hovered ? Appearance.colors.colLayer1Hover : "transparent"

        HoverHandler {
            id: hover

            cursorShape: Qt.PointingHandCursor
        }

        TapHandler {
            id: tap

            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: root.lens.openChat(card.modelData.id)
        }

        ChatAvatar {
            id: badge

            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            who: card.modelData
            size: 46
        }

        /*
         * Title and time on one line, kind and counts on the next — the shape
         * every chat list has, so the eye finds the time at the top right and
         * the unread count under it without reading the row. The last message
         * itself is still NOT drawn: a wall of previews is a wall of
         * somebody's private words.
         */
        Item {
            anchors.left: badge.right
            anchors.leftMargin: 12
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            height: 40

            StyledText {
                id: title

                anchors.left: parent.left
                anchors.right: when.left
                anchors.rightMargin: 8
                anchors.top: parent.top
                elide: Text.ElideRight
                text: card.modelData.title || "Chat"
                font.pixelSize: Appearance.font.pixelSize.normal
                font.weight: card.unread > 0 ? Font.Bold : Font.DemiBold
                color: card.current ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
            }

            StyledText {
                id: when

                anchors.right: parent.right
                anchors.baseline: title.baseline
                text: card.modelData.lastMessage && card.modelData.lastMessage.date ? Fmt.when(card.modelData.lastMessage.date) : ""
                font.pixelSize: Appearance.font.pixelSize.smallest
                color: card.unread > 0 && !card.muted ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
            }

            Row {
                id: kindRow

                anchors.left: parent.left
                anchors.right: trailing.left
                anchors.rightMargin: 8
                anchors.bottom: parent.bottom
                spacing: 4

                MaterialSymbol {
                    anchors.verticalCenter: parent.verticalCenter
                    text: Fmt.chatIcon(card.modelData)
                    iconSize: 14
                    color: Appearance.colors.colSubtext
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    width: kindRow.width - 18
                    elide: Text.ElideRight
                    text: Fmt.chatKind(card.modelData)
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                }

            }

            Row {
                id: trailing

                anchors.right: parent.right
                anchors.bottom: parent.bottom
                spacing: 5

                // Straight to the pictures, without reading the conversation
                // first. Reserved rather than shown on hover, so the badges do
                // not jump left when the pointer arrives.
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 24
                    height: 20
                    radius: 10
                    opacity: hover.hovered || wallHover.hovered ? 1 : 0
                    enabled: hover.hovered || wallHover.hovered
                    color: wallHover.hovered ? Appearance.colors.colLayer2Hover : Appearance.colors.colLayer2

                    Behavior on opacity {
                        animation: Appearance.animation.stateChange.numberAnimation.createObject(card)
                    }

                    MaterialSymbol {
                        anchors.centerIn: parent
                        text: "grid_view"
                        iconSize: 14
                        color: Appearance.colors.colOnLayer2
                    }

                    HoverHandler {
                        id: wallHover

                        cursorShape: Qt.PointingHandCursor
                    }

                    TapHandler {
                        gesturePolicy: TapHandler.ReleaseWithinBounds
                        onTapped: {
                            root.lens.openChat(card.modelData.id);
                            root.lens.showMedia();
                        }
                    }

                    StyledToolTip {
                        visible: wallHover.hovered
                        text: "Its pictures"
                    }

                }

                MaterialSymbol {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: card.muted
                    text: "notifications_off"
                    iconSize: 14
                    color: Appearance.colors.colSubtext
                }

                MaterialSymbol {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: card.modelData.pinned === true && card.unread === 0
                    text: "push_pin"
                    iconSize: 14
                    color: Appearance.colors.colSubtext
                }

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: card.unread > 0
                    width: Math.max(20, count.implicitWidth + 12)
                    height: 20
                    radius: 10
                    color: card.muted ? Appearance.colors.colLayer3 : Appearance.colors.colPrimary

                    StyledText {
                        id: count

                        anchors.centerIn: parent
                        // Capped: 4213 unread made a badge wide enough to
                        // elide the title it belongs to.
                        text: card.unread > 999 ? "999+" : String(card.unread)
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        font.weight: Font.DemiBold
                        color: card.muted ? Appearance.colors.colOnLayer3 : Appearance.colors.colOnPrimary
                    }

                }

            }

        }

        Behavior on color {
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(card)
        }

    }

}
