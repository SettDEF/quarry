import qs.modules.common
import qs.modules.lens
import qs.modules.widgets
import qs.services
import Qt5Compat.GraphicalEffects
import QtQuick
import QtQuick.Layouts
import "../fmt.js" as Fmt

/*
 * THE MORSE LENS WEARING QUARRY'S CLOTHES.
 *
 * Same chrome as the 4chan lens and the same surfaces as the gallery: a header
 * bar, a screen underneath, one menu and one viewer over the top. Somebody who
 * never looks at Telegram should find this indistinguishable from the rest of
 * the app — which is the point of a lens rather than an embedded client.
 */
LensSkin {
    id: root

    ground: Appearance.colors.colLayer0

    readonly property var lensRef: root.lens

    /*
     * THE RAIL IS THE CHAT LIST.
     *
     * quarry's own rail already lists the chats (the lens's `navTiles`), so a
     * list here as well was every chat twice. The search and the folders below
     * filter the rail; the list itself is drawn here only when the rail is
     * hidden (an immersive read), because then nothing else shows the chats.
     */
    readonly property bool railShown: !Host.chromeSuppressed

    /*
     * WHICH SURFACE AUTOSCROLL DRIVES — see LensSkin.scrollable.
     *
     * The screen says so: the chat screen names its conversation, not the
     * topic strip above it.
     */
    // Nothing while a picture is open over the list: autoscroll and its dock
    // are for the list, and scrolling it unseen behind the viewer helps nobody.
    scrollable: root.lensRef.viewing ? null : main.item ? (main.item.scrollable || main.item) : null
    padsItself: true

    /// The line under a title: what is wrong, else what is on screen.
    function statusLine() {
        const lens = root.lensRef;
        if (!lens.linkReady)
            return lens.linkReason;
        if (lens.errorText.length > 0)
            return lens.errorText;
        if (lens.bulkRunning)
            return `Keeping ${lens.bulkDone} of ${lens.bulkTotal}…`;
        if (lens.fetching)
            return "Asking Morse…";
        // A mock backend is fixtures, not somebody's Telegram, and a screen
        // that does not say so is claiming to be something it is not.
        const mock = lens.mock ? "Mock backend — these are fixtures · " : "";
        if (lens.screen === "chats")
            return `${mock}${lens.chats.length} chats · read-only`;
        const secret = lens.chatIsSecret ? " · secret chat, nothing leaves it" : "";
        const kind = Fmt.chatKind(lens.chat);
        if (lens.screen === "media") {
            // The fallback answers a different question, so it says which.
            const how = lens.wallFallback ? ` · from the last ${lens.scanned} messages — this Morse can't search a chat's files` : "";
            return `${mock}${lens.media.length}${lens.hasMore ? "+" : ""} files${how}`;
        }
        return `${mock}${kind.length > 0 ? kind + " · " : ""}${lens.messages.length} messages${lens.atTop ? " · the beginning" : ""}${secret}`;
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── chrome ───────────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 56
            color: Appearance.colors.colLayer0Base

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 8

                IconButton {
                    icon: "arrow_back"
                    tooltip: root.lensRef.canGoBack ? "Back" : "Close the lens"
                    onClicked: root.lensRef.canGoBack ? root.lensRef.back() : Lenses.close()
                }

                ChatAvatar {
                    visible: root.lensRef.screen !== "chats"
                    who: root.lensRef.chat
                    size: 36
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: -2

                    StyledText {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        text: root.lensRef.screen === "chats" ? "Morse" : root.lensRef.screenTitle
                        font.pixelSize: Appearance.font.pixelSize.larger
                        font.weight: Font.DemiBold
                        color: Appearance.colors.colOnLayer0
                    }

                    StyledText {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        visible: text.length > 0
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: root.lensRef.errorText.length > 0 || !root.lensRef.linkReady ? Appearance.colors.colError : Appearance.colors.colSubtext
                        text: root.statusLine()
                    }
                }

                MaterialTextField {
                    Layout.preferredWidth: 260
                    visible: root.lensRef.screen === "chats"
                    leadingIcon: "search"
                    placeholder: "Find a chat"
                    text: root.lensRef.chatFilter
                    onEdited: value => root.lensRef.chatFilter = value
                    onCleared: root.lensRef.chatFilter = ""
                }

                // The two readings of one chat, one button apart — both named.
                PillTabBar {
                    visible: root.lensRef.screen !== "chats"
                    labels: true
                    tabs: [
                        {
                            "id": "chat",
                            "icon": "forum",
                            "label": "Messages"
                        },
                        {
                            "id": "media",
                            "icon": "photo_library",
                            "label": "Pictures"
                        }
                    ]
                    current: root.lensRef.screen
                    onTabSelected: id => id === "media" ? root.lensRef.showMedia() : root.lensRef.screen = "chat"
                }

                IconButton {
                    visible: root.lensRef.screen === "media" && !root.lensRef.chatIsSecret
                    icon: root.lensRef.bulkRunning ? "stop_circle" : "library_add"
                    tooltip: root.lensRef.bulkRunning ? "Stop keeping" : "Keep every picture on this wall"
                    onClicked: root.lensRef.bulkRunning ? root.lensRef.cancelBulk() : root.lensRef.takeAll()
                }

                IconButton {
                    icon: "refresh"
                    tooltip: "Ask again"
                    onClicked: root.lensRef.refresh()
                }

                IconButton {
                    icon: "close"
                    tooltip: "Close"
                    onClicked: Lenses.close()
                }
            }
        }

        // ── folders, and what a wall is filtered to ──────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: visible ? 44 : 0
            visible: (root.lensRef.screen === "chats" && root.lensRef.folders.length > 0) || root.lensRef.screen === "media"
            color: Appearance.colors.colLayer0

            // Telegram's own folders, named: a row of identical folder icons
            // is not a choice anybody can make. They filter the rail.
            Flickable {
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 14
                visible: root.lensRef.screen === "chats"
                contentWidth: folderBar.width
                contentHeight: height
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.HorizontalFlick

                PillTabBar {
                    id: folderBar

                    anchors.verticalCenter: parent.verticalCenter
                    labels: true
                    tabs: root.folderTabs
                    current: root.lensRef.folderId
                    onTabSelected: id => root.lensRef.setFolder(id)
                }
            }

            PillTabBar {
                anchors.left: parent.left
                anchors.leftMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                visible: root.lensRef.screen === "media"
                labels: true
                tabs: root.lensRef.wallFilters.map(f => ({
                            "id": f.id,
                            "icon": f.icon,
                            "label": f.label
                        }))
                current: root.lensRef.wallFilter
                onTabSelected: id => root.lensRef.setWallFilter(id)
            }

            // How the wall is laid out — the same choice the gallery offers.
            PillTabBar {
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                visible: root.lensRef.screen === "media"
                iconOnly: true
                tabs: root.lensRef.wallLayouts.map(l => ({
                            "id": l.id,
                            "icon": l.icon,
                            "label": l.label
                        }))
                current: root.lensRef.wallLayout
                onTabSelected: id => root.lensRef.setWallLayout(id)
            }
        }

        // ── the screen ───────────────────────────────────────────────────────
        Loader {
            id: main

            Layout.fillWidth: true
            Layout.fillHeight: true
            sourceComponent: root.lensRef.screen === "media" ? mediaScreen : root.lensRef.screen === "chat" ? chatScreen : root.railShown ? pickScreen : chatsScreen
        }
    }

    // Telegram's own folder tabs. "All" is the ABSENCE of a folder, so it is
    // this client's row rather than one the server sent.
    readonly property var folderTabs: [
        {
            "id": "",
            "icon": "forum",
            "label": "All"
        }
    ].concat(root.lensRef.folders.map(f => ({
                "id": String(f.id),
                // Telegram's own icon for the folder, not one grey folder
                // nine times — see fmt.js.
                "icon": Fmt.folderIcon(f.icon),
                "label": f.unread > 0 ? `${f.title} ${f.unread}` : String(f.title)
            })))

    Component {
        id: chatsScreen
        ChatList {
            lens: root.lensRef
        }
    }

    Component {
        id: pickScreen

        PagePlaceholder {
            icon: "forum"
            title: "Pick a chat in the rail"
            description: root.lensRef.chatFilter.length > 0 ? "The rail shows the chats that match." : "Search and the folders above narrow it down."
        }
    }

    Component {
        id: chatScreen

        /*
         * A FORUM IS A LIST OF TOPICS WITH A CHAT UNDER IT.
         *
         * The strip only exists for a chat that has topics, so an ordinary
         * conversation is unchanged — and picking one narrows the messages
         * below to that topic.
         */
        Item {
            // The messages, not the topic strip above them: Morse's own list
            // when the real chat is in, else the lens's conversation.
            readonly property var scrollable: realChat.item ? realChat.item.view : convo

            Column {
                anchors.fill: parent
                spacing: 0

                TopicBar {
                    id: topics
                    width: parent.width
                    lens: root.lensRef
                }

                /*
                 * Morse's real conversation — bubbles, replies, the composer,
                 * all of it — loaded from the installed Morse module, which
                 * shell.qml puts on the import path. Built by name so a quarry
                 * without Morse installed falls back to `Conversation` below
                 * instead of failing to load.
                 */
                Item {
                    id: realChatHost
                    width: parent.width
                    height: realChat.item ? parent.height - topics.height : 0
                    visible: realChat.item !== null

                    QtObject {
                        id: realChat
                        property var item: null
                    }

                    function build() {
                        if (realChat.item)
                            return;
                        try {
                            realChat.item = Qt.createQmlObject(
                                "import Morse\nThreadView { anchors.fill: parent }", realChatHost, "morse-real-chat");
                        } catch (e) {
                            console.warn("[morse lens] Morse's chat is not installed; using the lens's own:", e);
                            realChat.item = null;
                            return;
                        }
                        // The lens bar already names the chat; one title, not two.
                        if (realChat.item.showHeader !== undefined)
                            realChat.item.showHeader = false;
                        realChat.item.chatId = Qt.binding(() => root.lensRef.chatId);
                        realChat.item.topicId = Qt.binding(() => String(root.lensRef.thread || ""));
                        realChat.item.mediaRequested.connect(message => root.lensRef.openViewer(message));
                    }

                    Component.onCompleted: build()
                }

                Conversation {
                    id: convo
                    visible: realChat.item === null

                    // The whole pane: theirs on the left, yours on the right.
                    // A channel is one centred column of posts instead.
                    width: convo.channel ? Math.min(parent.width, 760) : parent.width
                    x: Math.round((parent.width - width) / 2)
                    height: visible ? parent.height - topics.height : 0
                    lens: root.lensRef
                    onContextRequested: (message, x, y, link) => mediaMenu.openFor(message, x, y, link)
                }
            }
        }
    }

    Component {
        id: mediaScreen
        MediaWall {
            lens: root.lensRef
            onContextRequested: (message, x, y) => mediaMenu.openFor(message, x, y)
        }
    }

    // One of each for the whole skin: a delegate that scrolls away must not
    // take an open menu or an open picture with it.
    MediaMenu {
        id: mediaMenu
        lens: root.lensRef
    }

    MediaViewer {
        id: viewer

        // Full screen: into the window's overlay, over everything the app
        // draws — but under the popups, so its own menu still opens on top.
        parent: viewer.full && Shell.overlay ? Shell.overlay : root
        anchors.fill: parent
        z: viewer.full ? -1 : 50
        lens: root.lensRef
        onContextRequested: (message, x, y) => mediaMenu.openFor(message, x, y)
    }

    /*
     * THE QUESTION NOBODY WAS ASKING.
     *
     * `acceptInvite` and `declineInvite` have been on the lens since the
     * beginning and `links.join` is on the wire's allow-list — but no skin ever
     * drew the question, so following an invitation set `pendingInvite` and
     * showed nothing at all. The click looked like it had not registered.
     *
     * Joining is a WRITE: it puts your account in somebody's group, which is
     * visible to everyone in it and is not undone by pressing back. So it is a
     * question with two plain answers rather than something that happens
     * because you clicked a link — the same reason `links.join` is a separate
     * method from `links.resolve` on the wire.
     */
    Sheet {
        id: invite

        surfaceWidth: Math.min(420, root.width - 48)
        surfaceHeight: inviteBody.implicitHeight + 36
        onClosed: root.lensRef.declineInvite()

        // Set, not bound: Escape or a click outside runs Sheet.close(), which
        // assigns `open` and would cut a binding, so later invites showed nothing.
        Connections {
            target: root.lensRef
            function onPendingInviteChanged() {
                invite.open = root.lensRef.pendingInvite.length > 0;
            }
        }

        ColumnLayout {
            id: inviteBody

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 18
            spacing: 10

            RowLayout {
                Layout.fillWidth: true
                spacing: 12

                // The chat's own picture — usually a data: minithumbnail, so
                // it is there the moment the question is.
                Rectangle {
                    id: inviteBadge
                    Layout.preferredWidth: 52
                    Layout.preferredHeight: 52
                    radius: width / 2
                    color: Appearance.colors.colSecondaryContainer

                    MaterialSymbol {
                        anchors.centerIn: parent
                        visible: invitePic.status !== Image.Ready
                        text: "group"
                        iconSize: 26
                        color: Appearance.colors.colOnSecondaryContainer
                    }

                    Image {
                        id: invitePic
                        anchors.fill: parent
                        source: root.lensRef.invitePhoto
                        sourceSize.width: 104
                        sourceSize.height: 104
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        // One sheet, open rarely: the mask is not a per-tile cost.
                        layer.enabled: true
                        layer.effect: OpacityMask {
                            maskSource: Rectangle {
                                width: inviteBadge.width
                                height: inviteBadge.height
                                radius: inviteBadge.radius
                            }
                        }
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    StyledText {
                        Layout.fillWidth: true
                        text: "Join " + root.lensRef.inviteTitle + "?"
                        font.pixelSize: Appearance.font.pixelSize.larger
                        font.weight: Font.Medium
                        wrapMode: Text.Wrap
                        color: Appearance.colors.colOnLayer1
                    }

                    StyledText {
                        Layout.fillWidth: true
                        visible: root.lensRef.inviteMembers > 0
                        text: root.lensRef.inviteMembers.toLocaleString(Qt.locale(), "f", 0) + (root.lensRef.inviteMembers === 1 ? " member" : " members")
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                    }
                }
            }

            StyledText {
                Layout.fillWidth: true
                // Said plainly, because it is the part people are surprised by.
                text: "You will appear in its member list, and its messages will arrive in your chats."
                font.pixelSize: Appearance.font.pixelSize.smaller
                wrapMode: Text.Wrap
                color: Appearance.colors.colSubtext
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 6
                spacing: 8

                Item {
                    Layout.fillWidth: true
                }

                TextButton {
                    // A public chat can be read without joining.
                    text: root.lensRef.inviteChatId.length > 0 ? "Just look" : "Not now"
                    onClicked: root.lensRef.inviteChatId.length > 0 ? root.lensRef.lookAtInvite() : root.lensRef.declineInvite()
                }

                TextButton {
                    text: "Join"
                    onClicked: root.lensRef.acceptInvite()
                }
            }
        }
    }
}
