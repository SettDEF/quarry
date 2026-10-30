import QtQuick
import QtQuick.Layouts
import qs.modules.common
import qs.modules.gallery
import qs.modules.lens
import qs.modules.widgets
import qs.services

/*
 * THE SITE'S OWN SHAPE — black ground, orange on the things you press.
 *
 * Not a theme for its own sake: a video site is browsed by picture, and a dark
 * ground is what lets thirty posters sit next to each other without the page
 * competing with them. The orange is the site's, so the lens reads as the place
 * it is showing rather than as a panel in a file manager.
 *
 * Holds scroll position and nothing else. Where you are, what has been fetched
 * and what is playing all belong to the lens, which is what lets you change
 * skin mid-video and land on the same second.
 */
LensSkin {
    id: root

    readonly property var theLens: root.lens
    readonly property color amber: "#ff9000"
    readonly property color ink: "#f2f2f2"
    readonly property color dim: "#9a9a9a"
    readonly property color card: "#161616"

    ground: "#0b0b0b"

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── chrome ───────────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 50
            color: "#101010"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 10

                IconButton {
                    icon: "arrow_back"
                    tooltip: root.theLens.canGoBack ? "Back" : "Close the lens"
                    iconColor: root.ink
                    onClicked: root.theLens.canGoBack ? root.theLens.goBack() : Lenses.close()
                }

                // The site's wordmark, in the site's two colours. It is a lens
                // on one site; saying which one is not decoration.
                RowLayout {
                    spacing: 0

                    StyledText {
                        text: "porn"
                        font.pixelSize: Appearance.font.pixelSize.normal
                        font.weight: Font.Bold
                        color: root.ink
                    }

                    Rectangle {
                        Layout.preferredWidth: hubText.implicitWidth + 10
                        Layout.preferredHeight: 20
                        radius: 4
                        color: root.amber

                        StyledText {
                            id: hubText

                            anchors.centerIn: parent
                            text: "hub"
                            font.pixelSize: Appearance.font.pixelSize.normal
                            font.weight: Font.Bold
                            color: "#000000"
                        }

                    }

                }

                /*
                 * One line, not two.
                 *
                 * The place and the count were stacked, which cost a row of
                 * chrome to say four words. Beside each other they read the
                 * same and give the pictures the height back.
                 */
                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 6
                    spacing: 8

                    StyledText {
                        elide: Text.ElideRight
                        Layout.maximumWidth: 340
                        text: root.theLens.screenTitle
                        font.pixelSize: Appearance.font.pixelSize.normal
                        font.weight: Font.DemiBold
                        color: root.ink
                    }

                    StyledText {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        visible: text.length > 0
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: root.theLens.errorText.length > 0 || root.theLens.skippedText.length > 0 ? "#ff6b6b" : root.dim
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

                /*
                 * THE TWO DROPDOWNS THE SITE HAS.
                 *
                 * A row of chips can hold three orderings and a dozen
                 * categories before it runs off the edge — which is what it was
                 * doing. The site puts both behind menus, and so does this: the
                 * ordering menu carries the periods (most viewed this week, top
                 * rated this month) that the chips could not express at all, and
                 * the category menu carries all thirty-six rather than the
                 * fifteen that happened to fit.
                 */
                RippleButton {
                    implicitHeight: 32
                    implicitWidth: sortLabel.implicitWidth + 40
                    colBackground: "#1d1d1d"
                    onClicked: sortMenu.visible ? sortMenu.close() : sortMenu.open()

                    RowLayout {
                        anchors.centerIn: parent
                        spacing: 4

                        StyledText {
                            id: sortLabel

                            text: root.theLens.modeLabel(root.theLens.mode)
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: root.ink
                        }

                        MaterialSymbol {
                            text: "expand_more"
                            iconSize: 16
                            color: root.dim
                        }

                    }

                    MenuPopup {
                        id: sortMenu

                        y: parent.height + 6
                        minWidth: 240

                        Repeater {
                            model: root.theLens.modes

                            delegate: MenuRow {
                                required property var modelData

                                text: modelData.label
                                icon: modelData.icon
                                hint: modelData.group
                                checked: root.theLens.mode === modelData.id
                                onTriggered: {
                                    sortMenu.close();
                                    root.theLens.chooseMode(modelData.id);
                                }
                            }

                        }

                    }

                }

                RippleButton {
                    implicitHeight: 32
                    implicitWidth: catLabel.implicitWidth + 40
                    colBackground: "#1d1d1d"
                    onClicked: catMenu.visible ? catMenu.close() : catMenu.open()

                    RowLayout {
                        anchors.centerIn: parent
                        spacing: 4

                        StyledText {
                            id: catLabel

                            text: root.theLens.category.length > 0 ? root.theLens.category : `Categories · ${root.theLens.categories.length}`
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: root.theLens.category.length > 0 ? root.amber : root.ink
                        }

                        MaterialSymbol {
                            text: "expand_more"
                            iconSize: 16
                            color: root.dim
                        }

                    }

                    MenuPopup {
                        id: catMenu

                        y: parent.height + 6
                        minWidth: 230

                        MenuRow {
                            text: "Everything"
                            icon: "apps"
                            checked: root.theLens.category.length === 0
                            onTriggered: {
                                catMenu.close();
                                root.theLens.chooseCategory("");
                            }
                        }

                        MenuRow {
                            separator: true
                        }

                        Repeater {
                            model: root.theLens.categories

                            delegate: MenuRow {
                                required property var modelData

                                text: modelData
                                icon: "label"
                                checked: root.theLens.category === modelData
                                onTriggered: {
                                    catMenu.close();
                                    root.theLens.chooseCategory(modelData);
                                }
                            }

                        }

                    }

                }

                // The site's own search, not quarry's: it asks this site for
                // these words, inside whatever category is open.
                MaterialTextField {
                    id: searchField

                    Layout.preferredWidth: 260
                    placeholder: root.theLens.category.length > 0 ? `Search in ${root.theLens.category}` : "Search Pornhub"
                    text: root.theLens.searchText
                    onAccepted: root.theLens.search(text)
                }

                IconButton {
                    icon: "shuffle"
                    tooltip: "Show me different ones"
                    iconColor: root.ink
                    onClicked: root.theLens.shuffle()
                }

                IconButton {
                    icon: "public"
                    tooltip: "Open the real site here"
                    iconColor: root.ink
                    // Everything the API does not carry — the comments, the
                    // pornstar pages, a playlist — is one click away rather
                    // than absent.
                    onClicked: root.theLens.showSite()
                }

            }

        }

        /*
         * ONE STRIP, NOT TWO — the pictures are what the window is for.
         *
         * Orientation had a row, the categories had a row, and the count had a
         * label of its own: three bands of chrome, nearly two hundred pixels,
         * before the first poster. They are one scrolling strip now, with the
         * orientation pinned at the left because it is the question you answer
         * once and the categories running past it because that is the one you
         * change constantly. The count moved into the Categories dropdown's
         * hint, where it is read when it matters and takes no space when it
         * does not.
         */
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 38
            visible: root.theLens.screen === "browse"
            color: "#0e0e0e"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 8

                Repeater {
                    model: root.theLens.orientations

                    delegate: Rectangle {
                        id: orientChip

                        required property var modelData
                        readonly property bool here: root.theLens.orientation === orientChip.modelData.id

                        implicitHeight: 26
                        implicitWidth: orientLabel.implicitWidth + 38
                        radius: 13
                        // One rectangle owning both colours: a label painted
                        // black over a pill that had not gone amber was the
                        // one word on the screen nobody could read.
                        color: orientChip.here ? root.amber : chipHover.hovered ? "#2c2c2c" : "#232323"

                        RowLayout {
                            anchors.centerIn: parent
                            spacing: 5

                            MaterialSymbol {
                                text: orientChip.modelData.icon
                                iconSize: 13
                                color: orientChip.here ? "#000000" : root.dim
                            }

                            StyledText {
                                id: orientLabel

                                text: orientChip.modelData.label
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                font.weight: Font.Medium
                                color: orientChip.here ? "#000000" : root.ink
                            }

                        }

                        HoverHandler {
                            id: chipHover

                            cursorShape: Qt.PointingHandCursor
                        }

                        TapHandler {
                            gesturePolicy: TapHandler.ReleaseWithinBounds
                            onTapped: root.theLens.chooseOrientation(orientChip.modelData.id)
                        }

                    }

                }

                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 18
                    color: "#2a2a2a"
                }

                ListView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    orientation: ListView.Horizontal
                    spacing: 6
                    clip: true
                    model: [""].concat(root.theLens.categories)

                    delegate: Rectangle {
                        id: catChip

                        required property var modelData
                        readonly property bool here: root.theLens.category === catChip.modelData

                        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                        implicitHeight: 24
                        implicitWidth: chipLabel.implicitWidth + 22
                        radius: 12
                        color: catChip.here ? root.amber : catHover.hovered ? "#262626" : "#1d1d1d"

                        StyledText {
                            id: chipLabel

                            anchors.centerIn: parent
                            text: catChip.modelData.length > 0 ? catChip.modelData : "All"
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            font.weight: Font.Medium
                            color: catChip.here ? "#000000" : root.ink
                        }

                        HoverHandler {
                            id: catHover

                            cursorShape: Qt.PointingHandCursor
                        }

                        TapHandler {
                            gesturePolicy: TapHandler.ReleaseWithinBounds
                            onTapped: root.theLens.chooseCategory(catChip.modelData)
                        }

                    }

                }

            }

        }

        // ── the grid, or why there is not one ────────────────────────────────
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            PagePlaceholder {
                anchors.centerIn: parent
                width: Math.min(parent.width - 80, 440)
                visible: root.theLens.screen === "browse" && root.theLens.rows.length === 0 && !root.theLens.loading
                icon: root.theLens.skippedText.length > 0 ? "block" : root.theLens.errorText.length > 0 ? "cloud_off" : "search_off"
                title: root.theLens.skippedText.length > 0 ? "The site cannot answer that" : root.theLens.errorText.length > 0 ? "Could not reach the site" : "Nothing here"
                description: root.theLens.skippedText.length > 0 ? root.theLens.skippedText : root.theLens.errorText.length > 0 ? root.theLens.errorText : root.theLens.searchText.length > 0 ? `Pornhub has nothing for “${root.theLens.searchText}”` : "The site answered with no videos"
            }

            GridView {
                id: grid

                anchors.fill: parent
                anchors.margins: 10
                visible: root.theLens.screen === "browse" && root.theLens.rows.length > 0
                clip: true
                cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 320)))
                cellHeight: Math.round(cellWidth * 0.66)
                // The ListModel, not the array — see Feed.qml: assigning a new
                // array resets the view to the top, which is the jump.
                model: root.theLens.feedRef.model
                cacheBuffer: cellHeight * 2
                // Near the bottom is where the next page is asked for; the feed
                // refuses a second ask while one is out, so this can be eager.
                onContentYChanged: {
                    if (contentY + height > contentHeight - cellHeight * 2)
                        root.theLens.loadMore();

                }

                delegate: Item {
                    id: cell

                    // A ListModel hands the delegate its roles, so the row
                    // arrives as `row` rather than as `modelData`.
                    required property var row
                    readonly property var modelData: cell.row
                    /// "15:10", from the site's own field — see the manifest's
                    /// `duration_clock`, which reads a clock as a clock.
                    readonly property string length: {
                        const seconds = cell.modelData && cell.modelData.duration ? cell.modelData.duration : 0;
                        if (!(seconds > 0))
                            return "";

                        const minutes = Math.floor(seconds / 60);
                        const rest = Math.floor(seconds % 60);
                        return `${minutes}:${rest < 10 ? "0" : ""}${rest}`;
                    }

                    width: grid.cellWidth
                    height: grid.cellHeight

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 5
                        radius: 8
                        clip: true
                        color: root.card
                        border.width: poster.containsMouse ? 2 : 0
                        border.color: root.amber

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

                        // How long it is, over the poster's corner — every
                        // tube site puts it there and it is the second thing
                        // anybody reads after the picture.
                        Rectangle {
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: 6
                            visible: cell.length.length > 0
                            width: lengthLabel.implicitWidth + 12
                            height: 18
                            radius: 4
                            color: "#cc000000"

                            StyledText {
                                id: lengthLabel

                                anchors.centerIn: parent
                                text: cell.length
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                font.family: Appearance.font.family.monospace
                                color: "#ffffff"
                            }

                        }

                        // A title printed straight onto a photograph is
                        // unreadable half the time and unreadable in a
                        // different half for the next picture, so it gets the
                        // scrim every card in this app has.
                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: 46

                            StyledText {
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                anchors.margins: 8
                                elide: Text.ElideRight
                                maximumLineCount: 2
                                wrapMode: Text.WordWrap
                                text: cell.modelData.title || ""
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                color: poster.containsMouse ? root.amber : "#f2f2f2"
                            }

                            gradient: Gradient {
                                GradientStop {
                                    position: 0
                                    color: "transparent"
                                }

                                GradientStop {
                                    position: 1
                                    color: "#e6000000"
                                }

                            }

                        }

                        MouseArea {
                            id: poster

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

            /*
             * THE CATEGORIES, AS THE SITE'S OWN MENU DRAWS THEM.
             *
             * Orientation down the left, a wall of named cards, and the filters
             * people actually type along the bottom. The card's picture is one
             * quarry already holds for that word — it fills in as you browse,
             * and a card with nothing behind it yet says its name rather than
             * showing a borrowed photograph.
             */
            RowLayout {
                anchors.fill: parent
                anchors.margins: 12
                visible: root.theLens.screen === "categories"
                spacing: 16

                ColumnLayout {
                    // Pinned, not preferred: a Flow inside asked to fill width
                    // and took the wall's half of the screen with it.
                    Layout.preferredWidth: 200
                    Layout.maximumWidth: 200
                    Layout.minimumWidth: 200
                    Layout.fillWidth: false
                    Layout.fillHeight: true
                    Layout.alignment: Qt.AlignTop
                    spacing: 6

                    StyledText {
                        text: "Orientation"
                        font.pixelSize: Appearance.font.pixelSize.larger
                        font.weight: Font.DemiBold
                        color: root.ink
                    }

                    Repeater {
                        model: root.theLens.orientations

                        /*
                         * Painted here rather than toggled.
                         *
                         * The selected one was drawn with black text on the
                         * assumption the pill behind it had gone amber — and
                         * when it had not, the chosen orientation was the one
                         * word on the screen nobody could read. A plain
                         * rectangle owns both colours, so they cannot disagree.
                         */
                        delegate: Rectangle {
                            id: orientPill

                            required property var modelData
                            readonly property bool here: root.theLens.orientation === orientPill.modelData.id

                            Layout.fillWidth: true
                            implicitHeight: 38
                            radius: 8
                            color: orientPill.here ? root.amber : orientHover.hovered ? "#2c2c2c" : "#242424"

                            RowLayout {
                                anchors.left: parent.left
                                anchors.leftMargin: 12
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 8

                                MaterialSymbol {
                                    text: orientPill.modelData.icon
                                    iconSize: 16
                                    color: orientPill.here ? "#000000" : root.dim
                                }

                                StyledText {
                                    text: orientPill.modelData.label
                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                    font.weight: orientPill.here ? Font.DemiBold : Font.Normal
                                    color: orientPill.here ? "#000000" : root.ink
                                }

                            }

                            HoverHandler {
                                id: orientHover

                                cursorShape: Qt.PointingHandCursor
                            }

                            TapHandler {
                                gesturePolicy: TapHandler.ReleaseWithinBounds
                                onTapped: root.theLens.chooseOrientation(orientPill.modelData.id)
                            }

                        }

                    }

                    Item {
                        Layout.preferredHeight: 10
                    }

                    StyledText {
                        text: "Popular filters"
                        font.pixelSize: Appearance.font.pixelSize.small
                        font.weight: Font.DemiBold
                        color: root.ink
                    }

                    Flow {
                        Layout.preferredWidth: 200
                        Layout.maximumWidth: 200
                        spacing: 5

                        Repeater {
                            model: root.theLens.popularFilters

                            delegate: RippleButton {
                                required property var modelData

                                implicitHeight: 24
                                implicitWidth: filterLabel.implicitWidth + 18
                                colBackground: "#242424"
                                onClicked: root.theLens.search(modelData)

                                StyledText {
                                    id: filterLabel

                                    anchors.centerIn: parent
                                    text: parent.modelData
                                    font.pixelSize: Appearance.font.pixelSize.smallest
                                    color: root.dim
                                }

                            }

                        }

                    }

                    Item {
                        Layout.fillHeight: true
                    }

                }

                GridView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumWidth: 200
                    clip: true
                    cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 190)))
                    cellHeight: Math.round(cellWidth * 0.62)
                    model: root.theLens.categories

                    delegate: Item {
                        id: catCell

                        required property var modelData

                        width: GridView.view.cellWidth
                        height: GridView.view.cellHeight

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 4
                            radius: 8
                            clip: true
                            color: root.card
                            border.width: catHover.hovered ? 2 : 0
                            border.color: root.amber

                            // A picture the catalogue already has for this word.
                            // Nothing is fetched to draw this wall.
                            Image {
                                anchors.fill: parent
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                opacity: 0.55
                                // A pure read; the asking is below, where the
                                // cell appearing is what actually knows.
                                source: root.theLens.coverFor(catCell.modelData)
                                // One row for this word the first time a card
                                // appears, and the answer is remembered.
                                Component.onCompleted: root.theLens.requestCover(catCell.modelData)
                            }

                            Rectangle {
                                anchors.fill: parent

                                gradient: Gradient {
                                    GradientStop {
                                        position: 0
                                        color: "#00000000"
                                    }

                                    GradientStop {
                                        position: 1
                                        color: "#cc000000"
                                    }

                                }

                            }

                            // How many videos are behind this word — the
                            // site's own number, read from its own page. Drawn
                            // only when it is known: a card that says nothing
                            // is better than a card that says zero.
                            StyledText {
                                anchors.left: parent.left
                                anchors.bottom: parent.bottom
                                anchors.margins: 8
                                visible: root.theLens.countFor(catCell.modelData) > 0
                                text: {
                                    const n = root.theLens.countFor(catCell.modelData);
                                    return n >= 1000 ? `${Math.round(n / 1000)}k videos` : `${n} videos`;
                                }
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                color: "#d0ffffff"
                            }

                            StyledText {
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: root.theLens.countFor(catCell.modelData) > 0 ? 24 : 8
                                anchors.margins: 8
                                elide: Text.ElideRight
                                text: catCell.modelData
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                font.weight: Font.DemiBold
                                color: catHover.hovered ? root.amber : root.ink
                            }

                            HoverHandler {
                                id: catHover

                                cursorShape: Qt.PointingHandCursor
                            }

                            TapHandler {
                                gesturePolicy: TapHandler.ReleaseWithinBounds
                                onTapped: root.theLens.chooseCategory(catCell.modelData)
                            }

                        }

                    }

                }

            }

            /*
             * THE PERFORMERS, WHICH ARE HALF OF WHAT THIS SITE IS FOR.
             *
             * The API publishes every performer it knows — thousands — so this
             * is a filter box over a wall of names rather than a list you scroll
             * for a minute. Picking one searches for them, because the site's
             * own search is what has their videos.
             */
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 12
                visible: root.theLens.screen === "stars"
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    MaterialTextField {
                        Layout.fillWidth: true
                        placeholder: "Find a performer"
                        onEdited: (text) => {
                            return root.theLens.starFilter = text;
                        }
                    }

                    Repeater {
                        model: [{
                            "id": "",
                            "label": "Everyone"
                        }, {
                            "id": "female",
                            "label": "Women"
                        }, {
                            "id": "male",
                            "label": "Men"
                        }, {
                            "id": "trans",
                            "label": "Trans"
                        }]

                        delegate: RippleButton {
                            required property var modelData

                            implicitHeight: 28
                            implicitWidth: genderLabel.implicitWidth + 22
                            toggled: root.theLens.starGender === modelData.id
                            colBackground: "#1d1d1d"
                            colBackgroundToggled: root.amber
                            onClicked: root.theLens.starGender = modelData.id

                            StyledText {
                                id: genderLabel

                                anchors.centerIn: parent
                                text: parent.modelData.label
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                color: root.theLens.starGender === parent.modelData.id ? "#000000" : root.ink
                            }

                        }

                    }

                    StyledText {
                        text: root.theLens.starsLoading ? "Asking the site…" : `${root.theLens.starsShown.length} of ${root.theLens.stars.length}`
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: root.dim
                    }

                }

                GridView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 176)))
                    cellHeight: Math.round(cellWidth * 1.22)
                    model: root.theLens.starsShown

                    // A face and a number, like the site's own Pornstars menu.
                    // A column of names is a phone book; this is a choice.
                    delegate: Item {
                        id: starCell

                        required property var modelData

                        width: GridView.view.cellWidth
                        height: GridView.view.cellHeight

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 4
                            radius: 10
                            clip: true
                            color: root.card
                            border.width: starHover.hovered ? 2 : 0
                            border.color: root.amber

                            Image {
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                height: parent.height - 44
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: true
                                source: starCell.modelData.thumb || ""
                            }

                            MaterialSymbol {
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.top: parent.top
                                anchors.topMargin: Math.round((parent.height - 44) / 2 - 14)
                                visible: String(starCell.modelData.thumb || "").length === 0
                                text: "person"
                                iconSize: 30
                                color: root.dim
                            }

                            ColumnLayout {
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                anchors.margins: 8
                                spacing: 0

                                StyledText {
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                    text: starCell.modelData.name || ""
                                    font.pixelSize: Appearance.font.pixelSize.smallest
                                    font.weight: Font.DemiBold
                                    color: starHover.hovered ? root.amber : root.ink
                                }

                                StyledText {
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                    visible: starCell.modelData.videos > 0
                                    text: `${starCell.modelData.videos} videos`
                                    font.pixelSize: Appearance.font.pixelSize.smallest
                                    color: root.dim
                                }

                            }

                            HoverHandler {
                                id: starHover

                                cursorShape: Qt.PointingHandCursor
                            }

                            TapHandler {
                                gesturePolicy: TapHandler.ReleaseWithinBounds
                                onTapped: root.theLens.openStar(starCell.modelData)
                            }

                        }

                    }

                }

            }

            // ── watching one ─────────────────────────────────────────────────
            Watch {
                anchors.fill: parent
                visible: root.theLens.screen === "watch"
                lens: root.theLens
                ground: "#000000"
                accent: root.amber
                onAccent: "#000000"
                panel: "#101010"
                ink: root.ink
                inkDim: root.dim
            }

        }

    }

}
