import qs.modules.common
import qs.services
import QtQuick
import QtQuick.Effects
import QtQuick.Layouts

// M3 snackbar, driven by the Toast singleton. Slides up from the bottom.
Item {
    id: root

    readonly property var entry: Toast.current
    readonly property bool shown: Toast.active

    implicitHeight: bar.implicitHeight
    visible: bar.opacity > 0
    /*
     * ABOVE EVERYTHING, INCLUDING A SHEET.
     *
     * A toast is the app answering something you just did, so it has to be
     * readable whatever is open. Declaration order gave it that for free until
     * Sheet took a `z` of its own; without this line an "Export finished"
     * lands behind the export sheet that started it.
     */
    z: 1000

    Rectangle {
        id: bar
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.shown ? 20 : -height - 10

        implicitWidth: Math.min(root.width - 48, barContent.implicitWidth + 40)
        implicitHeight: Math.max(52, barContent.implicitHeight + 22)
        // The shell's notification card: a full pill, the high surface layer,
        // a hairline edge and its soft close shadow.
        radius: height / 2
        opacity: root.shown ? 1 : 0

        color: root.entry && root.entry.isError ? Appearance.colors.colErrorContainer : Appearance.colors.colLayer3
        border.width: 1
        border.color: Appearance.colors.colLayer0Border

        RectangularShadow {
            anchors.fill: parent
            z: -1
            radius: parent.radius
            blur: 14
            spread: 1
            offset: Qt.vector2d(0, 2)
            color: Appearance.colors.colShadow
        }

        readonly property color foreground: root.entry && root.entry.isError ? Appearance.colors.colOnErrorContainer : Appearance.colors.colOnSurface

        Behavior on anchors.bottomMargin {
            NumberAnimation {
                duration: Appearance.animDur(380)
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.animationCurves.expressiveDefaultSpatial
            }
        }
        Behavior on opacity {
            NumberAnimation {
                duration: Appearance.animation.elementMoveFast.duration
            }
        }

        RowLayout {
            id: barContent
            anchors.fill: parent
            anchors.leftMargin: 20
            anchors.rightMargin: 8
            spacing: 12

            MaterialSymbol {
                visible: root.entry ? root.entry.isError : false
                text: "error"
                iconSize: Appearance.font.pixelSize.larger
                color: bar.foreground
            }

            StyledText {
                Layout.fillWidth: true
                Layout.maximumWidth: 520
                text: root.entry ? root.entry.message : ""
                wrapMode: Text.WordWrap
                font.pixelSize: Appearance.font.pixelSize.small
                color: bar.foreground
            }

            TextButton {
                visible: root.entry ? String(root.entry.actionText).length > 0 : false
                text: root.entry ? root.entry.actionText : ""
                variant: "text"
                onClicked: Toast.runAction()
            }

            IconButton {
                icon: "close"
                size: 34
                iconSize: Appearance.font.pixelSize.normal
                iconColor: bar.foreground
                onClicked: Toast.dismiss()
            }
        }
    }
}
