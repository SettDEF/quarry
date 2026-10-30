import QtQuick
import QtQuick.Layouts
import qs.modules.common
import qs.modules.widgets

/*
 * WHILE SEARCHING: how the results are ordered, over what time, where — and
 * the communities that match, one click away. The results themselves are the
 * feed, in whatever layout this subreddit uses.
 */
Rectangle {
    id: root
    required property var lens
    property color ground: Appearance.colors.colLayer0Base
    visible: root.lens.query.length > 0 && root.lens.screen === "feed"
    implicitHeight: visible ? col.implicitHeight + 16 : 0
    color: root.ground

    component Chip: Rectangle {
        id: chip
        property string label
        property bool on: false
        property string icon: ""
        signal clicked()
        implicitWidth: chipRow.implicitWidth + 22; implicitHeight: 28; radius: 14
        color: chip.on ? Appearance.colors.colPrimary : ch.hovered ? Appearance.colors.colLayer2Hover : Appearance.colors.colLayer2
        Behavior on color { ColorAnimation { duration: 120 } }
        Row {
            id: chipRow
            anchors.centerIn: parent
            spacing: 4
            MaterialSymbol { visible: chip.icon.length > 0; anchors.verticalCenter: parent.verticalCenter; text: chip.icon; iconSize: 15; color: chip.on ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer2 }
            StyledText { anchors.verticalCenter: parent.verticalCenter; text: chip.label; font.pixelSize: Appearance.font.pixelSize.smaller; color: chip.on ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer2 }
        }
        HoverHandler { id: ch; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: chip.clicked() }
    }

    ColumnLayout {
        id: col
        anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 14; rightMargin: 14; topMargin: 4 }
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            Repeater {
                model: ["relevance", "top", "new", "comments"]
                delegate: Chip {
                    required property string modelData
                    label: root.lens.searchSortLabel[modelData]
                    on: root.lens.searchSort === modelData
                    onClicked: root.lens.chooseSearch(modelData, "")
                }
            }
            Rectangle { implicitWidth: 1; implicitHeight: 20; color: Appearance.colors.colOutlineVariant; Layout.leftMargin: 4; Layout.rightMargin: 4 }
            // a time window means nothing for "new"
            Repeater {
                model: root.lens.searchSort === "new" ? [] : ["day", "week", "month", "year", "all"]
                delegate: Chip {
                    required property string modelData
                    label: root.lens.searchTimeLabel[modelData]
                    on: root.lens.searchTime === modelData
                    onClicked: root.lens.chooseSearch("", modelData)
                }
            }
            Item { Layout.fillWidth: true }
            // only in the community you were in
            Chip {
                visible: root.lens.sub !== "all" && !root.lens.isProfile()
                icon: "filter_alt"
                label: `only r/${root.lens.sub}`
                on: root.lens.searchSub.length > 0
                onClicked: root.lens.search(root.lens.query, root.lens.searchSub.length === 0)
            }
            IconButton {
                icon: "close"
                tooltip: "End the search"
                size: 30
                onClicked: root.lens.clearSearch()
            }
        }

        // communities that match: go there
        Flow {
            visible: root.lens.foundSubs.length > 0
            Layout.fillWidth: true
            spacing: 6
            StyledText { height: 28; verticalAlignment: Text.AlignVCenter; text: "Communities"; font.pixelSize: Appearance.font.pixelSize.smallest; color: Appearance.colors.colSubtext; rightPadding: 4 }
            Repeater {
                model: root.lens.foundSubs
                delegate: Chip {
                    required property var modelData
                    icon: modelData.over18 ? "explicit" : "group"
                    label: `r/${modelData.display_name}` + (modelData.subscribers ? `  ·  ${(modelData.subscribers >= 1e6 ? (modelData.subscribers / 1e6).toFixed(1) + "M" : modelData.subscribers >= 1e3 ? Math.round(modelData.subscribers / 1e3) + "k" : modelData.subscribers)}` : "")
                    onClicked: root.lens.openSub(modelData.display_name)
                }
            }
        }
    }
}
