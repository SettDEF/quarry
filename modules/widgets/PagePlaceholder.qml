import qs.modules.common
import QtQuick
import QtQuick.Layouts

// Empty / error / first-run state: big glyph, headline, explanation, action.
Item {
    id: root

    property string icon: "inbox"
    property string title: ""
    property string description: ""
    property string actionText: ""
    property string actionIcon: ""
    property bool busy: false

    signal actionTriggered

    ColumnLayout {
        anchors.centerIn: parent
        /*
         * CLAMPED AT ZERO.
         *
         * A caller that anchors this with `centerIn` gives it a position and no
         * SIZE, so root.width is 0 and this came out at -64: the layout gave
         * every fillWidth child no width at all, and the headline and the
         * explanation were drawn on top of each other at the centre point. Two
         * sentences in the same 20 pixels, unreadable, in the one state whose
         * whole job is to explain what happened.
         */
        width: Math.max(240, Math.min(root.width - 64, 420))
        spacing: 6

        LoadingIndicator {
            Layout.alignment: Qt.AlignHCenter
            Layout.bottomMargin: 10
            visible: root.busy
            running: root.busy
            size: 40
        }

        MaterialSymbol {
            Layout.alignment: Qt.AlignHCenter
            visible: !root.busy
            text: root.icon
            iconSize: 64
            color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.45)
        }

        StyledText {
            Layout.fillWidth: true
            Layout.topMargin: 8
            visible: root.title.length > 0
            text: root.title
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            font.pixelSize: Appearance.font.pixelSize.larger
            font.weight: Font.Medium
            font.family: Appearance.font.family.title
            color: Appearance.colors.colOnLayer1
        }

        StyledText {
            Layout.fillWidth: true
            visible: root.description.length > 0
            text: root.description
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            lineHeight: 1.25
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colSubtext
        }

        TextButton {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 14
            visible: root.actionText.length > 0
            text: root.actionText
            icon: root.actionIcon
            variant: "tonal"
            onClicked: root.actionTriggered()
        }
    }
}
