import QtQuick
import QtQuick.Layouts
import qs.modules.common
import qs.modules.gallery
import qs.modules.lens
import qs.modules.widgets
import qs.services

/*
 * THE SAME LENS IN QUARRY'S OWN CLOTHES.
 *
 * Colour roles and the app's surfaces, for anyone who would rather the lens did
 * not look like a different program in the same window. Identical navigation,
 * identical player — the difference is the palette and the corner radius, which
 * is the point of a skin.
 */
LensSkin {
    id: root

    readonly property var theLens: root.lens

    ground: Appearance.colors.colLayer0

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
                    Layout.preferredWidth: 240
                    placeholder: root.theLens.category.length > 0 ? `Search in ${root.theLens.category}` : "Search Pornhub"
                    text: root.theLens.searchText
                    onAccepted: root.theLens.search(text)
                }

                IconButton {
                    icon: "public"
                    tooltip: "Open the real site here"
                    onClicked: root.theLens.showSite()
                }

            }

        }

        // ── orderings, then the site's categories ────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 44
            visible: root.theLens.screen === "browse"
            color: Appearance.colors.colLayer0

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 6

                Repeater {
                    model: ["featured", "new", "views"]

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

                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 18
                    color: Appearance.colors.colOutlineVariant
                }

                // The categories scroll on past the orderings: there are
                // thirty-six of them and the rail carries the full list.
                ListView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    orientation: ListView.Horizontal
                    spacing: 6
                    clip: true
                    model: [""].concat(root.theLens.categories)

                    delegate: RippleButton {
                        required property var modelData

                        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                        implicitHeight: 28
                        implicitWidth: chipLabel.implicitWidth + 22
                        toggled: root.theLens.category === modelData
                        colBackground: Appearance.colors.colLayer1
                        onClicked: root.theLens.chooseCategory(modelData)

                        StyledText {
                            id: chipLabel

                            anchors.centerIn: parent
                            text: parent.modelData.length > 0 ? parent.modelData : "All"
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            color: root.theLens.category === parent.modelData ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer1
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

                // The cell follows the chosen layout (Lens.layoutCell), so the
                // app's layout button works here like everywhere else; a
                // compact row is a row rather than a tile.
                readonly property bool asList: root.theLens.layout === "compact"

                anchors.fill: parent
                anchors.margins: 12
                visible: root.theLens.screen === "browse" && root.theLens.rows.length > 0
                clip: true
                cellWidth: asList ? width : Math.floor(width / Math.max(1, Math.floor(width / Math.max(120, root.theLens.layoutCell || 300))))
                cellHeight: asList ? 88 : Math.round(cellWidth * 0.64)
                // The ListModel, not the array — see Feed.qml: assigning a new
                // array resets the view to the top, which is the jump.
                model: root.theLens.feedRef.model
                cacheBuffer: cellHeight * 2
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

            Watch {
                anchors.fill: parent
                visible: root.theLens.screen === "watch"
                lens: root.theLens
                ground: Appearance.colors.colLayer0
                accent: Appearance.colors.colPrimary
                onAccent: Appearance.colors.colOnPrimary
                panel: Appearance.colors.colLayer0Base
                ink: Appearance.colors.colOnLayer0
                inkDim: Appearance.colors.colSubtext
            }

        }

    }

}
