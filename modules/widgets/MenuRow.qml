import qs.modules.common
import QtQuick
import QtQuick.Layouts

// One row in a MenuPopup: leading icon, label, optional trailing check or hint.
Rectangle {
    id: root

    property string text: ""
    property string icon: ""
    property string hint: ""
    property bool checked: false
    property bool destructive: false
    property bool separator: false
    /// Draws the trailing chevron and keeps the label clear of it. The row
    /// itself still reports taps; MenuSubmenu is what turns them into a flyout.
    property bool hasSubmenu: false

    signal triggered

    /*
     * The "off" colour is the hover colour at zero alpha, NOT `transparent`.
     *
     * `transparent` is rgba(0,0,0,0), so a ColorAnimation from a hover tint to
     * it interpolates the RGB toward BLACK while the alpha falls — the row
     * darkens on the way out and you see a black flash every time the pointer
     * leaves. Fading within one hue has no such midpoint.
     */
    readonly property color offColor: ColorUtils.transparentize(Appearance.colors.colLayer4Hover, 1)


    /*
     * Must account for the trailing hint and check, not just the leading label —
     * otherwise the popup sizes itself to the label alone and the right-anchored
     * hint is drawn on top of it.
     */
    readonly property real trailingWidth: (root.hint.length > 0 ? hintLabel.implicitWidth + 14 : 0) + 24
        + (root.hasSubmenu ? 18 : 0)

    // Stretched to the widest row by the popup's ColumnLayout, so the hover
    // highlight and the right-aligned hints line up across the whole menu.
    Layout.fillWidth: true
    implicitWidth: rowContent.implicitWidth + root.trailingWidth + 32
    implicitHeight: root.separator ? 9 : 40
    radius: Appearance.rounding.small

    /*
     * Four states, in the order they override each other: PRESSED beats hover,
     * hover beats checked, checked beats nothing.
     *
     * Hover alone (what this was) makes a menu feel like it is only watching
     * the pointer: a click had no acknowledgement of its own, and the row you
     * had already chosen looked exactly like the three you had not. Morse
     * draws all four, and a menu reads as answering you rather than tracking
     * you. A disabled row keeps its checked ground so it still says what is
     * selected while saying you cannot change it here.
     */
    /*
     * A CHECK IS AN ACCENT, NOT A FILLED BAR.
     *
     * Checked rows were painted in the primary container colour — a saturated
     * bar the full width of the menu. With one selected item that reads as
     * confident; with five of them, which is what a settings menu holding a
     * layout choice and four toggles actually has, the menu becomes a stack of
     * shouting stripes and the row you are pointing at no longer stands out
     * from the rows you are not.
     *
     * So `checked` is now a quiet tint — a third of the way to the hover
     * colour — and the STATE is carried by the icon and the check mark, which
     * take the accent. Hover still beats it, so the pointer is always the
     * brightest thing in the menu, which is the one thing a menu must get
     * right.
     */
    readonly property color checkedGround: ColorUtils.mix(root.offColor, Appearance.colors.colLayer4Hover, 0.45)

    color: root.separator ? root.offColor
        : !root.enabled ? (root.checked ? root.checkedGround : root.offColor)
        : tap.pressed ? Appearance.colors.colLayer4Active
        : hov.hovered ? Appearance.colors.colLayer4Hover
        : root.checked ? root.checkedGround
        : root.offColor

    // Greyed, not hidden: the row is still readable, which is how someone
    // works out WHY it is unavailable.
    opacity: root.enabled || root.checked ? 1 : 0.38

    readonly property color foreground: root.destructive
        ? Appearance.colors.colError
        : Appearance.colors.colOnLayer4

    /// The accent a checked row carries — on its icon and its check mark only.
    readonly property color accent: root.destructive
        ? Appearance.colors.colError
        : root.checked ? Appearance.colors.colPrimary : root.foreground

    Behavior on opacity {
        animation: Appearance.animation.stateChange.numberAnimation.createObject(root)
    }

    Behavior on color {
        // A hover highlight is a STATE, not a movement — see Appearance.stateChange.
        animation: Appearance.animation.stateChange.colorAnimation.createObject(root)
    }

    Divider {
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        visible: root.separator
    }

    Row {
        id: rowContent
        anchors.left: parent.left
        anchors.leftMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.separator
        spacing: 10

        MaterialSymbol {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.icon.length > 0
            text: root.icon
            iconSize: Appearance.font.pixelSize.normal
            fill: root.checked ? 1 : 0
            color: root.accent
        }

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            text: root.text
            font.pixelSize: Appearance.font.pixelSize.small
            font.weight: root.checked ? Font.Medium : Font.Normal
            color: root.foreground
        }
    }

    StyledText {
        id: hintLabel
        // Anchored to the check slot whether or not the tick is showing: an
        // invisible Item still has geometry, so every hint in the menu shares
        // one right edge instead of jumping when a row becomes checked.
        anchors.right: root.hasSubmenu ? trailingChevron.left : trailingCheck.left
        anchors.rightMargin: 4
        anchors.verticalCenter: parent.verticalCenter
        visible: root.hint.length > 0 && !root.separator
        text: root.hint
        font.pixelSize: Appearance.font.pixelSize.smaller
        color: Appearance.colors.colSubtext
    }

    // A chevron says "there is more this way" -- the one thing that separates
    // a row that ACTS from a row that OPENS. Without it a submenu row looks
    // like an export that silently does nothing.
    MaterialSymbol {
        id: trailingChevron
        anchors.right: parent.right
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        visible: root.hasSubmenu && !root.separator
        text: "chevron_right"
        iconSize: Appearance.font.pixelSize.normal
        color: Appearance.colors.colSubtext
    }

    MaterialSymbol {
        id: trailingCheck
        anchors.right: parent.right
        anchors.rightMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        visible: root.checked && !root.separator
        text: "check"
        iconSize: Appearance.font.pixelSize.normal
        color: root.foreground
    }

    HoverHandler {
        id: hov
        enabled: !root.separator
        cursorShape: Qt.PointingHandCursor
    }

    TapHandler {
        id: tap
        enabled: !root.separator
        // GRAB THE PRESS. The default policy (DragThreshold) does not take an
        // exclusive grab, so the press fell through to the gallery underneath
        // and acted on whatever tile was there — while hover, which travels a
        // different path, still highlighted the row. A menu row that lights up
        // and then does something else entirely is the worst of both.
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onTapped: root.triggered()
    }
}
