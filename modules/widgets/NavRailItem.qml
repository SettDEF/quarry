import Qt5Compat.GraphicalEffects
import QtQuick
import QtQuick.Layouts
import qs.modules.common

/*
 * One destination in the rail: an icon, a name, and how much is behind it.
 *
 * Active reads as a filled pill in the secondary container colour — the
 * Material 3 navigation-drawer treatment, so it sits with the rest of the
 * desktop rather than inventing a highlight of its own. Collapsed, the name
 * moves into a tooltip and the icon stays in exactly the same place, so the
 * rail can narrow without anything jumping under the pointer.
 */
Rectangle {
    id: root

    property bool expanded: true
    property string icon: ""
    /*
     * A picture in place of the glyph — a chat's own photo, a person's face.
     *
     * A rail of identical grey glyphs is a rail you have to READ, one row at
     * a time, and every messaging client on earth solves that with the
     * picture. The glyph stays as the fallback: no photo, or one that has not
     * landed yet.
     */
    property string picture: ""
    /// An app-style icon tile (a lens's `icon.svg`); drawn as is, not tinted or masked.
    property string iconImage: ""
    property string label: ""
    property string count: ""
    /// A second line under the label — what a row is, when the label is only
    /// its name ("/po/" says nothing; "Papercraft & Origami" does).
    property string sublabel: ""
    property string trailingIcon: ""
    property bool active: false
    /// False folds the row away with its group: height and opacity together,
    /// so the rows below slide up instead of jumping.
    property bool shown: true
    property real fold: root.shown ? 1 : 0
    readonly property color hoverTint: Appearance.colors.colLayer1Hover
    readonly property color fg: root.active ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer0
    /*
     * Labels follow the rail's width, not a timer: fully faded until there is
     * room for a word, fully there by the time the rail is open. Nothing pops.
     * `openness` is 0…1 from NavRail; the text starts appearing a third of the
     * way open, when it would otherwise be clipped mid-letter.
     */
    property real openness: root.expanded ? 1 : 0
    readonly property real textOpacity: Math.max(0, Math.min(1, (root.openness - 0.35) / 0.65))

    signal triggered()
    /// Right-clicked, in this row's own coordinates. The rail decides what a
    /// menu on this row should say — see `navMenu` on Lens.
    signal contextRequested(real x, real y)

    implicitHeight: Math.round((root.sublabel.length > 0 ? 50 : 40) * root.fold)
    opacity: root.fold
    visible: root.fold > 0.01
    radius: Math.min(20, height / 2)
    color: root.active ? (mouse.containsPress ? Appearance.colors.colSecondaryContainerActive : mouse.containsMouse ? Appearance.colors.colSecondaryContainerHover : Appearance.colors.colSecondaryContainer) : (mouse.containsPress ? Appearance.colors.colLayer1Active : mouse.containsMouse ? root.hoverTint : ColorUtils.transparentize(root.hoverTint, 1))

    MaterialSymbol {
        id: glyph

        // One position in both states: where it sits centred in the narrow
        // rail. A glyph that moved when the rail opened would slide sideways
        // under the pointer.
        x: 15
        anchors.verticalCenter: parent.verticalCenter
        visible: !portrait.shown && !tile.shown
        text: root.icon
        iconSize: 22
        fill: root.active ? 1 : 0
        color: root.fg
    }

    // Same spot and size as the portrait below; the tile carries its own corners.
    Image {
        id: tile

        readonly property bool shown: root.iconImage.length > 0 && status === Image.Ready && !portrait.shown

        x: 15 - 3
        width: 28
        height: 28
        anchors.verticalCenter: parent.verticalCenter
        visible: tile.shown
        source: root.iconImage
        sourceSize.width: 56
        sourceSize.height: 56
        asynchronous: true
        smooth: true
    }

    // Exactly where the glyph sits, at the size the glyph occupies, so a row
    // with a photo and a row without line up.
    Rectangle {
        id: portrait

        readonly property bool shown: root.picture.length > 0 && face.status === Image.Ready

        x: 15 - 3
        width: 28
        height: 28
        radius: 14
        anchors.verticalCenter: parent.verticalCenter
        visible: portrait.shown
        color: "transparent"
        clip: true

        Image {
            id: face

            anchors.fill: parent
            source: root.picture
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            smooth: true
            sourceSize.width: 56
            sourceSize.height: 56
            layer.enabled: true

            layer.effect: OpacityMask {

                maskSource: Rectangle {
                    width: portrait.width
                    height: portrait.height
                    radius: portrait.radius
                }

            }

        }

    }

    Column {
        opacity: root.textOpacity
        visible: opacity > 0
        anchors.left: glyph.right
        anchors.leftMargin: 12
        anchors.right: tail.left
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        spacing: -1

        StyledText {
            width: parent.width
            text: root.label
            elide: Text.ElideRight
            font.pixelSize: Appearance.font.pixelSize.small
            font.weight: root.active ? Font.DemiBold : Font.Normal
            color: root.fg
        }

        StyledText {
            width: parent.width
            visible: root.sublabel.length > 0
            text: root.sublabel
            elide: Text.ElideRight
            font.pixelSize: Appearance.font.pixelSize.smallest
            color: root.active ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colSubtext
            opacity: 0.85
        }

    }

    Row {
        id: tail

        opacity: root.textOpacity
        visible: opacity > 0
        anchors.right: parent.right
        anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        spacing: 4

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            text: root.count
            visible: text.length > 0
            font.pixelSize: Appearance.font.pixelSize.smaller
            font.family: Appearance.font.family.numbers
            color: root.active ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colSubtext
        }

        MaterialSymbol {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.trailingIcon.length > 0
            text: root.trailingIcon
            iconSize: 15
            color: Appearance.colors.colSubtext
        }

    }

    MouseArea {
        id: mouse

        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: (event) => {
            if (event.button === Qt.RightButton) {
                root.contextRequested(event.x, event.y);
                return ;
            }
            root.triggered();
        }
    }

    StyledToolTip {
        // Beside the rail: below would land on the next row.
        side: Qt.RightEdge
        visible: !root.expanded && mouse.containsMouse
        text: root.count.length > 0 ? `${root.label} · ${root.count}` : root.label
    }

    Behavior on fold {
        NumberAnimation {
            duration: Appearance.animDur(240)
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Appearance.animationCurves.emphasizedDecel
        }

    }
    // Taller when it carries a second line, so the two never crowd.

    Behavior on color {
        animation: Appearance.animation.stateChange.colorAnimation.createObject(root)
    }

}
