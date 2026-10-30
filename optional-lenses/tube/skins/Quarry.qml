import QtMultimedia
import QtQuick
import QtQuick.Layouts
import qs.modules.common
import qs.modules.gallery
import qs.modules.lens
import qs.modules.widgets
import qs.services

/*
 * THE DEFAULT SKIN — the tube sites wearing quarry's own clothes.
 *
 * Colour roles and ii surfaces, so someone who never looks at the sites finds
 * this the same app. Holds nothing but scroll position: where you are and what
 * has been fetched belong to the lens.
 */
LensSkin {
    id: root

    readonly property var theLens: root.lens

    ground: Appearance.colors.colLayer0

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── chrome: where you are, and the site's own search ─────────────────
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
                        color: root.theLens.errorText.length > 0 || root.theLens.skippedText.length > 0 ? Appearance.colors.colError : Appearance.colors.colSubtext
                        text: {
                            if (root.theLens.errorText.length > 0)
                                return root.theLens.errorText;

                            if (root.theLens.skippedText.length > 0)
                                return root.theLens.skippedText;

                            if (root.theLens.loading && root.theLens.rows.length === 0)
                                return "Asking the site…";

                            return root.theLens.rows.length > 0 ? `${root.theLens.rows.length} videos` : "";
                        }
                    }

                }

                MaterialTextField {
                    id: searchBox

                    Layout.preferredWidth: 260
                    visible: root.theLens.screen === "browse"
                    placeholder: `Search ${root.theLens.feedRef.siteLabel(root.theLens.site)}`
                    text: root.theLens.searchText
                    onAccepted: (typed) => {
                        return root.theLens.search(typed);
                    }
                }

                IconButton {
                    icon: "search"
                    visible: root.theLens.screen === "browse"
                    tooltip: "Search this site"
                    onClicked: root.theLens.search(searchBox.text)
                }

            }

        }

        // ── the site switcher ────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 44
            visible: root.theLens.screen === "browse"
            color: "transparent"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 6

                Repeater {
                    model: root.theLens.feedRef.sites

                    delegate: RippleButton {
                        required property var modelData

                        implicitHeight: 30
                        implicitWidth: siteLabel.implicitWidth + 26
                        toggled: root.theLens.site === modelData.id
                        colBackground: Appearance.colors.colLayer1
                        onClicked: root.theLens.chooseSite(modelData.id)

                        StyledText {
                            id: siteLabel

                            anchors.centerIn: parent
                            text: modelData.label
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            font.weight: Font.Medium
                            color: root.theLens.site === modelData.id ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer1
                        }

                    }

                }

                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 18
                    color: Appearance.colors.colOutlineVariant
                }

                Repeater {
                    model: root.theLens.feedRef.modeLabel ? ["featured", "new", "views"] : []

                    delegate: RippleButton {
                        required property var modelData

                        implicitHeight: 30
                        implicitWidth: modeLabel.implicitWidth + 26
                        toggled: root.theLens.mode === modelData
                        onClicked: root.theLens.chooseMode(modelData)

                        StyledText {
                            id: modeLabel

                            anchors.centerIn: parent
                            text: root.theLens.feedRef.modeLabel[modelData] || modelData
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: root.theLens.mode === modelData ? Appearance.colors.colOnLayer1 : Appearance.colors.colSubtext
                        }

                    }

                }

                Item {
                    Layout.fillWidth: true
                }

            }

        }

        // ── the wall, or why there is not one ────────────────────────────────
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            /*
             * A site that could not answer says so IN ITS OWN RIGHT.
             *
             * The daemon reports `skipped` with a reason when a source cannot
             * express the query; drawing that as an empty grid would mean
             * "nothing matched", which is a different and wrong answer.
             */
            PagePlaceholder {
                anchors.centerIn: parent
                width: Math.min(parent.width - 80, 440)
                visible: root.theLens.screen === "browse" && root.theLens.rows.length === 0 && !root.theLens.loading
                icon: root.theLens.skippedText.length > 0 ? "block" : root.theLens.errorText.length > 0 ? "cloud_off" : "search_off"
                title: root.theLens.skippedText.length > 0 ? "This site cannot answer that" : root.theLens.errorText.length > 0 ? "Could not reach the site" : "Nothing here"
                description: root.theLens.skippedText.length > 0 ? root.theLens.skippedText : root.theLens.errorText.length > 0 ? root.theLens.errorText : root.theLens.searchText.length > 0 ? `${root.theLens.feedRef.siteLabel(root.theLens.site)} has nothing for “${root.theLens.searchText}”` : "The site answered with no videos"
            }

            GridView {
                id: grid

                // The cell follows the chosen layout (Lens.layoutCell), so the
                // app's layout button works here like everywhere else; a
                // compact row is a row rather than a tile.
                readonly property bool asList: root.theLens.layout === "compact"

                anchors.fill: parent
                anchors.margins: 12
                visible: root.theLens.screen === "browse" && root.theLens.rows.length > 0
                clip: true
                cellWidth: asList ? width : Math.floor(width / Math.max(1, Math.floor(width / Math.max(120, root.theLens.layoutCell || 300))))
                cellHeight: asList ? 88 : Math.round(cellWidth * 0.62)
                model: root.theLens.rows
                cacheBuffer: cellHeight * 2
                // Near the bottom is where the next page is asked for; the feed
                // refuses a second ask while one is out, so this can be eager.
                onContentYChanged: {
                    if (contentY + height > contentHeight - cellHeight * 2)
                        root.theLens.loadMore();

                }

                delegate: Item {
                    id: cell

                    required property var modelData

                    width: grid.cellWidth
                    height: grid.cellHeight

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 5
                        radius: 17
                        clip: true
                        color: Appearance.colors.colLayer1

                        ThumbImage {
                            anchors.fill: parent
                            // The app's own thumbnail view, not a bare Image: `Catalog.thumbFor`
                            // answers "" until the daemon has fetched the poster and then says so
                            // with a signal, which a plain binding never hears — which is why every
                            // card in this grid was an empty rectangle.
                            item: cell.modelData
                            size: Catalog.tileThumbSize
                            fillMode: Image.PreserveAspectCrop
                        }

                        // The title, over a scrim so it reads on any frame.
                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: 46

                            StyledText {
                                anchors.fill: parent
                                anchors.margins: 8
                                verticalAlignment: Text.AlignBottom
                                elide: Text.ElideRight
                                maximumLineCount: 2
                                wrapMode: Text.WordWrap
                                text: cell.modelData.title || ""
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: "white"
                            }

                            gradient: Gradient {
                                GradientStop {
                                    position: 0
                                    color: "transparent"
                                }

                                GradientStop {
                                    position: 1
                                    color: "#cc000000"
                                }

                            }

                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.theLens.watch(cell.modelData)
                        }

                    }

                }

                footer: Item {
                    width: grid.width
                    height: root.theLens.loading ? 60 : 0

                    LoadingIndicator {
                        anchors.centerIn: parent
                        running: root.theLens.loading
                    }

                }

            }

            // ── watching one ─────────────────────────────────────────────────
            Rectangle {
                anchors.fill: parent
                visible: root.theLens.screen === "watch"
                color: "black"

                MediaPlayer {
                    id: player

                    source: root.theLens.playingUrl
                    videoOutput: surface
                    onSourceChanged: {
                        if (root.theLens.playingUrl.length > 0) {
                            play();
                        }
                    }

                    audioOutput: AudioOutput {
                        id: sound
                    }

                }

                VideoOutput {
                    id: surface

                    anchors.fill: parent
                    anchors.bottomMargin: 56
                    fillMode: VideoOutput.PreserveAspectFit
                }

                // Still resolving, or it could not be resolved. Either way the
                // poster is shown rather than a black rectangle.
                Image {
                    anchors.fill: parent
                    anchors.bottomMargin: 56
                    fillMode: Image.PreserveAspectFit
                    visible: root.theLens.playingUrl.length === 0
                    asynchronous: true
                    // Same reason as the grid: a bare source binding never hears the
                    // daemon say the poster has landed.
                    source: root.theLens.watching ? Catalog.thumbFor(root.theLens.watching, 640) : ""

                    Connections {
                        function onThumbReady(id, path) {
                            if (root.theLens.watching && String(id) === String(root.theLens.watching.id))
                                parent.source = path;

                        }

                        target: Catalog
                    }

                }

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: 8
                    visible: root.theLens.playingUrl.length === 0

                    LoadingIndicator {
                        Layout.alignment: Qt.AlignHCenter
                        visible: root.theLens.resolving
                        running: root.theLens.resolving
                    }

                    StyledText {
                        Layout.alignment: Qt.AlignHCenter
                        text: root.theLens.resolving ? "Finding the video on its page…" : root.theLens.watchError.length > 0 ? root.theLens.watchError : root.theLens.streamError.length > 0 ? root.theLens.streamError : root.theLens.chosenUrl.length > 0 && root.theLens.playingUrl.length === 0 ? "Opening the stream through quarryd…" : ""
                        color: "white"
                        font.pixelSize: Appearance.font.pixelSize.small
                    }

                }

                // The qualities the daemon actually resolved — never a guess.
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 56
                    color: Appearance.colors.colLayer0Base

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 8

                        IconButton {
                            icon: "arrow_back"
                            tooltip: "Back to the wall"
                            onClicked: root.theLens.stopWatching()
                        }

                        IconButton {
                            icon: player.playbackState === MediaPlayer.PlayingState ? "pause" : "play_arrow"
                            tooltip: player.playbackState === MediaPlayer.PlayingState ? "Pause" : "Play"
                            enabled: root.theLens.playingUrl.length > 0
                            onClicked: player.playbackState === MediaPlayer.PlayingState ? player.pause() : player.play()
                        }

                        IconButton {
                            icon: "skip_previous"
                            tooltip: "The one before"
                            onClicked: root.theLens.watchNeighbour(-1)
                        }

                        IconButton {
                            icon: "skip_next"
                            tooltip: "The next one"
                            onClicked: root.theLens.watchNeighbour(1)
                        }

                        StyledText {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            text: root.theLens.watching ? (root.theLens.watching.title || "") : ""
                            color: Appearance.colors.colOnLayer0
                            font.pixelSize: Appearance.font.pixelSize.smaller
                        }

                        Repeater {
                            model: root.theLens.qualities

                            delegate: RippleButton {
                                required property var modelData
                                required property int index

                                implicitHeight: 28
                                implicitWidth: qLabel.implicitWidth + 20
                                toggled: root.theLens.quality === index
                                colBackground: Appearance.colors.colLayer1
                                onClicked: root.theLens.chooseQuality(index)

                                StyledText {
                                    id: qLabel

                                    anchors.centerIn: parent
                                    text: modelData.label || "?"
                                    font.pixelSize: Appearance.font.pixelSize.smallest
                                    color: root.theLens.quality === index ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer1
                                }

                            }

                        }

                    }

                }

            }

        }

    }

}
