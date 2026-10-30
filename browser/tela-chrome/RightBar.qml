import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

pragma ComponentBehavior: Bound

// Slim action rail on the right edge.
//
// The item list is plain data so the planned drag-to-customise editor
// (Firefox-style, with flexible spacers) can reorder and persist it without the
// layout code changing. Entry shapes:
//
//   { id: "search", glyph: "search", tip: "Search" }
//   { type: "spacer" }            flexible gap
//   { type: "divider" }           hairline rule
Rectangle {
    id: root

    required property var theme
    property var items: []
    /// Ids that should render in an active/toggled state.
    property var activeIds: []

    signal actionTriggered(string id)

    color: theme.sidebar

    ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: 10
        anchors.bottomMargin: 10
        anchors.leftMargin: 6
        anchors.rightMargin: 6
        spacing: 3

        Repeater {
            model: root.items

            delegate: Item {
                id: entry

                required property var modelData

                readonly property string kind: modelData.type ?? "button"
                readonly property bool isSpacer: kind === "spacer"
                readonly property bool isDivider: kind === "divider"
                readonly property bool isButton: !isSpacer && !isDivider
                readonly property bool isActive: root.activeIds.indexOf(modelData.id) >= 0

                Layout.fillWidth: true
                Layout.fillHeight: isSpacer
                Layout.preferredHeight: isSpacer ? -1 : isDivider ? 9 : 34

                // Hairline group separator.
                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width - 10
                    height: 1
                    visible: entry.isDivider
                    color: root.theme.border
                }

                Rectangle {
                    anchors.fill: parent
                    visible: entry.isButton
                    radius: root.theme.roundingSmall
                    color: entry.isActive ? root.theme.accentContainer
                         : buttonHover.hovered ? root.theme.sidebarHover
                         : "transparent"

                    Behavior on color {
                        ColorAnimation {
                            duration: root.theme.durFast
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: root.theme.curveEffects
                        }
                    }

                    HoverHandler { id: buttonHover }
                    TapHandler { onTapped: root.actionTriggered(entry.modelData.id) }

                    ToolTip.visible: buttonHover.hovered && (entry.modelData.tip ?? "").length > 0
                    ToolTip.text: entry.modelData.tip ?? ""
                    ToolTip.delay: 450

                    Label {
                        anchors.centerIn: parent
                        text: entry.modelData.glyph ?? "circle"
                        color: entry.isActive ? root.theme.onAccentContainer
                             : buttonHover.hovered ? root.theme.text
                             : root.theme.textDim
                        font.family: root.theme.fontIcon
                        font.pixelSize: root.theme.iconSize

                        Behavior on color { ColorAnimation { duration: root.theme.durFast } }
                    }

                    // Badge for counts — downloads in progress, and so on.
                    Rectangle {
                        visible: (entry.modelData.badge ?? 0) > 0
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.rightMargin: 3
                        anchors.topMargin: 3
                        width: 8; height: 8; radius: 4
                        color: root.theme.accent
                    }
                }
            }
        }
    }
}
