import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

pragma ComponentBehavior: Bound

// Horizontal tab strip for `tabBar.mode: "top"`.
Rectangle {
    id: root

    required property var theme
    required property var tabs
    property int currentIndex: 0

    signal tabActivated(int index)
    signal tabClosed(int index)
    signal tabMuteToggled(int index)
    signal newTabRequested()
    signal paletteRequested()
    signal tabMenuRequested(int index, var point)

    implicitHeight: theme.rowHeight + 12
    color: theme.sidebar

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        spacing: 6

        Rectangle {
            Layout.alignment: Qt.AlignVCenter
            width: 16; height: 16
            radius: width / 2
            color: root.theme.accent

            TapHandler { onTapped: root.paletteRequested() }
        }

        ListView {
            id: strip

            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.topMargin: 6
            Layout.bottomMargin: 6
            orientation: ListView.Horizontal
            clip: true
            spacing: 4
            model: root.tabs
            currentIndex: root.currentIndex

            delegate: Rectangle {
                id: tabDelegate

                required property int index
                required property string title
                required property bool audible
                required property bool muted

                // Tabs share the strip evenly until they hit a comfortable
                // reading width, then stop shrinking and start scrolling.
                width: Math.max(120, Math.min(220, strip.width / Math.max(1, root.tabs.count) - 4))
                height: strip.height
                radius: root.theme.rounding

                readonly property bool active: index === root.currentIndex

                color: active ? root.theme.accentContainer
                              : tabHover.hovered ? root.theme.sidebarHover
                                                 : "transparent"

                Behavior on color {
                    ColorAnimation {
                        duration: root.theme.durFast
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: root.theme.curveEffects
                    }
                }

                HoverHandler { id: tabHover }
                TapHandler {
                    acceptedButtons: Qt.LeftButton
                    onTapped: root.tabActivated(tabDelegate.index)
                }
                TapHandler {
                    acceptedButtons: Qt.RightButton
                    onTapped: eventPoint => {
                        const point = tabDelegate.mapToItem(null, eventPoint.position.x,
                                                            eventPoint.position.y);
                        root.tabMenuRequested(tabDelegate.index, point);
                    }
                }
                TapHandler {
                    acceptedButtons: Qt.MiddleButton
                    onTapped: root.tabClosed(tabDelegate.index)
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 8
                    spacing: 8

                    Rectangle {
                        width: 6; height: 6; radius: 3
                        color: tabDelegate.active ? root.theme.onAccentContainer
                                                  : root.theme.textFaint
                    }

                    Label {
                        Layout.fillWidth: true
                        text: tabDelegate.title
                        color: tabDelegate.active ? root.theme.onAccentContainer
                                                  : root.theme.textDim
                        font.family: root.theme.fontMain
                        font.pixelSize: root.theme.fontSmall
                        elide: Text.ElideRight
                    }

                    // Speaker when the tab is making noise or is muted; click to
                    // toggle mute without switching to the tab.
                    Label {
                        visible: tabDelegate.audible || tabDelegate.muted
                        text: tabDelegate.muted ? "volume_off" : "volume_up"
                        color: tabDelegate.muted
                               ? root.theme.textFaint
                               : tabDelegate.active ? root.theme.onAccentContainer
                                                    : root.theme.textDim
                        font.family: root.theme.fontIcon
                        font.pixelSize: root.theme.iconSizeSmall
                        TapHandler { onTapped: root.tabMuteToggled(tabDelegate.index) }
                    }

                    Label {
                        text: "close"
                        color: tabDelegate.active ? root.theme.onAccentContainer
                                                  : root.theme.textDim
                        font.family: root.theme.fontIcon
                        font.pixelSize: root.theme.iconSizeSmall
                        opacity: tabHover.hovered ? 1 : 0

                        Behavior on opacity {
                            NumberAnimation { duration: root.theme.durFast }
                        }

                        TapHandler { onTapped: root.tabClosed(tabDelegate.index) }
                    }
                }
            }
        }

        Rectangle {
            Layout.alignment: Qt.AlignVCenter
            width: 28; height: 28
            radius: root.theme.roundingSmall
            color: newHover.hovered ? root.theme.sidebarHover : "transparent"

            HoverHandler { id: newHover }
            TapHandler { onTapped: root.newTabRequested() }

            Label {
                anchors.centerIn: parent
                text: "add"
                color: root.theme.textDim
                font.family: root.theme.fontIcon
                font.pixelSize: root.theme.iconSize
            }
        }
    }
}
