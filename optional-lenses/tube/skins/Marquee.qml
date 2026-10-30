import qs.modules.common
import qs.modules.lens
import qs.modules.gallery
import qs.modules.widgets
import qs.services
import QtQuick
import QtQuick.Layouts
import QtMultimedia

/*
 * THE DARK SKIN — the shape these sites actually are.
 *
 * Black ground, amber accent, bigger posters and a duration badge, because
 * that is what a tube site's grid is for: deciding from the thumbnail. It
 * deliberately does not use Appearance's surfaces — a skin is allowed to look
 * nothing like the rest of quarry, which is the point of having two.
 *
 * Same lens underneath, so switching to it mid-video lands on the same video.
 */
LensSkin {
    id: root

    ground: "#0b0b0d"
    readonly property var theLens: root.lens

    readonly property color accent: "#ffa31a"
    readonly property color dim: "#8a8a92"

    function clock(seconds) {
        const total = Math.max(0, Math.round(seconds || 0));
        if (total <= 0)
            return "";
        const m = Math.floor(total / 60);
        const s = total % 60;
        return `${m}:${s < 10 ? "0" : ""}${s}`;
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── the bar ──────────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 52
            color: "#141418"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                spacing: 6

                IconButton {
                    icon: "arrow_back"
                    iconColor: "white"
                    tooltip: root.theLens.canGoBack ? "Back" : "Close the lens"
                    onClicked: root.theLens.canGoBack ? root.theLens.goBack() : Lenses.close()
                }

                // The sites, as tabs — this is the site switcher being the
                // primary navigation rather than a row of chips under a title.
                Repeater {
                    model: root.theLens.feedRef.sites
                    delegate: Rectangle {
                        required property var modelData
                        implicitHeight: 34
                        implicitWidth: tabText.implicitWidth + 24
                        radius: 6
                        color: root.theLens.site === modelData.id ? root.accent : "transparent"
                        StyledText {
                            id: tabText
                            anchors.centerIn: parent
                            text: modelData.label
                            font.pixelSize: Appearance.font.pixelSize.small
                            font.weight: Font.Bold
                            color: root.theLens.site === modelData.id ? "#141418" : "white"
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.theLens.chooseSite(modelData.id)
                        }
                    }
                }

                Item {
                    Layout.fillWidth: true
                }

                MaterialTextField {
                    id: box
                    Layout.preferredWidth: 240
                    visible: root.theLens.screen === "browse"
                    placeholder: "Search this site"
                    text: root.theLens.searchText
                    onAccepted: typed => root.theLens.search(typed)
                }
            }
        }

        // ── orderings ────────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 38
            visible: root.theLens.screen === "browse"
            color: "#0b0b0d"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 14
                spacing: 18

                Repeater {
                    model: ["featured", "new", "views"]
                    delegate: StyledText {
                        required property var modelData
                        text: (root.theLens.feedRef.modeLabel[modelData] || modelData).toUpperCase()
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        font.weight: root.theLens.mode === modelData ? Font.Bold : Font.Normal
                        color: root.theLens.mode === modelData ? root.accent : root.dim
                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -6
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.theLens.chooseMode(modelData)
                        }
                    }
                }

                Item {
                    Layout.fillWidth: true
                }

                StyledText {
                    Layout.rightMargin: 14
                    text: root.theLens.loading ? "loading…" : (root.theLens.rows.length > 0 ? `${root.theLens.rows.length}` : "")
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: root.dim
                }
            }
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            // Same honesty as the default skin: a site that could not answer
            // says what it could not do, rather than showing an empty grid.
            ColumnLayout {
                anchors.centerIn: parent
                width: Math.min(parent.width - 60, 420)
                spacing: 6
                visible: root.theLens.screen === "browse" && root.theLens.rows.length === 0 && !root.theLens.loading

                StyledText {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: root.theLens.skippedText.length > 0 ? "This site cannot answer that"
                        : root.theLens.errorText.length > 0 ? "Could not reach the site" : "Nothing here"
                    font.pixelSize: Appearance.font.pixelSize.large
                    font.weight: Font.Bold
                    color: "white"
                }
                StyledText {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: root.theLens.skippedText.length > 0 ? root.theLens.skippedText
                        : root.theLens.errorText.length > 0 ? root.theLens.errorText
                        : "The site answered with no videos"
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: root.dim
                }
            }

            GridView {
                id: wall
                anchors.fill: parent
                anchors.margins: 8
                visible: root.theLens.screen === "browse" && root.theLens.rows.length > 0
                clip: true
                cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 340)))
                cellHeight: Math.round(cellWidth * 0.64)
                model: root.theLens.rows
                cacheBuffer: cellHeight * 2
                onContentYChanged: {
                    if (contentY + height > contentHeight - cellHeight * 2)
                        root.theLens.loadMore();
                }

                delegate: Item {
                    id: tile
                    required property var modelData
                    width: wall.cellWidth
                    height: wall.cellHeight

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 4
                        radius: 4
                        clip: true
                        color: "#17171c"
                        border.width: hover.hovered ? 2 : 0
                        border.color: root.accent

                        ThumbImage {
                            anchors.fill: parent
                            // The app's own thumbnail view, not a bare Image: `Catalog.thumbFor`
                            // answers "" until the daemon has fetched the poster and then says so
                            // with a signal, which a plain binding never hears — which is why every
                            // card in this grid was an empty rectangle.
                            item: tile.modelData
                            size: Catalog.tileThumbSize
                            fillMode: Image.PreserveAspectCrop
                            }

                        Rectangle {
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            anchors.margins: 6
                            visible: badge.text.length > 0
                            width: badge.implicitWidth + 10
                            height: badge.implicitHeight + 4
                            radius: 3
                            color: "#cc000000"
                            StyledText {
                                id: badge
                                anchors.centerIn: parent
                                text: root.clock(tile.modelData.duration)
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                color: "white"
                            }
                        }

                        StyledText {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            anchors.margins: 6
                            anchors.rightMargin: 60
                            elide: Text.ElideRight
                            maximumLineCount: 2
                            wrapMode: Text.WordWrap
                            text: tile.modelData.title || ""
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: "white"
                            style: Text.Outline
                            styleColor: "#000000"
                        }

                        HoverHandler {
                            id: hover
                        }
                        TapHandler {
                            onTapped: root.theLens.watch(tile.modelData)
                        }
                    }
                }
            }

            // ── the player ───────────────────────────────────────────────────
            Rectangle {
                anchors.fill: parent
                visible: root.theLens.screen === "watch"
                color: "black"

                MediaPlayer {
                    id: film
                    source: root.theLens.playingUrl
                    audioOutput: AudioOutput {}
                    videoOutput: screen
                    onSourceChanged: if (root.theLens.playingUrl.length > 0)
                        play()
                }

                VideoOutput {
                    id: screen
                    anchors.fill: parent
                    anchors.bottomMargin: 50
                    fillMode: VideoOutput.PreserveAspectFit
                }

                Image {
                    anchors.fill: parent
                    anchors.bottomMargin: 50
                    fillMode: Image.PreserveAspectFit
                    visible: root.theLens.playingUrl.length === 0
                    asynchronous: true
                    opacity: 0.5
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

                StyledText {
                    anchors.centerIn: parent
                    visible: root.theLens.playingUrl.length === 0
                    text: root.theLens.resolving ? "Finding the video on its page…" : root.theLens.watchError.length > 0 ? root.theLens.watchError : root.theLens.streamError.length > 0 ? root.theLens.streamError : root.theLens.chosenUrl.length > 0 && root.theLens.playingUrl.length === 0 ? "Opening the stream through quarryd…" : ""
                    color: "white"
                    font.pixelSize: Appearance.font.pixelSize.small
                }

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 50
                    color: "#141418"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 12
                        spacing: 6

                        IconButton {
                            icon: "arrow_back"
                            iconColor: "white"
                            onClicked: root.theLens.stopWatching()
                        }
                        IconButton {
                            icon: film.playbackState === MediaPlayer.PlayingState ? "pause" : "play_arrow"
                            iconColor: "white"
                            enabled: root.theLens.playingUrl.length > 0
                            onClicked: film.playbackState === MediaPlayer.PlayingState ? film.pause() : film.play()
                        }
                        IconButton {
                            icon: "skip_next"
                            iconColor: "white"
                            tooltip: "The next one"
                            onClicked: root.theLens.watchNeighbour(1)
                        }

                        StyledText {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            text: root.theLens.watching ? (root.theLens.watching.title || "") : ""
                            color: "white"
                            font.pixelSize: Appearance.font.pixelSize.smaller
                        }

                        Repeater {
                            model: root.theLens.qualities
                            delegate: StyledText {
                                required property var modelData
                                required property int index
                                text: modelData.label || "?"
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                font.weight: root.theLens.quality === index ? Font.Bold : Font.Normal
                                color: root.theLens.quality === index ? root.accent : root.dim
                                MouseArea {
                                    anchors.fill: parent
                                    anchors.margins: -5
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.theLens.chooseQuality(index)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
