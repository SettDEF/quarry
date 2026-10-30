import qs.modules.common
import qs.modules.widgets
import QtQuick
import QtQuick.Layouts

/*
 * A section name in the rail. Collapsed, the fold arrow takes its place: it
 * still separates the groups, and unlike the hairline that used to stand here
 * it says which way the group is — open or folded — and that it can be clicked
 * at all. A folded group drew no rule whatsoever, so in the narrow rail whole
 * sections went missing with nothing to show they were there.
 */
Item {
    id: root

    property string text: ""
    property bool expanded: true
    property real openness: root.expanded ? 1 : 0
    /// Whether the group under this heading is unfolded.
    property bool open: true
    /// What is selected inside the group, shown beside a folded heading.
    property string summary: ""
    /// How many rows sit under this heading; -1 when the caller does not say.
    property int rows: -1
    /// Collapsed, the arrow stands in for the words — but an empty group is
    /// not a group, and gets no mark at all.
    readonly property bool mark: root.rows !== 0
    /// Whether this heading folds anything at all. A lens's section captions
    /// pass an empty `onToggled` — nothing happens — while the chevron, the
    /// hover tint, the hand cursor and the "Hide …" tooltip all promised that
    /// it did: four separate signals for an action that was never there.
    property bool foldable: true

    signal toggled

    Layout.fillWidth: true
    // Expanded, a heading is always its full height; the extra 17 is the
    // arrow's slot in the narrow rail, which an empty group does not get.
    implicitHeight: 17 * root.openness + (root.mark ? 17 : 17 * root.openness)

    Rectangle {
        id: hit
        anchors.fill: parent
        anchors.topMargin: Math.round(6 * root.openness)
        radius: 10
        color: root.foldable && captionMouse.containsMouse ? Appearance.colors.colLayer1Hover : ColorUtils.transparentize(Appearance.colors.colLayer1Hover, 1)
        Behavior on color {
            animation: Appearance.animation.stateChange.colorAnimation.createObject(hit)
        }
    }

    Row {
        opacity: Math.max(0, Math.min(1, (root.openness - 0.35) / 0.65))
        visible: opacity > 0
        anchors.left: parent.left
        anchors.leftMargin: 14
        anchors.right: parent.right
        anchors.rightMargin: 10
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 6
        spacing: 6

        StyledText {
            id: captionText
            text: root.text
            font.pixelSize: Appearance.font.pixelSize.smaller
            font.weight: Font.Medium
            color: Appearance.colors.colSubtext
        }
        StyledText {
            visible: !root.open && root.summary.length > 0
            width: Math.max(0, parent.width - captionText.implicitWidth - chevron.width - 12)
            text: "· " + root.summary
            elide: Text.ElideRight
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            opacity: 0.8
        }
    }

    MaterialSymbol {
        id: chevron
        opacity: Math.max(0, Math.min(1, (root.openness - 0.35) / 0.65))
        visible: opacity > 0 && root.foldable
        anchors.right: parent.right
        anchors.rightMargin: 10
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 4
        text: "expand_more"
        iconSize: 18
        color: Appearance.colors.colSubtext
        rotation: root.open ? 0 : -90
        Behavior on rotation {
            NumberAnimation {
                duration: Appearance.animDur(200)
                easing.type: Easing.OutCubic
            }
        }
    }

    MouseArea {
        id: captionMouse
        anchors.fill: parent
        enabled: root.foldable
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggled()
    }

    StyledToolTip {
        side: Qt.RightEdge
        visible: root.foldable && root.openness < 0.5 && captionMouse.containsMouse
        text: root.open ? `Hide ${root.text.toLowerCase()}` : `Show ${root.text.toLowerCase()}`
    }

    MaterialSymbol {
        // The same arrow the wide rail uses, at the same angle, so folding a
        // group means one thing in both states.
        // A fixed heading still has to separate its section in the narrow
        // rail — a different glyph, so it reads as a rule and not as an arrow
        // that will do something when it is pressed.
        opacity: (root.mark ? 1 - root.openness : 0) * (root.foldable && captionMouse.containsMouse ? 1 : 0.55)
        visible: opacity > 0
        anchors.centerIn: parent
        text: root.foldable ? "expand_more" : "more_horiz"
        iconSize: 16
        color: Appearance.colors.colSubtext
        rotation: root.open ? 0 : -90
        Behavior on rotation {
            NumberAnimation {
                duration: Appearance.animDur(200)
                easing.type: Easing.OutCubic
            }
        }
        Behavior on opacity {
            NumberAnimation {
                duration: Appearance.animDur(120)
            }
        }
    }
}
