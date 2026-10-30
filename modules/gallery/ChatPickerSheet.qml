import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

/*
 * Pick a chat, pick what the picture should arrive as, send it.
 *
 * (The connection's name is not decided — see the header of
 * services/Dispatch.qml. Nothing a user reads here carries a codename.)
 *
 * Three decisions in one surface, in the order they are actually made: where,
 * as what, and with what said alongside. Splitting them across two sheets would
 * mean choosing a chat before knowing whether "as a GIF" was even on offer.
 *
 * PRIVACY. Chats are drawn as a title, a kind and an unread count and nothing
 * else. Morse's `Chat` carries a `lastMessage`, and a picker that printed a
 * message preview would put a conversation on screen — and into any screenshot
 * of it — to answer a question nobody asked. `Dispatch._slimChat` drops it
 * before it ever reaches this file.
 */
Sheet {
    id: root

    property var item: null
    property var chat: null
    /// A file that already exists and must travel exactly as it is — what the
    /// export sheet hands over after you have chosen a crop. "" means export
    /// from the item instead, in whichever form is picked below.
    property string path: ""
    property string mode: ""
    property string search: ""
    property var results: []
    property bool searching: false

    surfaceWidth: 440
    surfaceHeight: Math.min(600, root.height - 80)

    /*
     * A file already on disk has no "as a GIF" question left to ask — it is
     * whatever it is. The only choice remaining is whether Telegram should
     * recompress it as a photo or carry it as a file.
     */
    readonly property var modes: root.path.length > 0 ? [
        {
            "id": "photo",
            "label": "As a photo",
            "icon": "image",
            "hint": "Telegram recompresses"
        },
        {
            "id": "file",
            "label": "As a file",
            "icon": "attach_file",
            "hint": "exactly the file you just made"
        }
    ] : Dispatch.modesFor(root.item)
    /// Recent chats, or what the last search turned up. One list, two sources,
    /// because "recent first, searchable" is one question asked two ways.
    readonly property var shown: root.search.trim().length > 0 ? root.results : Dispatch.chats

    function openFor(picked, filePath) {
        root.item = picked;
        root.path = filePath || "";
        root.chat = null;
        root.search = "";
        root.results = [];
        searchField.text = "";
        captionField.text = "";
        // Whatever this picture can be, first entry — a GIF defaults to
        // arriving as a GIF.
        root.mode = root.modes.length > 0 ? root.modes[0].id : "file";
        Dispatch.refreshChats();
        root.open = true;
    }

    function kindIcon(chat) {
        switch (chat.kind) {
        case "channel":
            return "campaign";
        case "group":
        case "supergroup":
            return "group";
        case "secret":
            return "lock";
        }
        return "person";
    }

    onSearchChanged: searchDebounce.restart()

    // A chat picked before the daemon went away is not a chat any more: its id
    // belonged to a session that has ended, and leaving its name under the Send
    // button says something is selected when nothing is.
    Connections {
        target: Dispatch
        function onAvailableChanged() {
            if (!Dispatch.available)
                root.chat = null;
        }
    }

    Timer {
        id: searchDebounce
        interval: 240
        onTriggered: {
            const term = root.search;
            if (term.trim().length === 0) {
                root.results = [];
                root.searching = false;
                return;
            }
            root.searching = true;
            Dispatch.searchChats(term, function (err, chats) {
                // A search that has been superseded must not overwrite the one
                // on screen — the answers come back in whatever order the
                // server felt like.
                if (term !== root.search)
                    return;
                root.searching = false;
                root.results = chats;
            });
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 10

        // ── what is being sent ───────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            Rectangle {
                Layout.preferredWidth: 42
                Layout.preferredHeight: 42
                radius: Appearance.rounding.small
                color: Appearance.colors.colLayer2
                clip: true
                visible: root.item !== null

                ThumbImage {
                    anchors.fill: parent
                    item: root.item
                    size: 160
                    gated: false
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                StyledText {
                    text: "Send to a chat"
                    font.pixelSize: Appearance.font.pixelSize.larger
                    font.weight: Font.DemiBold
                    color: Appearance.colors.colOnLayer1
                }

                StyledText {
                    Layout.fillWidth: true
                    text: {
                        if (root.path.length > 0)
                            return root.path.split("/").pop();
                        if (!root.item)
                            return "";
                        return root.item.title && root.item.title.length > 0 ? root.item.title : root.item.slug;
                    }
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: Appearance.colors.colSubtext
                    elide: Text.ElideRight
                }
            }

            IconButton {
                icon: "close"
                size: 30
                onClicked: root.close()
            }
        }

        /*
         * WHEN THERE IS NOTHING TO SEND TO, SAY IT AND STOP.
         *
         * One line, and no buttons under it. There is no morsed user unit to
         * start — Morse ships a launcher script, not a service — so a "Start
         * it" button here would be a guess at a command, and a button that
         * usually fails is worse than the sentence on its own.
         */
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 38
            visible: !Dispatch.available
            radius: Appearance.rounding.small
            color: Appearance.colors.colLayer2
            border.width: 1
            border.color: Appearance.colors.colLayer0Border

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 8

                MaterialSymbol {
                    text: Dispatch.state === "connecting" ? "sync" : "cloud_off"
                    iconSize: Appearance.font.pixelSize.normal
                    color: Appearance.colors.colSubtext
                }

                StyledText {
                    Layout.fillWidth: true
                    text: Dispatch.reason
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colOnLayer1
                    elide: Text.ElideRight
                }
            }
        }

        // A mock send goes nowhere. Saying so is the whole reason the backend
        // is on the wire — see Morse/PROTOCOL.md on the fixture QR code.
        StyledText {
            Layout.fillWidth: true
            visible: Dispatch.available && Dispatch.mock
            text: "Morse is on its mock backend — this will not reach Telegram."
            font.pixelSize: Appearance.font.pixelSize.smallest
            color: Appearance.colors.colSubtext
            wrapMode: Text.WordWrap
        }

        // ── as what ─────────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            visible: root.modes.length > 1

            Repeater {
                model: root.modes

                delegate: PillTab {
                    required property var modelData
                    icon: modelData.icon
                    label: modelData.label
                    labelSize: Appearance.font.pixelSize.smaller
                    horizontalPadding: 10
                    verticalPadding: 5
                    active: root.mode === modelData.id
                    onTriggered: root.mode = modelData.id
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            text: {
                const picked = root.modes.find(m => m.id === root.mode);
                return picked ? picked.hint : "";
            }
            font.pixelSize: Appearance.font.pixelSize.smallest
            color: Appearance.colors.colSubtext
        }

        Divider {
            Layout.fillWidth: true
        }

        // ── where ───────────────────────────────────────────────────────────
        MaterialTextField {
            id: searchField
            Layout.fillWidth: true
            enabled: Dispatch.available
            opacity: enabled ? 1 : 0.5
            placeholder: "Search every chat…"
            leadingIcon: "search"
            onEdited: text => root.search = text
            onCleared: root.search = ""
        }

        StyledListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 2
            model: root.shown

            delegate: Rectangle {
                id: chatRow
                required property var modelData
                width: list.width
                height: 44
                radius: Appearance.rounding.small
                color: root.chat && root.chat.id === modelData.id ? Appearance.colors.colSecondaryContainer : (chatHover.hovered ? Appearance.colors.colLayer2Hover : "transparent")

                Behavior on color {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(chatRow)
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    spacing: 10

                    MaterialSymbol {
                        text: root.kindIcon(modelData)
                        iconSize: 18
                        color: root.chat && root.chat.id === modelData.id ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colSubtext
                    }

                    StyledText {
                        Layout.fillWidth: true
                        text: modelData.title
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: root.chat && root.chat.id === modelData.id ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                        elide: Text.ElideRight
                    }

                    // Pinned and unread, not a preview: enough to recognise the
                    // row, nothing about what was said in it.
                    MaterialSymbol {
                        visible: modelData.pinned
                        text: "push_pin"
                        iconSize: 14
                        color: Appearance.colors.colSubtext
                    }

                    StyledText {
                        visible: modelData.unread > 0
                        text: modelData.unread
                        font.family: Appearance.font.family.monospace
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: Appearance.colors.colPrimary
                    }
                }

                HoverHandler {
                    id: chatHover
                    cursorShape: Qt.PointingHandCursor
                }

                TapHandler {
                    onTapped: root.chat = modelData
                    // A double click is "yes, that one" — the same shortcut a
                    // file dialog has.
                    onDoubleTapped: {
                        root.chat = modelData;
                        root.send();
                    }
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: Dispatch.available && root.shown.length === 0 && !Dispatch.chatsLoading && !root.searching
            text: root.search.trim().length > 0 ? "No chat by that name." : "No chats yet."
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
        }

        // ── what to say with it ─────────────────────────────────────────────
        MaterialTextField {
            id: captionField
            Layout.fillWidth: true
            enabled: Dispatch.available
            opacity: enabled ? 1 : 0.5
            placeholder: "Caption (optional)"
            leadingIcon: "edit"
            showClear: false
            onAccepted: root.send()
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            // The state, where the eye already is. It replaces nothing, so the
            // list stays visible while the upload runs.
            LoadingIndicator {
                size: 18
                visible: Dispatch.sendState === "exporting" || Dispatch.sendState === "sending"
            }

            MaterialSymbol {
                visible: Dispatch.sendState === "sent"
                text: "check_circle"
                iconSize: 18
                color: Appearance.colors.colPrimary
            }

            StyledText {
                Layout.fillWidth: true
                elide: Text.ElideRight
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Dispatch.sendState === "failed" ? Appearance.colors.colError : Appearance.colors.colSubtext
                text: {
                    switch (Dispatch.sendState) {
                    case "exporting":
                        return "Preparing the file…";
                    case "sending":
                        return "Sending…";
                    case "sent":
                        return `Sent to ${Dispatch.sendTitle}`;
                    case "failed":
                        return Dispatch.sendError;
                    }
                    return root.chat ? root.chat.title : "Pick a chat";
                }
            }

            TextButton {
                text: "Send"
                icon: "send"
                variant: "filled"
                enabled: Dispatch.available && root.chat !== null && Dispatch.sendState !== "sending" && Dispatch.sendState !== "exporting"
                onClicked: root.send()
            }
        }
    }

    function send() {
        if (!root.chat || !Dispatch.available)
            return;
        const target = root.chat;
        const done = function (err) {
            if (err) {
                Toast.error("Not sent: " + err);
                return;
            }
            Toast.show(`Sent to ${target.title}`);
            // Closed on success only: a failure leaves the sheet up with the
            // reason on it, so the next try does not start from nothing.
            root.close();
        };
        if (root.path.length > 0)
            Dispatch.sendPath(root.path, target, root.mode, captionField.text, done);
        else
            Dispatch.sendItem(root.item, target, root.mode, captionField.text, done);
    }
}
