import qs.modules.common
import qs.modules.gallery
import qs.modules.widgets
import qs.services
import QtQuick
import QtQuick.Layouts
import QtMultimedia

/*
 * THE WATCH SCREEN, WRITTEN ONCE.
 *
 * It lives beside the skins rather than above them because QML resolves a
 * neighbouring component by directory: a skin can use `Watch` only if it is in
 * the skin's own folder. It is not a skin itself — the manifest never names it.
 *
 * Both skins need the same player: the same resolve-then-play, the same
 * scrubber that does not fight the drag, the same strip of what is next. Only
 * the colours differ, so only the colours are parameters — a second copy of a
 * player is a second place for the seek logic to be subtly wrong.
 *
 * The timeline is the app's own `StyledSlider`, bound the way the viewer binds
 * it: the value is suspended while held, the seek is issued on release, and the
 * handle glides at the speed the video is actually playing instead of jumping
 * once a second when the player deigns to report a position.
 */
Item {
    id: root

    required property var lens
    /// The palette, so a skin can hand over its own without owning a player.
    property color ground: "black"
    property color accent: Appearance.colors.colPrimary
    property color onAccent: Appearance.colors.colOnPrimary
    property color panel: Appearance.colors.colLayer0Base
    property color ink: "#ffffff"
    property color inkDim: "#b0ffffff"

    readonly property bool playing: player.playbackState === MediaPlayer.PlayingState

    /*
     * WHAT IS NEXT, PULLED UP OVER THE PICTURE.
     *
     * A single row of six is what fits under a player, and it is not enough to
     * choose from — but a permanent grid would take the picture's place. So the
     * strip is a drawer: scroll up over it, drag its handle, or press the
     * chevron, and it grows into a wall of what is next; push it back down and
     * the picture has the screen again. The same gesture people already use on
     * the phone version of every one of these sites.
     */
    property bool nextOpen: false
    readonly property int stripClosed: 116
    readonly property int stripOpen: Math.round(root.height * 0.62)

    function clock(ms) {
        if (!(ms > 0))
            return "0:00";
        const total = Math.floor(ms / 1000);
        const hours = Math.floor(total / 3600);
        const minutes = Math.floor((total % 3600) / 60);
        const seconds = total % 60;
        const mm = hours > 0 && minutes < 10 ? `0${minutes}` : String(minutes);
        const ss = seconds < 10 ? `0${seconds}` : String(seconds);
        return hours > 0 ? `${hours}:${mm}:${ss}` : `${mm}:${ss}`;
    }

    MediaPlayer {
        id: player
        source: root.lens.playingUrl
        videoOutput: surface
        audioOutput: AudioOutput {
            id: sound
            muted: !Prefs.videoSound
            volume: Prefs.videoVolume
        }
        // A new url is a new video: nobody opens one to press play.
        onSourceChanged: if (root.lens.playingUrl.length > 0)
            play()
        // The site's feeds are what is next, and the lens knows the order.
        onMediaStatusChanged: if (mediaStatus === MediaPlayer.EndOfMedia)
            root.lens.watchNeighbour(1)
    }

    Rectangle {
        anchors.fill: parent
        color: root.ground
    }

    VideoOutput {
        id: surface
        anchors.fill: parent
        anchors.bottomMargin: bar.height + upNext.height + facts.height
        fillMode: VideoOutput.PreserveAspectFit
    }

    // Until there is a file, the poster stands in — a black rectangle says
    // nothing, and the row already carries a picture of what you chose.
    Image {
        anchors.fill: surface
        fillMode: Image.PreserveAspectFit
        visible: root.lens.playingUrl.length === 0
        asynchronous: true
        // Same reason as the grid: a bare source binding never hears the
        // daemon say the poster has landed.
        source: root.lens.watching ? Catalog.thumbFor(root.lens.watching, 640) : ""
        Connections {
            function onThumbReady(id, path) {
                if (root.lens.watching && String(id) === String(root.lens.watching.id))
                    parent.source = path;
            }
            target: Catalog
        }
        opacity: 0.55
    }

    ColumnLayout {
        anchors.centerIn: surface
        spacing: 10
        visible: root.lens.playingUrl.length === 0

        LoadingIndicator {
            Layout.alignment: Qt.AlignHCenter
            visible: root.lens.resolving
            running: root.lens.resolving
        }
        StyledText {
            Layout.alignment: Qt.AlignHCenter
            horizontalAlignment: Text.AlignHCenter
            width: Math.min(root.width - 80, 520)
            wrapMode: Text.WordWrap
            text: root.lens.resolving ? "Finding the video on its page…" : root.lens.watchError.length > 0 ? root.lens.watchError : root.lens.streamError.length > 0 ? root.lens.streamError : root.lens.chosenUrl.length > 0 ? "Opening the stream through quarryd…" : ""
            color: root.ink
            font.pixelSize: Appearance.font.pixelSize.small
        }
    }

    // Click the picture to pause, as every player has since players existed.
    TapHandler {
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onTapped: root.playing ? player.pause() : player.play()
    }

    /*
     * WHO IS IN IT, WHAT IT IS FILED UNDER, AND HOW IT DID.
     *
     * The strip above the player carries what the video's own page shows and a
     * catalogue row cannot: the performers (press one and you are looking at
     * their videos), the categories it belongs to (press one and you are in
     * that category), and the two numbers the site puts under its player.
     */
    Rectangle {
        id: facts
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: upNext.top
        height: visible ? Math.min(74, factRow.implicitHeight + 16) : 0
        visible: root.lens.detail !== null
        color: root.panel

        Flickable {
            anchors.fill: parent
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            anchors.topMargin: 8
            contentWidth: factRow.implicitWidth
            flickableDirection: Flickable.HorizontalFlick
            clip: true

            RowLayout {
                id: factRow
                height: parent.height
                spacing: 6

                StyledText {
                    visible: text.length > 0
                    text: {
                        const detail = root.lens.detail;
                        if (!detail)
                            return "";
                        const bits = [];
                        if (detail.views)
                            bits.push(`${Number(detail.views).toLocaleString(Qt.locale(), "f", 0)} views`);
                        if (detail.rating)
                            bits.push(`${Math.round(Number(detail.rating))}%`);
                        return bits.join("  ·  ");
                    }
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: root.inkDim
                }

                Repeater {
                    model: root.lens.detailStars

                    delegate: RippleButton {
                        required property var modelData
                        implicitHeight: 26
                        implicitWidth: starChip.implicitWidth + 26
                        colBackground: "#22ffffff"
                        onClicked: root.lens.openStar(modelData)

                        RowLayout {
                            anchors.centerIn: parent
                            spacing: 4
                            MaterialSymbol {
                                text: "person"
                                iconSize: 14
                                color: root.accent
                            }
                            StyledText {
                                id: starChip
                                text: parent.parent.modelData
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                color: root.ink
                            }
                        }
                    }
                }

                Repeater {
                    model: root.lens.detailCategories

                    delegate: RippleButton {
                        required property var modelData
                        implicitHeight: 26
                        implicitWidth: catChip.implicitWidth + 22
                        colBackground: "#18ffffff"
                        onClicked: root.lens.chooseCategory(modelData)

                        StyledText {
                            id: catChip
                            anchors.centerIn: parent
                            text: parent.modelData
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            color: root.inkDim
                        }
                    }
                }
            }
        }
    }

    // ── what is next, along the bottom ───────────────────────────────────────
    Rectangle {
        id: upNext
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: bar.top
        height: strip.count > 0 ? (root.nextOpen ? root.stripOpen : root.stripClosed) : 0
        visible: height > 0
        color: root.panel

        Behavior on height {
            NumberAnimation {
                duration: Appearance.animDur(220)
                easing.type: Easing.OutCubic
            }
        }

        // The handle: something to aim at, and something that says the drawer
        // is a drawer before anybody has tried to drag it.
        Item {
            id: handle
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 18

            Rectangle {
                anchors.centerIn: parent
                width: 44
                height: 4
                radius: 2
                color: root.inkDim
                opacity: handleHover.hovered ? 0.9 : 0.45
            }

            MaterialSymbol {
                anchors.right: parent.right
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                text: root.nextOpen ? "expand_more" : "expand_less"
                iconSize: 16
                color: root.inkDim
            }

            HoverHandler {
                id: handleHover
                cursorShape: Qt.SizeVerCursor
            }

            TapHandler {
                gesturePolicy: TapHandler.ReleaseWithinBounds
                onTapped: root.nextOpen = !root.nextOpen
            }

            // Dragged rather than tapped: past a third of the way and it stays
            // where you threw it, which is what a drawer does everywhere else.
            DragHandler {
                id: pull
                target: null
                yAxis.enabled: true
                xAxis.enabled: false
                onActiveChanged: {
                    if (pull.active)
                        return;
                    const moved = pull.centroid.position.y - pull.centroid.pressPosition.y;
                    if (moved < -30)
                        root.nextOpen = true;
                    else if (moved > 30)
                        root.nextOpen = false;
                }
            }

            // A wheel over the strip opens it too: on a desktop that is the
            // same intention as the swipe.
            WheelHandler {
                onWheel: event => {
                    if (event.angleDelta.y < 0)
                        root.nextOpen = true;
                    else if (event.angleDelta.y > 0 && strip.contentY <= 0)
                        root.nextOpen = false;
                }
            }
        }

        GridView {
            id: strip
            anchors.fill: parent
            anchors.topMargin: 22
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            anchors.bottomMargin: 8
            // Closed it is one row that scrolls sideways; open it is a wall
            // that scrolls down. One view, two shapes, so nothing is rebuilt
            // when it opens.
            flow: root.nextOpen ? GridView.FlowLeftToRight : GridView.FlowTopToBottom
            cellWidth: 178
            cellHeight: root.nextOpen ? 122 : height
            clip: true
            // Recomputed when the feed grows, so a strip that ran short fills
            // itself in rather than staying short for the rest of the video.
            // Six fit in the closed strip; the open wall is worth filling.
            model: root.lens.rows.length >= 0 ? root.lens.neighbours(root.nextOpen ? 40 : 12) : []

            delegate: Item {
                required property var modelData
                width: 170
                height: root.nextOpen ? 114 : strip.height

                Rectangle {
                    anchors.fill: parent
                    radius: 10
                    clip: true
                    color: "#1a1a1a"

                    ThumbImage {
                        anchors.fill: parent
                        // The app's own thumbnail view, not a bare Image: `Catalog.thumbFor`
                        // answers "" until the daemon has fetched the poster and then says so
                        // with a signal, which a plain binding never hears — which is why every
                        // card in this grid was an empty rectangle.
                        item: parent.parent.modelData
                        size: 320
                        fillMode: Image.PreserveAspectCrop
                        }

                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 34
                        gradient: Gradient {
                            GradientStop {
                                position: 0
                                color: "transparent"
                            }
                            GradientStop {
                                position: 1
                                color: "#d0000000"
                            }
                        }
                        StyledText {
                            anchors.fill: parent
                            anchors.margins: 6
                            verticalAlignment: Text.AlignBottom
                            elide: Text.ElideRight
                            text: parent.parent.parent.modelData.title || ""
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            color: "white"
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.lens.watch(parent.parent.modelData)
                    }
                }
            }
        }
    }

    // ── the controls ─────────────────────────────────────────────────────────
    Rectangle {
        id: bar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 92
        color: root.panel

        ColumnLayout {
            anchors.fill: parent
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            anchors.topMargin: 8
            anchors.bottomMargin: 6
            spacing: 2

            // The timeline gets a row of its own, at the width of the bar —
            // the same lesson as the viewer's own player.
            RowLayout {
                Layout.fillWidth: true
                spacing: 12

                StyledText {
                    Layout.minimumWidth: 52
                    horizontalAlignment: Text.AlignRight
                    text: root.clock(scrubber.held ? scrubber.value : player.position)
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: scrubber.held ? root.accent : root.ink
                }

                StyledSlider {
                    id: scrubber
                    Layout.fillWidth: true
                    configuration: StyledSlider.Configuration.S
                    highlightColor: root.accent
                    handleColor: root.accent
                    enabled: player.seekable
                    from: 0
                    to: Math.max(1, player.duration)
                    readout: root.clock(scrubber.value)
                    buffered: player.duration > 0 ? player.bufferProgress : -1
                    // Value units are milliseconds of video, so one second of
                    // video per second of real time is a velocity of 1000.
                    smoothValue: true
                    // A stopped picture must not have a moving handle: see smoothPaused.
                    smoothPaused: !root.playing
                    smoothVelocity: 1000

                    onPressedChanged: {
                        if (pressed)
                            return;
                        // Read the drop point before the binding restores the
                        // playhead over it — see the viewer's own scrubber.
                        player.position = scrubber.value;
                    }

                    Binding {
                        target: scrubber
                        property: "value"
                        value: player.position
                        when: !scrubber.held
                        restoreMode: Binding.RestoreNone
                    }
                }

                StyledText {
                    Layout.minimumWidth: 52
                    text: player.duration > 0 ? root.clock(player.duration) : "--:--"
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: root.inkDim
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 2

                IconButton {
                    icon: "arrow_back"
                    tooltip: "Back to the grid"
                    size: 36
                    onClicked: root.lens.stopWatching()
                }
                IconButton {
                    icon: root.playing ? "pause" : "play_arrow"
                    tooltip: root.playing ? "Pause" : "Play"
                    size: 40
                    iconSize: Appearance.font.pixelSize.huge
                    enabled: root.lens.playingUrl.length > 0
                    onClicked: root.playing ? player.pause() : player.play()
                }
                IconButton {
                    icon: "open_in_new"
                    tooltip: root.lens.ownWindow ? "Videos open in their own window" : "Move this to its own window"
                    size: 36
                    toggled: root.lens.ownWindow
                    onClicked: {
                        // One press moves this video; it also turns the
                        // preference on, because somebody who asks once
                        // usually means it.
                        root.lens.setOwnWindow(true);
                        root.lens.openInWindow(root.lens.watching);
                    }
                }
                IconButton {
                    icon: "skip_previous"
                    tooltip: "The one before"
                    size: 36
                    onClicked: root.lens.watchNeighbour(-1)
                }
                IconButton {
                    icon: "skip_next"
                    tooltip: "The next one"
                    size: 36
                    onClicked: root.lens.watchNeighbour(1)
                }
                IconButton {
                    icon: Prefs.videoSound ? (Prefs.videoVolume > 0.5 ? "volume_up" : "volume_down") : "volume_off"
                    tooltip: Prefs.videoSound ? "Mute" : "Unmute"
                    size: 36
                    onClicked: Prefs.videoSound = !Prefs.videoSound
                }
                StyledSlider {
                    Layout.preferredWidth: 86
                    configuration: StyledSlider.Configuration.XS
                    highlightColor: root.accent
                    handleColor: root.accent
                    from: 0
                    to: 1
                    value: Prefs.videoVolume
                    readout: `${Math.round(value * 100)}%`
                    onMoved: {
                        Prefs.videoVolume = value;
                        Prefs.videoSound = true;
                    }
                }

                Item {
                    Layout.fillWidth: true
                    Layout.minimumWidth: 12
                }

                // The qualities the daemon actually resolved — never a guess.
                Repeater {
                    model: root.lens.qualities
                    delegate: RippleButton {
                        required property var modelData
                        required property int index
                        implicitHeight: 28
                        implicitWidth: qualityLabel.implicitWidth + 20
                        toggled: root.lens.quality === index
                        colBackground: "#22ffffff"
                        colBackgroundToggled: root.accent
                        onClicked: root.lens.chooseQuality(index)

                        StyledText {
                            id: qualityLabel
                            anchors.centerIn: parent
                            text: modelData.label || "?"
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            color: root.lens.quality === index ? root.onAccent : root.ink
                        }
                    }
                }
            }
        }
    }
}
