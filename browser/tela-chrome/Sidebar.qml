import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

pragma ComponentBehavior: Bound

// Vertical tab strip.
//
// Layout is deliberately hierarchical rather than a flat list: space switcher,
// search, then tabs under a labelled section. The active row is marked three
// ways — container fill, an accent bar, and text weight — because in a long
// list one signal alone is easy to lose.
Rectangle {
    id: root

    required property var theme
    required property var tabs
    property int currentIndex: 0

    // Icon-rail rendering: labels collapse away, rows centre their marker.
    property bool compact: false

    signal tabActivated(int index)
    signal tabClosed(int index)
    signal tabMuteToggled(int index)
    signal tabsReordered(int from, int to)
    signal newTabRequested()
    signal paletteRequested()
    signal tabMenuRequested(int index, var point)

    color: theme.sidebar

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 4

        // ── Space switcher ─────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 40
            radius: root.theme.rounding
            color: spaceHover.hovered ? root.theme.sidebarHover : "transparent"

            Behavior on color { ColorAnimation { duration: root.theme.durFast } }

            HoverHandler { id: spaceHover }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: root.compact ? 0 : 8
                anchors.rightMargin: root.compact ? 0 : 8
                spacing: 10

                Item {
                    Layout.alignment: Qt.AlignVCenter | (root.compact ? Qt.AlignHCenter : Qt.AlignLeft)
                    Layout.fillWidth: root.compact
                    implicitWidth: 22
                    implicitHeight: 22

                    Rectangle {
                        anchors.centerIn: parent
                        width: 22; height: 22
                        radius: 8
                        color: root.theme.accent

                        Label {
                            anchors.centerIn: parent
                            text: "P"
                            color: root.theme.onAccent
                            font.family: root.theme.fontMain
                            font.pixelSize: root.theme.fontSmall
                            font.weight: Font.DemiBold
                        }
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    visible: !root.compact
                    spacing: 0

                    Label {
                        Layout.fillWidth: true
                        text: "Personal"
                        color: root.theme.text
                        font.family: root.theme.fontMain
                        font.pixelSize: root.theme.fontSmall
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                    }
                    Label {
                        Layout.fillWidth: true
                        text: root.tabs.count + (root.tabs.count === 1 ? " tab" : " tabs")
                        color: root.theme.textFaint
                        font.family: root.theme.fontMain
                        font.pixelSize: root.theme.fontSmallest
                    }
                }

                Label {
                    visible: !root.compact
                    text: "unfold_more"
                    color: root.theme.textFaint
                    font.family: root.theme.fontIcon
                    font.pixelSize: root.theme.iconSizeSmall
                }
            }
        }

        // ── Search ─────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.topMargin: 4
            height: root.theme.rowHeight
            radius: root.theme.rounding
            color: searchHover.hovered ? root.theme.surfaceHover : root.theme.surface

            Behavior on color { ColorAnimation { duration: root.theme.durFast } }

            HoverHandler { id: searchHover }
            TapHandler { onTapped: root.paletteRequested() }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: root.compact ? 0 : 10
                anchors.rightMargin: root.compact ? 0 : 10
                spacing: 8

                Label {
                    Layout.alignment: Qt.AlignVCenter | (root.compact ? Qt.AlignHCenter : Qt.AlignLeft)
                    Layout.fillWidth: root.compact
                    horizontalAlignment: Text.AlignHCenter
                    text: "search"
                    color: root.theme.textDim
                    font.family: root.theme.fontIcon
                    font.pixelSize: root.theme.iconSize
                }
                Label {
                    Layout.fillWidth: true
                    visible: !root.compact
                    text: "Search"
                    color: root.theme.textDim
                    font.family: root.theme.fontMain
                    font.pixelSize: root.theme.fontSmall
                    elide: Text.ElideRight
                }
                Label {
                    visible: !root.compact
                    text: "⌃K"
                    color: root.theme.textFaint
                    font.family: root.theme.fontMono
                    font.pixelSize: root.theme.fontSmallest
                }
            }
        }

        // ── Section header ─────────────────────────────────────────────
        Label {
            Layout.fillWidth: true
            Layout.leftMargin: 10
            Layout.topMargin: 12
            Layout.bottomMargin: 2
            visible: !root.compact
            text: "TABS"
            color: root.theme.textFaint
            font.family: root.theme.fontMain
            font.pixelSize: root.theme.fontSmallest
            font.weight: Font.DemiBold
            font.letterSpacing: 1.0
        }

        // Rail mode has no room for a header, so a hairline stands in.
        Rectangle {
            Layout.fillWidth: true
            Layout.topMargin: 8
            Layout.bottomMargin: 4
            Layout.leftMargin: 8
            Layout.rightMargin: 8
            height: 1
            visible: root.compact
            color: root.theme.border
        }

        // ── Tab list ───────────────────────────────────────────────────
        ListView {
            id: tabList

            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 1
            model: root.tabs
            currentIndex: root.currentIndex
            boundsBehavior: Flickable.StopAtBounds

            // Rows slide to their new spots after a drag-reorder.
            move: Transition {
                NumberAnimation { property: "y"; duration: root.theme.durNormal
                    easing.type: Easing.BezierSpline; easing.bezierCurve: root.theme.curveSpatial }
            }
            displaced: Transition {
                NumberAnimation { property: "y"; duration: root.theme.durNormal
                    easing.type: Easing.BezierSpline; easing.bezierCurve: root.theme.curveSpatial }
            }

            ScrollBar.vertical: ScrollBar {
                id: scroller
                policy: tabList.contentHeight > tabList.height
                        ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                width: 4

                contentItem: Rectangle {
                    radius: 2
                    color: root.theme.textFaint
                    opacity: scroller.pressed ? 0.7 : 0.3
                    Behavior on opacity { NumberAnimation { duration: root.theme.durFast } }
                }
            }

            delegate: Rectangle {
                id: tabDelegate

                required property int index
                required property string title
                required property string iconUrl
                required property bool loading
                required property bool audible
                required property bool muted

                width: ListView.view.width
                height: root.theme.rowHeight
                radius: root.theme.rounding

                // Follows the cursor while being dragged; the model move is
                // applied once, on release (live-mutating the model mid-grab is
                // what makes ListView reordering jitter and drop the grab).
                z: dragHandler.active ? 5 : 0
                transform: Translate {
                    // Scene coordinates, not delegate-relative: the delegate is
                    // itself being translated, so centroid.position would shift
                    // as it moves and feed back into a jitter.
                    y: dragHandler.active
                       ? dragHandler.centroid.scenePosition.y - dragHandler.centroid.scenePressPosition.y
                       : 0
                }

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

                // Accent bar on the active row — the signal that survives when
                // the container fill sits close to the sidebar colour.
                Rectangle {
                    anchors.left: parent.left
                    anchors.leftMargin: 3
                    anchors.verticalCenter: parent.verticalCenter
                    width: 3
                    height: tabDelegate.active ? parent.height - 14 : 0
                    radius: 1.5
                    color: root.theme.onAccentContainer
                    visible: !root.compact

                    Behavior on height {
                        NumberAnimation {
                            duration: root.theme.durNormal
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: root.theme.curveSpatial
                        }
                    }
                }

                HoverHandler { id: tabHover }
                TapHandler {
                    acceptedButtons: Qt.LeftButton
                    onTapped: root.tabActivated(tabDelegate.index)
                }

                // Drag to reorder. The threshold lets a plain click still
                // activate the tab; only a real drag moves it. The move is
                // computed from how many row-heights the drag travelled and
                // applied on release.
                DragHandler {
                    id: dragHandler
                    target: null
                    dragThreshold: 12
                    onActiveChanged: {
                        if (active)
                            return;
                        const delta = centroid.scenePosition.y - centroid.scenePressPosition.y;
                        const rowH = tabDelegate.height + tabList.spacing;
                        const steps = Math.round(delta / rowH);
                        if (steps === 0)
                            return;
                        const target = Math.max(0, Math.min(root.tabs.count - 1,
                                                            tabDelegate.index + steps));
                        if (target !== tabDelegate.index)
                            root.tabsReordered(tabDelegate.index, target);
                    }
                }
                TapHandler {
                    acceptedButtons: Qt.RightButton
                    onTapped: eventPoint => {
                        const point = tabDelegate.mapToItem(null, eventPoint.position.x,
                                                            eventPoint.position.y);
                        root.tabMenuRequested(tabDelegate.index, point);
                    }
                }
                // Middle-click closes, as it does everywhere else.
                TapHandler {
                    acceptedButtons: Qt.MiddleButton
                    onTapped: root.tabClosed(tabDelegate.index)
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: root.compact ? 0 : 11
                    anchors.rightMargin: root.compact ? 0 : 6
                    spacing: root.compact ? 0 : 9

                    // Favicon, with a dot fallback and a spinner while loading.
                    Item {
                        Layout.alignment: Qt.AlignVCenter | (root.compact ? Qt.AlignHCenter : Qt.AlignLeft)
                        Layout.fillWidth: root.compact
                        implicitWidth: 16
                        implicitHeight: 16

                        Image {
                            id: favicon
                            anchors.centerIn: parent
                            width: 16; height: 16
                            source: tabDelegate.iconUrl
                            visible: root.theme.showFavicons
                                     && !tabDelegate.loading
                                     && status === Image.Ready
                            sourceSize.width: 32
                            sourceSize.height: 32
                            smooth: true
                        }

                        Rectangle {
                            anchors.centerIn: parent
                            width: 6; height: 6; radius: 3
                            visible: !tabDelegate.loading && !favicon.visible
                            color: tabDelegate.active ? root.theme.onAccentContainer
                                                      : root.theme.textFaint
                        }

                        Item {
                            anchors.centerIn: parent
                            width: 14; height: 14
                            visible: tabDelegate.loading

                            Rectangle {
                                anchors.fill: parent
                                radius: width / 2
                                color: "transparent"
                                border.width: 2
                                border.color: tabDelegate.active ? root.theme.onAccentContainer
                                                                 : root.theme.accent

                                // A gap in the ring is what makes rotation read.
                                Rectangle {
                                    width: 7; height: 7
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    color: tabDelegate.active ? root.theme.accentContainer
                                                              : tabHover.hovered
                                                                ? root.theme.sidebarHover
                                                                : root.theme.sidebar
                                }

                                RotationAnimator on rotation {
                                    running: tabDelegate.loading
                                    loops: Animation.Infinite
                                    from: 0; to: 360
                                    duration: 900
                                }
                            }
                        }
                    }

                    Label {
                        Layout.fillWidth: true
                        visible: !root.compact
                        text: tabDelegate.title
                        color: tabDelegate.active ? root.theme.onAccentContainer
                                                  : root.theme.textDim
                        font.family: root.theme.fontMain
                        font.pixelSize: root.theme.fontSmall
                        font.weight: tabDelegate.active ? Font.DemiBold : Font.Normal
                        elide: Text.ElideRight
                    }

                    // Speaker icon: shown when a tab is making noise or is muted.
                    // Clicking it toggles mute without activating the tab. In the
                    // compact rail there is no room, so it is title-mode only.
                    Rectangle {
                        visible: !root.compact && (tabDelegate.audible || tabDelegate.muted)
                        Layout.preferredWidth: 20
                        Layout.preferredHeight: 20
                        Layout.alignment: Qt.AlignVCenter
                        radius: 6
                        color: audioHover.hovered ? root.theme.surfaceActive : "transparent"

                        HoverHandler { id: audioHover }
                        TapHandler {
                            onTapped: root.tabMuteToggled(tabDelegate.index)
                        }

                        Label {
                            anchors.centerIn: parent
                            text: tabDelegate.muted ? "volume_off" : "volume_up"
                            color: tabDelegate.muted
                                   ? root.theme.textFaint
                                   : tabDelegate.active ? root.theme.onAccentContainer
                                                        : root.theme.textDim
                            font.family: root.theme.fontIcon
                            font.pixelSize: 15
                        }
                    }

                    // Close sits in a fixed slot so titles do not reflow as the
                    // pointer moves down the list.
                    Item {
                        visible: !root.compact && root.theme.closeButtonMode !== "never"
                        Layout.preferredWidth: 20
                        Layout.preferredHeight: 20
                        Layout.alignment: Qt.AlignVCenter

                        opacity: root.theme.closeButtonMode === "always" || tabHover.hovered ? 1 : 0

                        Behavior on opacity {
                            NumberAnimation {
                                duration: root.theme.durFast
                                easing.type: Easing.BezierSpline
                                easing.bezierCurve: root.theme.curveEffects
                            }
                        }

                        Rectangle {
                            anchors.fill: parent
                            radius: 6
                            color: closeHover.hovered ? root.theme.surfaceActive : "transparent"

                            HoverHandler { id: closeHover }
                            TapHandler { onTapped: root.tabClosed(tabDelegate.index) }

                            Label {
                                anchors.centerIn: parent
                                text: "close"
                                color: tabDelegate.active ? root.theme.onAccentContainer
                                                          : root.theme.textDim
                                font.family: root.theme.fontIcon
                                font.pixelSize: root.theme.iconSizeSmall
                            }
                        }
                    }
                }
            }
        }

        // ── New tab ────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.topMargin: 4
            height: root.theme.rowHeight
            radius: root.theme.rounding
            color: newHover.hovered ? root.theme.sidebarHover : "transparent"

            Behavior on color { ColorAnimation { duration: root.theme.durFast } }

            HoverHandler { id: newHover }
            TapHandler { onTapped: root.newTabRequested() }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: root.compact ? 0 : 11
                anchors.rightMargin: root.compact ? 0 : 10
                spacing: root.compact ? 0 : 9

                Label {
                    Layout.alignment: Qt.AlignVCenter | (root.compact ? Qt.AlignHCenter : Qt.AlignLeft)
                    Layout.fillWidth: root.compact
                    horizontalAlignment: Text.AlignHCenter
                    text: "add"
                    color: newHover.hovered ? root.theme.text : root.theme.textDim
                    font.family: root.theme.fontIcon
                    font.pixelSize: root.theme.iconSize

                    Behavior on color { ColorAnimation { duration: root.theme.durFast } }
                }
                Label {
                    Layout.fillWidth: true
                    visible: !root.compact
                    text: "New tab"
                    color: newHover.hovered ? root.theme.text : root.theme.textDim
                    font.family: root.theme.fontMain
                    font.pixelSize: root.theme.fontSmall

                    Behavior on color { ColorAnimation { duration: root.theme.durFast } }
                }
                Label {
                    visible: !root.compact
                    text: "⌃T"
                    color: root.theme.textFaint
                    font.family: root.theme.fontMono
                    font.pixelSize: root.theme.fontSmallest
                }
            }
        }
    }
}
