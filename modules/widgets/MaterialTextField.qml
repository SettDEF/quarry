import qs.modules.common
import QtQuick
import QtQuick.Controls

/*
 * M3 filled text field with a leading icon and clear button.
 *
 * Hand-drawn rather than using Controls.Material so the container tones come
 * from the live palette instead of Material's own theme, which doesn't know
 * about tinct's colours.
 */
Rectangle {
    id: root

    property alias text: input.text
    property alias placeholder: placeholderLabel.text
    property alias echoMode: input.echoMode
    property alias readOnly: input.readOnly
    property string leadingIcon: ""
    property bool showClear: true
    property real trailingSpace: 0
    property real fieldRadius: Appearance.rounding.full
    /*
     * The bottom corners, separately.
     *
     * A field with something attached below it — a completions list — has to
     * stop being a pill at the join, or the two read as two things with a
     * pinch between them. Defaults to `fieldRadius`, so nothing changes for a
     * field that stands alone.
     */
    property real bottomRadius: root.fieldRadius

    signal accepted(string text)
    signal edited(string text)
    signal cleared

    function forceFieldFocus() {
        input.forceActiveFocus();
    }
    /// Focus AND select, so typing replaces what is there. The two are always
    /// wanted together when a shortcut jumps to a field you have already used.
    function focusAndSelect() {
        input.forceActiveFocus();
        input.selectAll();
    }
    function clear() {
        input.text = "";
        root.cleared();
    }

    implicitHeight: 46
    implicitWidth: 260
    radius: root.fieldRadius
    bottomLeftRadius: root.bottomRadius
    bottomRightRadius: root.bottomRadius
    color: Appearance.colors.colSurfaceContainerHigh
    border.width: input.activeFocus ? 2 : 0
    border.color: Appearance.colors.colPrimary

    Behavior on color {
        animation: Appearance.animation.stateChange.colorAnimation.createObject(root)
    }

    MaterialSymbol {
        id: leading
        visible: root.leadingIcon.length > 0
        anchors.left: parent.left
        anchors.leftMargin: 14
        anchors.verticalCenter: parent.verticalCenter
        text: root.leadingIcon
        iconSize: Appearance.font.pixelSize.larger
        color: input.activeFocus ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer1
    }

    TextInput {
        id: input
        /*
         * THE WHOLE FIELD IS THE FIELD.
         *
         * This was anchored by its vertical CENTRE with no height, so the item
         * that actually takes the click was one text line tall — a thin band
         * across the middle of a 48px control. Clicking the field anywhere else
         * hit the background rectangle, which does nothing, so you clicked
         * again, and again, until you happened to land on the strip. It read as
         * the field ignoring you at random.
         *
         * Filling the height makes the hit area the control you can see.
         * `AlignVCenter` below keeps the text where it was.
         */
        anchors {
            left: leading.visible ? leading.right : parent.left
            leftMargin: leading.visible ? 10 : 18
            right: clearButton.visible ? clearButton.left : parent.right
            // Callers can reserve space on the right for a control of their own
            // (the query bar puts its filter button inside the field).
            rightMargin: 10 + root.trailingSpace
            top: parent.top
            bottom: parent.bottom
        }

        // QtRendering here: NativeRendering makes small placeholder text and
        // the selection highlight look wrong inside a filled container.
        renderType: Text.QtRendering
        clip: true
        color: Appearance.colors.colOnSurface
        selectionColor: Appearance.colors.colSecondaryContainer
        selectedTextColor: Appearance.colors.colOnSecondaryContainer
        selectByMouse: true
        verticalAlignment: TextInput.AlignVCenter

        font {
            family: Appearance.font.family.main
            pixelSize: Appearance.font.pixelSize.small
            variableAxes: Appearance.font.variableAxes.main
        }

        onAccepted: root.accepted(input.text)
        onTextEdited: root.edited(input.text)

        StyledText {
            id: placeholderLabel
            anchors.verticalCenter: parent.verticalCenter
            visible: input.text.length === 0
            color: Appearance.colors.colOutline
            font.pixelSize: Appearance.font.pixelSize.small
        }
    }

    IconButton {
        id: clearButton
        anchors.right: parent.right
        anchors.rightMargin: 5
        anchors.verticalCenter: parent.verticalCenter
        visible: root.showClear && input.text.length > 0
        icon: "close"
        size: 32
        iconSize: Appearance.font.pixelSize.normal
        onClicked: root.clear()
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        cursorShape: Qt.IBeamCursor
    }
}
