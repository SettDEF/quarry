import qs.modules.common
import qs.services
import QtQuick
import QtQuick.Layouts

/*
 * ONE EXTENSION, WITH WHAT IT IS AND WHAT IT OFFERS.
 *
 * Extensions lived as toggle rows in the overflow menu: a name and a switch. A
 * menu row has nowhere to say who wrote a thing, what version it is, what it
 * actually does, or why it failed to load — and "failed" as a four-letter hint
 * beside a name is the least useful way to report a broken extension.
 *
 * The part that was missing entirely: `Extension` has declared a
 * `settingsPage` component since the API existed, and nothing anywhere
 * rendered it. An extension could ship settings that no one could reach.
 */
Rectangle {
    id: root

    required property var entry
    property bool expanded: false

    readonly property bool on: Extensions.isEnabled(root.entry.id)
    readonly property bool broken: !!root.entry.error && root.entry.error.length > 0
    readonly property var instance: root.entry.instance || null
    readonly property bool hasSettings: root.instance && root.instance.settingsPage

    readonly property color offColor: ColorUtils.transparentize(Appearance.colors.colLayer2Hover, 1)

    Layout.fillWidth: true
    implicitHeight: head.implicitHeight + (root.expanded ? extra.implicitHeight + 12 : 0)
    Behavior on implicitHeight {
        animation: Appearance.animation.elementMove.numberAnimation.createObject(root)
    }
    radius: Appearance.rounding.small
    color: root.expanded ? Appearance.colors.colLayer2
        : headTap.pressed ? Appearance.colors.colLayer2Active
        : headHover.hovered ? Appearance.colors.colLayer2Hover
        : root.offColor
    Behavior on color {
        animation: Appearance.animation.stateChange.colorAnimation.createObject(root)
    }
    clip: true

    Item {
        id: head
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        implicitHeight: Math.max(56, body.implicitHeight + 16)
        height: implicitHeight

        HoverHandler {
            id: headHover
            cursorShape: Qt.PointingHandCursor
        }
        TapHandler {
            id: headTap
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: Extensions.toggle(root.entry.id)
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
                text: root.broken ? "error" : "extension"
                iconSize: Appearance.font.pixelSize.larger
                color: root.broken ? Appearance.colors.colError
                    : root.on ? Appearance.colors.colOnLayer1
                    : Appearance.colors.colSubtext
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1

                StyledText {
                    Layout.fillWidth: true
                    text: root.entry.name
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: root.on ? Appearance.colors.colOnLayer1 : Appearance.colors.colSubtext
                    elide: Text.ElideRight
                }

                /*
                 * The failure, in full, where the extension is.
                 *
                 * A load error was a four-character hint in a menu. The first
                 * line of a QML error names the file and the line, which is
                 * the whole difference between "it broke" and a fix.
                 */
                StyledText {
                    Layout.fillWidth: true
                    visible: root.broken
                    text: String(root.entry.error).split("\n")[0]
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    font.family: Appearance.font.family.monospace
                    color: Appearance.colors.colError
                    wrapMode: Text.WordWrap
                }

                StyledText {
                    Layout.fillWidth: true
                    visible: !root.broken
                    text: {
                        const bits = [];
                        if (root.entry.version)
                            bits.push("v" + root.entry.version);
                        if (root.entry.author)
                            bits.push(root.entry.author);
                        bits.push(root.entry.source === "user" ? "yours" : "shipped");
                        if (root.hasSettings)
                            bits.push("has settings");
                        return bits.join(" · ");
                    }
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                    elide: Text.ElideRight
                }
            }

            StyledSwitch {
                checked: root.on
                // The row is the target — see the TapHandler above.
                interactive: false
                enabled: !root.broken
            }

            // Only offered when there is something behind it: a chevron that
            // opens an empty panel is worse than no chevron.
            Rectangle {
                visible: root.hasSettings || root.entry.description.length > 0
                implicitWidth: 30
                implicitHeight: 30
                radius: height / 2
                color: chevTap.pressed ? Appearance.colors.colLayer3Active
                    : chevHover.hovered ? Appearance.colors.colLayer3Hover
                    : root.offColor
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

    ColumnLayout {
        id: extra
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: head.bottom
        anchors.leftMargin: 46
        anchors.rightMargin: 12
        spacing: 10
        opacity: root.expanded ? 1 : 0
        visible: opacity > 0
        Behavior on opacity {
            animation: Appearance.animation.elementMove.numberAnimation.createObject(root)
        }

        StyledText {
            Layout.fillWidth: true
            visible: root.entry.description.length > 0
            text: root.entry.description
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            wrapMode: Text.WordWrap
        }

        /*
         * The extension's own settings, at last.
         *
         * Loaded only while expanded AND enabled: a disabled extension has no
         * instance, so there is nothing to render, and saying so beats an
         * empty box.
         */
        Loader {
            Layout.fillWidth: true
            active: root.expanded && root.on && root.hasSettings
            sourceComponent: active ? root.instance.settingsPage : null
        }

        StyledText {
            Layout.fillWidth: true
            visible: root.expanded && root.hasSettings && !root.on
            text: "Turn it on to reach its settings."
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
        }

        Item {
            implicitHeight: 2
        }
    }
}
