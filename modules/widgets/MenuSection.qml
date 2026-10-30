import qs.modules.common
import QtQuick
import QtQuick.Layouts

/*
 * A LABEL FOR A GROUP OF MENU ROWS.
 *
 * The settings menu had grown to four different jobs in one flat list — pick a
 * layout, toggle what is shown, run an action, enable an extension — separated
 * only by hairlines. A hairline says "these are apart"; it does not say what
 * either side of it IS, so every row had to be read to find the one you wanted.
 *
 * Small, dim and set in caps: a section label is scaffolding for the eye and
 * should never compete with the rows it introduces.
 */
Item {
    id: root

    property string text: ""
    /// Suppressed for the first section, where a rule above it would sit
    /// against the menu's own edge.
    property bool rule: true

    Layout.fillWidth: true
    implicitHeight: label.implicitHeight + (root.rule ? 17 : 9)

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: 4
        anchors.leftMargin: 10
        anchors.rightMargin: 10
        height: 1
        visible: root.rule
        color: Appearance.colors.colOutlineVariant
        opacity: 0.5
    }

    StyledText {
        id: label
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.leftMargin: 12
        anchors.bottomMargin: 3
        text: root.text.toUpperCase()
        font.pixelSize: Appearance.font.pixelSize.smallest
        font.weight: Font.DemiBold
        font.letterSpacing: 0.6
        color: Appearance.colors.colSubtext
        opacity: 0.75
    }
}
