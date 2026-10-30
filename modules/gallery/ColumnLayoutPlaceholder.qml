import qs.modules.common
import qs.modules.widgets
import QtQuick

// One centred line of explanation. Small enough to be its own file so the 3D
// view does not grow a layout import for a single string.
Item {
    id: root

    property string text: ""

    implicitWidth: label.implicitWidth
    implicitHeight: label.implicitHeight

    StyledText {
        id: label
        anchors.centerIn: parent
        text: root.text
        color: Appearance.colors.colSubtext
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        width: Math.min(implicitWidth, 320)
    }
}
