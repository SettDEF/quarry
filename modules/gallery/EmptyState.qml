import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

/*
 * WHEN THERE IS NOTHING TO SHOW, SAY WHY AND OFFER THE WAY ON.
 *
 * There were two of these, drawn on top of each other: the wall's own
 * "What are you filling?" slot picker, and the window's "Nothing matches"
 * placeholder, centred on the same point — so an empty search looked like a
 * rendering accident. There is one now, owned by the window, and it answers
 * the three different empties differently:
 *
 *   - the daemon is not answering  → that, and a retry
 *   - a query that matched nothing → the query, quoted, and two ways out
 *   - an empty catalogue           → what to do to fill it
 */
Item {
    id: root

    signal searchEverywhere
    signal retry

    // Mid-fetch is not "empty" — it just has not answered yet, and flashing
    // this in front of a page that is about to land reads as a lie.
    readonly property bool shouldShow: !Catalog.loading && !Catalog.loadingMore && Catalog.count === 0
    /*
     * A damaged catalogue answers every search with zero rows and no error, so
     * "nothing matched" was drawn over fifteen thousand pictures for a day.
     * `Catalog.damaged` is the daemon saying the file itself is the problem.
     */
    readonly property bool failed: Catalog.error.length > 0 || Catalog.damaged.length > 0 || !Client.connected
    readonly property string query: (Catalog.query || "").trim()

    visible: opacity > 0
    opacity: root.shouldShow ? 1 : 0
    Behavior on opacity {
        NumberAnimation {
            duration: Appearance.animDur(200)
            easing.type: Easing.OutCubic
        }
    }
    enabled: root.shouldShow

    ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(420, root.width - 48)
        spacing: 0

        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 88
            Layout.preferredHeight: 88
            radius: 44
            color: root.failed ? Appearance.colors.colErrorContainer : Appearance.colors.colSecondaryContainer

            MaterialSymbol {
                anchors.centerIn: parent
                text: Catalog.damaged.length > 0 ? "database" : root.failed ? "cloud_off" : root.query.length > 0 ? "image_search" : "photo_library"
                iconSize: 40
                color: root.failed ? Appearance.colors.colOnErrorContainer : Appearance.colors.colOnSecondaryContainer
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.topMargin: 20
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            text: Catalog.damaged.length > 0 ? "The catalogue is damaged" : root.failed ? "The catalogue is not answering"
                : root.query.length > 0 ? `Nothing matches “${root.query}”`
                : "Your catalogue is empty"
            font.pixelSize: Appearance.font.pixelSize.huge
            font.weight: Font.DemiBold
            color: Appearance.colors.colOnLayer1
        }

        StyledText {
            Layout.fillWidth: true
            Layout.topMargin: 8
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: Catalog.damaged.length > 0 ? `Nothing can be searched until it is rebuilt — ${Catalog.damaged}. Restarting quarryd rebuilds it and keeps your boards and collections.` : root.failed ? (Catalog.error.length > 0 ? Catalog.error : "quarryd is not running. It starts on its own with the app; try again in a moment.")
                : root.query.length > 0 ? "Try fewer filters or another word — or ask every source, which finds pictures your catalogue has not seen yet."
                : "Search for something and quarry will fetch it from its sources."
            font.pixelSize: Appearance.font.pixelSize.smallie
            color: Appearance.colors.colSubtext
        }

        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 22
            spacing: 10

            TextButton {
                visible: root.failed
                text: "Try again"
                icon: "refresh"
                variant: "filled"
                onClicked: root.retry()
            }
            TextButton {
                visible: !root.failed && root.query.length > 0
                text: "Clear search"
                icon: "backspace"
                variant: "tonal"
                onClicked: Catalog.query = ""
            }
            TextButton {
                visible: !root.failed
                text: "Search every source"
                icon: "travel_explore"
                variant: "filled"
                onClicked: root.searchEverywhere()
            }
        }
    }
}
