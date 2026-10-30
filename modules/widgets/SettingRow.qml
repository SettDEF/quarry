import qs.modules.common
import QtQuick
import QtQuick.Layouts

/*
 * One setting: what it is, what it does to you, and what it is set to.
 *
 * It can hold a control now. Carrying only a switch is why every number was a
 * row you clicked to cycle — tile size stepped by 40 and wrapped at 420 with
 * nothing saying it would. It also matches searches itself, so no second list
 * of names can drift out of step with the rows it describes.
 */
Rectangle {
    id: root

    property string icon: ""
    property string label: ""
    property string description: ""
    property string value: ""
    property bool available: true
    /// Why it is unavailable, when the reason is not "unfinished": the seed row
    /// is off because you are not shuffling, not because the app is broken.
    property string unavailableNote: "not wired up"
    property bool destructive: false
    property bool hasSwitch: false
    property bool checked: false

    /// Extra words the row answers to. The label has to read as English; the
    /// search has to find it from whatever word was on your mind ("nsfw").
    property string terms: ""

    /// The caller's own reason to hide the row. Separate from `visible`, which
    /// the search owns — bound to both, they would overwrite each other.
    property bool shown: true
    /// Lower case, already trimmed. Empty shows everything.
    property string filter: ""

    readonly property bool matched: root.filter.length === 0 || (root.label + " " + root.description + " " + root.terms + " " + root.value).toLowerCase().indexOf(root.filter) >= 0

    /// What the row wants, independent of whether its card is on screen —
    /// which is what the card counts to decide whether to be on screen.
    readonly property bool wanted: root.shown && root.matched
    visible: root.wanted

    signal clicked

    /// Hover colour at zero alpha, not `transparent`: fading to rgba(0,0,0,0)
    /// drags the RGB to black on the way out and flashes dark.
    readonly property color offColor: ColorUtils.transparentize(Appearance.colors.colLayer2Hover, 1)

    signal toggled(bool on)

    /// Children land on the right, where the switch would be: a slider, a
    /// stepper, a row of chips.
    default property alias control: slot.data
    readonly property bool hasControl: slot.children.length > 0
    /// A slider has no natural width, so a row hosting one says how much to give.
    property real controlWidth: 0

    /// False when a control owns the press, and by hand on rows that only state
    /// a fact — a row that lights up and answers nothing reads as broken.
    property bool interactive: !root.hasControl

    readonly property color _fg: root.destructive ? Appearance.colors.colError : Appearance.colors.colOnLayer1

    Layout.fillWidth: true
    implicitHeight: Math.max(48, body.implicitHeight + 16)
    radius: Appearance.rounding.small
    // Pressed beats hover: a button that never acknowledges the press leaves
    // you wondering whether the click landed.
    color: !root.available || !root.interactive ? root.offColor : rowTap.pressed ? Appearance.colors.colLayer2Active : hover.hovered ? Appearance.colors.colLayer2Hover : root.offColor
    Behavior on color {
        animation: Appearance.animation.stateChange.colorAnimation.createObject(root)
    }

    HoverHandler {
        id: hover
        enabled: root.available && root.interactive
        cursorShape: Qt.PointingHandCursor
    }
    TapHandler {
        id: rowTap
        enabled: root.available && root.interactive
        // Grab on press: a row that lights up and then acts on whatever is
        // underneath is worse than one that does nothing.
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onTapped: {
            if (root.hasSwitch)
                root.toggled(!root.checked);
            else
                root.clicked();
        }
    }

    RowLayout {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        spacing: 12

        MaterialSymbol {
            visible: root.icon.length > 0
            Layout.alignment: Qt.AlignVCenter
            text: root.icon
            iconSize: Appearance.font.pixelSize.larger
            color: root.available ? root._fg : Appearance.colors.colSubtext
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 1

            StyledText {
                Layout.fillWidth: true
                text: root.label
                font.pixelSize: Appearance.font.pixelSize.small
                color: root.available ? root._fg : Appearance.colors.colSubtext
                elide: Text.ElideRight
            }
            // Says what changes, not what the label already said.
            StyledText {
                Layout.fillWidth: true
                visible: root.description.length > 0
                text: root.description
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colSubtext
                wrapMode: Text.WordWrap
            }
        }

        StyledText {
            // Shown beside a control too: a slider with no number is a guess.
            visible: root.available && root.value.length > 0 && !root.hasSwitch
            text: root.value
            font.family: Appearance.font.family.monospace
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
        }

        RowLayout {
            id: slot
            visible: root.available && root.hasControl
            Layout.alignment: Qt.AlignVCenter
            Layout.fillWidth: false
            Layout.preferredWidth: root.controlWidth > 0 ? root.controlWidth : implicitWidth
            spacing: 8
        }

        StyledSwitch {
            visible: root.available && root.hasSwitch
            Layout.alignment: Qt.AlignVCenter
            checked: root.checked
            // The row is the target; a second handler here toggles twice.
            interactive: false
        }

        // The honest marker: a label saying why, not a dead control.
        Rectangle {
            visible: !root.available
            Layout.alignment: Qt.AlignVCenter
            implicitWidth: notYet.implicitWidth + 14
            implicitHeight: 22
            radius: height / 2
            color: Appearance.colors.colLayer2

            StyledText {
                id: notYet
                anchors.centerIn: parent
                text: root.unavailableNote
                font.pixelSize: Appearance.font.pixelSize.smallest
                color: Appearance.colors.colSubtext
            }
        }
    }
}
