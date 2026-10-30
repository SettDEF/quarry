import qs.modules.common
import QtQuick
import QtQuick.Layouts

/*
 * One source. The row is the switch, the chevron opens the two settings that
 * only matter once it is on, and the badges say what those are set to closed.
 *
 * The bar is new: thirty-six rows differing only in a name say nothing about
 * which is worth keeping, and how much each put in your catalogue is a length
 * rather than a number to divide in your head.
 */
Rectangle {
    id: root

    required property string sourceId
    property string category: ""
    property bool video: false
    property int rows: 0
    /// Rows as a fraction of the biggest contributor's — against the total,
    /// almost everything is 3% and every bar looks the same.
    property real share: 0

    property bool enabled_: true
    /// 0 means "whatever the source's own default is" -- not "zero pages".
    property int pages: 0
    property int weight: 0

    property bool expanded: false

    /// Lower case, already trimmed. Matched against the id and the category.
    property string filter: ""
    property bool shown: true
    readonly property bool matched: root.filter.length === 0
        || (root.sourceId + " " + root.category).toLowerCase().indexOf(root.filter) >= 0
    visible: root.shown && root.matched

    signal setEnabled(bool on)
    signal setPages(int pages)
    signal setWeight(int weight)

    readonly property color offColor: ColorUtils.transparentize(Appearance.colors.colLayer2Hover, 1)

    function _compact(n) {
        if (!(n > 0))
            return "nothing yet";
        if (n >= 1000000)
            return (n / 1000000).toFixed(1) + "M pictures";
        if (n >= 1000)
            return (n / 1000).toFixed(n >= 10000 ? 0 : 1) + "k pictures";
        return n + (n === 1 ? " picture" : " pictures");
    }

    Layout.fillWidth: true
    implicitHeight: body.implicitHeight + (root.expanded ? more.implicitHeight + 10 : 0) + 16
    Behavior on implicitHeight {
        animation: Appearance.animation.elementMove.numberAnimation.createObject(root)
    }

    radius: Appearance.rounding.small
    // A filled tile, not a transparent strip: settings are one list, sources
    // are separate objects, and nine of them need edges or they read as one.
    color: root.expanded ? Appearance.colors.colLayer2Active
        : headTap.pressed ? Appearance.colors.colLayer2Active
        : headHover.hovered ? Appearance.colors.colLayer2Hover
        : Appearance.colors.colLayer2
    Behavior on color {
        animation: Appearance.animation.stateChange.colorAnimation.createObject(root)
    }

    // Clipped so the settings slide out from under the header rather than
    // being drawn over the row below it while the height is still animating.
    clip: true

    // --- the header: always visible -------------------------------------

    Item {
        id: head
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        implicitHeight: body.implicitHeight + 16
        height: implicitHeight

        HoverHandler {
            id: headHover
            cursorShape: Qt.PointingHandCursor
        }
        TapHandler {
            id: headTap
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: root.setEnabled(!root.enabled_)
        }

        RowLayout {
            id: body
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 12
            anchors.rightMargin: 8
            spacing: 12

            MaterialSymbol {
                Layout.alignment: Qt.AlignVCenter
                text: root.category === "adult" ? "no_adult_content" : root.category === "video" ? "movie" : root.category === "wallpapers" ? "wallpaper" : root.category === "photography" ? "photo_camera" : root.category === "art" ? "brush" : root.category === "icons" ? "shapes" : root.category === "local" ? "folder" : "cloud"
                iconSize: Appearance.font.pixelSize.larger
                color: root.enabled_ ? Appearance.colors.colOnLayer1 : Appearance.colors.colSubtext
                opacity: root.enabled_ ? 1 : 0.6
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                StyledText {
                    Layout.fillWidth: true
                    text: root.sourceId
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: root.enabled_ ? Appearance.colors.colOnLayer1 : Appearance.colors.colSubtext
                    elide: Text.ElideRight
                }
                StyledText {
                    Layout.fillWidth: true
                    // What it gave you, not its category — that is the heading
                    // it is already filed under.
                    text: {
                        const bits = [root._compact(root.rows)];
                        if (root.video)
                            bits.push("video");
                        if (!root.enabled_)
                            bits.push("not crawled");
                        return bits.join(" · ");
                    }
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                    elide: Text.ElideRight
                }

                // The track is drawn even at zero, so a landing crawl does not
                // make every row change height.
                Rectangle {
                    Layout.fillWidth: true
                    Layout.topMargin: 3
                    Layout.maximumWidth: 220
                    implicitHeight: 3
                    radius: height / 2
                    color: Appearance.colors.colLayer3

                    Rectangle {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        height: parent.height
                        radius: height / 2
                        // A floor: an empty bar and no bar mean different
                        // things and must not look alike.
                        width: root.rows > 0 ? Math.max(4, parent.width * Math.min(1, root.share)) : 0
                        color: root.enabled_ ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                        opacity: root.enabled_ ? 1 : 0.5

                        Behavior on width {
                            animation: Appearance.animation.elementMove.numberAnimation.createObject(root)
                        }
                    }
                }
            }

            // Only non-defaults: 36 rows announcing "normal priority" is noise.
            Rectangle {
                visible: root.pages > 0
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: pagesBadge.implicitWidth + 14
                implicitHeight: 22
                radius: height / 2
                color: Appearance.colors.colLayer3
                StyledText {
                    id: pagesBadge
                    anchors.centerIn: parent
                    text: `${root.pages}p`
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: Appearance.colors.colOnLayer1
                }
            }
            Rectangle {
                visible: root.weight !== 0
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: weightBadge.implicitWidth + 14
                implicitHeight: 22
                radius: height / 2
                color: root.weight > 0 ? Appearance.colors.colPrimaryContainer : Appearance.colors.colLayer3
                StyledText {
                    id: weightBadge
                    anchors.centerIn: parent
                    text: root.weight > 0 ? "first" : "last"
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: root.weight > 0 ? Appearance.colors.colOnPrimaryContainer : Appearance.colors.colSubtext
                }
            }

            StyledSwitch {
                Layout.alignment: Qt.AlignVCenter
                checked: root.enabled_
                // The row is the switch; a handler here would toggle twice.
                interactive: false
            }

            // Its own target: one control doing two things by pixel is how you
            // turn a source off by accident.
            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: 30
                implicitHeight: 30
                radius: height / 2
                color: chevTap.pressed ? Appearance.colors.colLayer3Active : chevHover.hovered ? Appearance.colors.colLayer3Hover : root.offColor
                Behavior on color {
                    animation: Appearance.animation.stateChange.colorAnimation.createObject(root)
                }

                HoverHandler {
                    id: chevHover
                    cursorShape: Qt.PointingHandCursor
                }
                TapHandler {
                    id: chevTap
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: root.expanded = !root.expanded
                }

                MaterialSymbol {
                    anchors.centerIn: parent
                    text: "expand_more"
                    iconSize: Appearance.font.pixelSize.large
                    color: Appearance.colors.colSubtext
                    rotation: root.expanded ? 180 : 0
                    Behavior on rotation {
                        animation: Appearance.animation.elementMove.numberAnimation.createObject(root)
                    }
                }
            }
        }
    }

    // --- the settings: only once you ask for them ------------------------

    ColumnLayout {
        id: more
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: head.bottom
        anchors.leftMargin: 46          // lines up under the label, not the icon
        anchors.rightMargin: 12
        spacing: 8
        opacity: root.expanded ? 1 : 0
        visible: opacity > 0
        Behavior on opacity {
            animation: Appearance.animation.elementMove.numberAnimation.createObject(root)
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                StyledText {
                    text: "Pages per search"
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colOnLayer1
                }
                StyledText {
                    Layout.fillWidth: true
                    // A search limit, not a scroll limit: scrolling is endless.
                    text: root.pages === 0 ? "Unlimited — a search keeps paging this source until it has no more." : `${root.pages} page${root.pages === 1 ? "" : "s"} per search. Scrolling keeps fetching regardless.`
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: Appearance.colors.colSubtext
                    wrapMode: Text.WordWrap
                }
            }

            Stepper {
                value: root.pages
                from: 0
                to: 8
                display: root.pages === 0 ? "∞" : `${root.pages}`
                onChanged_: v => root.setPages(v)
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4

            StyledText {
                text: "When it is asked"
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colOnLayer1
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Repeater {
                    model: [
                        {
                            "w": -5,
                            "label": "Last",
                            "hint": "after everything else"
                        },
                        {
                            "w": 0,
                            "label": "Normal",
                            "hint": "in turn"
                        },
                        {
                            "w": 5,
                            "label": "First",
                            "hint": "before the rest"
                        }
                    ]

                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool active: (root.weight > 0 && modelData.w > 0) || (root.weight < 0 && modelData.w < 0) || (root.weight === 0 && modelData.w === 0)

                        Layout.fillWidth: true
                        implicitHeight: 30
                        radius: Appearance.rounding.small
                        color: active ? Appearance.colors.colPrimaryContainer : chipTap.pressed ? Appearance.colors.colLayer3Active : chipHover.hovered ? Appearance.colors.colLayer3Hover : Appearance.colors.colLayer3
                        Behavior on color {
                            animation: Appearance.animation.stateChange.colorAnimation.createObject(root)
                        }

                        HoverHandler {
                            id: chipHover
                            cursorShape: Qt.PointingHandCursor
                        }
                        TapHandler {
                            id: chipTap
                            gesturePolicy: TapHandler.ReleaseWithinBounds
                            onTapped: root.setWeight(modelData.w)
                        }

                        StyledText {
                            anchors.centerIn: parent
                            text: modelData.label
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: parent.active ? Appearance.colors.colOnPrimaryContainer : Appearance.colors.colSubtext
                        }

                        StyledToolTip {
                            visible: chipHover.hovered
                            text: modelData.hint
                        }
                    }
                }
            }
        }

        Item {
            implicitHeight: 2
        }
    }
}
