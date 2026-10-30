import QtQuick
import QtQuick.Layouts
import qs.modules.common
import qs.modules.lens
import qs.modules.widgets
import qs.services

/*
 * THE READER IN QUARRY'S OWN CLOTHES — layer surfaces, the app's colours.
 *
 * Holds scroll position and nothing else: the communities, the listing, the
 * open post and every folded chain belong to the lens, which is what lets you
 * change skin halfway down a thread and land in the same place.
 */
LensSkin {
    id: root

    readonly property var theLens: root.lens

    ground: Appearance.colors.colLayer0

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

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
                    tooltip: root.theLens.canGoBack ? "Back" : "Close the lens"
                    onClicked: root.theLens.canGoBack ? root.theLens.goBack() : Lenses.close()
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: -2

                    StyledText {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        text: root.theLens.screenTitle
                        font.pixelSize: Appearance.font.pixelSize.larger
                        font.weight: Font.DemiBold
                        color: Appearance.colors.colOnLayer0
                    }

                    StyledText {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        visible: text.length > 0
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: root.theLens.errorText.length > 0 ? Appearance.colors.colError : Appearance.colors.colSubtext
                        text: {
                            if (root.theLens.errorText.length > 0)
                                return root.theLens.errorText;

                            if (root.theLens.loading && root.theLens.posts.length === 0)
                                return "Asking reddit…";

                            return root.theLens.screen === "feed" ? `${root.theLens.posts.length} posts` : "";
                        }
                    }

                }

                MaterialTextField {
                    Layout.preferredWidth: 200
                    placeholder: "Search, or r/name"
                    // r/name or u/name goes there; anything else searches reddit
                    onAccepted: (text) => {
                        const t = String(text).trim();
                        if (/^\/?r\//.test(t)) return root.theLens.openSub(t.replace(/^\/?r\//, ""));
                        if (/^\/?u\//.test(t)) return root.theLens.openUser(t.replace(/^\/?u\//, ""));
                        return root.theLens.search(t, false);
                    }
                }

                IconButton {
                    visible: root.theLens.screen === "feed" && root.theLens.layout !== "theater"
                    icon: root.theLens.autoscroll ? "stop_circle" : "keyboard_double_arrow_down"
                    tooltip: root.theLens.autoscroll ? "Stop autoscroll (A)" : "Autoscroll (A)"
                    onClicked: root.theLens.autoscroll = !root.theLens.autoscroll
                }

                IconButton {
                    icon: "public"
                    tooltip: "Open the real site here"
                    onClicked: root.theLens.showSite()
                }

            }

        }

        // while searching: order, time, where, matching communities
        SearchBar {
            Layout.fillWidth: true
            lens: root.theLens
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            // the feed reads itself (A); stops when a post opens
            AutoScroll {
                z: 5
                lens: root.theLens
                visible: root.theLens.screen === "feed" && root.theLens.layout !== "theater"
                flickable: root.theLens.layout === "cards" ? cardsView : root.theLens.showsWall ? wallView.view : listView
            }
            Shortcut {
                sequence: "A"
                enabled: root.visible && root.theLens.screen === "feed" && root.theLens.layout !== "theater"
                onActivated: root.theLens.autoscroll = !root.theLens.autoscroll
            }

            // one picture or video at a time, as big as the pane
            Theater {
                anchors.fill: parent
                anchors.margins: 8
                visible: root.theLens.screen === "feed" && root.theLens.layout === "theater"
                lens: root.theLens
            }

            // full posts with their media playing in the card (Rodded's way)
            Cards {
                id: cardsView
                anchors.fill: parent
                anchors.margins: 12
                visible: root.theLens.screen === "feed" && root.theLens.layout === "cards"
                lens: root.theLens
            }

            Listing {
                id: listView
                anchors.fill: parent
                anchors.margins: 12
                // The cards are one of five ways to read a subreddit now; the
                // other four are pictures. See the lens's `layouts`.
                visible: root.theLens.screen === "feed" && !root.theLens.showsWall && root.theLens.layout !== "cards" && root.theLens.layout !== "theater"
                lens: root.theLens
            }

            Wall {
                id: wallView
                anchors.fill: parent
                anchors.margins: 8
                visible: root.theLens.screen === "feed" && root.theLens.showsWall
                lens: root.theLens
            }

            Thread {
                anchors.fill: parent
                anchors.margins: 12
                visible: root.theLens.screen === "post"
                lens: root.theLens
            }

            // Every community reddit will admit to, for a reader with no
            // account and therefore no subscriptions of its own.
            ListView {
                anchors.fill: parent
                anchors.margins: 12
                visible: root.theLens.screen === "communities"
                clip: true
                spacing: 6
                model: root.theLens.communities

                delegate: Rectangle {
                    required property var modelData

                    width: ListView.view.width
                    height: 56
                    radius: 14
                    color: communityHover.hovered ? Appearance.colors.colLayer1Hover : Appearance.colors.colLayer1

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 10
                        spacing: 0

                        StyledText {
                            text: `r/${parent.parent.modelData.display_name || ""}`
                            font.pixelSize: Appearance.font.pixelSize.small
                            font.weight: Font.DemiBold
                            color: Appearance.colors.colOnLayer1
                        }

                        StyledText {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            text: parent.parent.modelData.public_description || ""
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            color: Appearance.colors.colSubtext
                        }

                    }

                    HoverHandler {
                        id: communityHover

                        cursorShape: Qt.PointingHandCursor
                    }

                    TapHandler {
                        gesturePolicy: TapHandler.ReleaseWithinBounds
                        onTapped: root.theLens.openSub(parent.modelData.display_name)
                    }

                }

            }

        }

    }

}
