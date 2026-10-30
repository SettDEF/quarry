import qs.modules.common
import QtQuick

/*
 * Horizontal pill tab bar with a sliding indicator behind the active tab —
 * the shell's PillTabBar. Compact (icon-only) when inactive, expanded
 * (icon + label) when active.
 *
 *   PillTabBar {
 *       tabs: [{ id: "hot", icon: "local_fire_department", label: "Hot" }]
 *       current: "hot"
 *       onTabSelected: id => feed.sort = id
 *   }
 */
Item {
    id: root

    required property var tabs               // [{ id, icon, label }]
    required property string current
    signal tabSelected(string id)

    property bool leftAligned: true
    property bool iconOnly: false
    /// Every tab shows its label, not only the active one — for tabs whose
    /// icons say nothing on their own (a user's folders).
    property bool labels: false
    property color activeBackground: Appearance.colors.colSecondaryContainer
    property color activeForeground: Appearance.colors.colOnSecondaryContainer
    property color inactiveForeground: Appearance.colors.colOnLayer1
    property color hoverBackground: Appearance.colors.colLayer1Hover

    /*
     * The "off" colour is the hover colour at zero alpha, NOT `transparent`.
     *
     * `transparent` is rgba(0,0,0,0), so a ColorAnimation from a hover tint to
     * it interpolates the RGB toward BLACK while the alpha falls — the row
     * darkens on the way out and you see a black flash every time the pointer
     * leaves. Fading within one hue has no such midpoint.
     */
    readonly property color offColor: ColorUtils.transparentize(root.hoverBackground, 1)

    property int animDuration: Appearance.animDur(280)

    readonly property int activeIdx: {
        for (let i = 0; i < root.tabs.length; i++)
            if (root.tabs[i].id === root.current)
                return i;
        return 0;
    }

    implicitHeight: 34
    implicitWidth: tabsRow.implicitWidth + 6

    // ── sliding indicator ─────────────────────────────────────────────
    Rectangle {
        id: slidingIndicator
        z: 0
        readonly property Item activeBtn: tabsRow.children[root.activeIdx] ?? null
        readonly property real inset: 3

        x: activeBtn ? tabsRow.x + activeBtn.x + inset : 0
        y: tabsRow.y + inset
        width: activeBtn ? activeBtn.width - inset * 2 : 0
        height: root.height - inset * 2
        radius: height / 2
        color: root.activeBackground

        Behavior on x {
            NumberAnimation {
                duration: root.animDuration
                easing.type: Easing.InOutCubic
            }
        }
        Behavior on width {
            NumberAnimation {
                duration: root.animDuration
                easing.type: Easing.InOutCubic
            }
        }
        Behavior on color {
            animation: Appearance.animation.stateChange.colorAnimation.createObject(this)
        }
    }

    Row {
        id: tabsRow
        z: 1
        anchors.verticalCenter: parent.verticalCenter
        anchors.horizontalCenter: root.leftAligned ? undefined : parent.horizontalCenter
        anchors.left: root.leftAligned ? parent.left : undefined
        anchors.leftMargin: 3
        spacing: 4

        Repeater {
            model: root.tabs

            delegate: Item {
                id: tabDelegate
                required property var modelData
                required property int index

                readonly property bool active: root.current === modelData.id
                // A textless active tab stays a centred icon circle — pill
                // padding would shove a lone icon off the indicator's centre.
                readonly property bool expanded: !root.iconOnly && (active || root.labels) && modelData.label !== undefined && String(modelData.label).length > 0
                readonly property int sidePad: 10

                implicitHeight: root.height
                implicitWidth: expanded ? btnRow.implicitWidth + sidePad * 2 : root.height

                Behavior on implicitWidth {
                    NumberAnimation {
                        duration: root.animDuration
                        easing.type: Easing.InOutCubic
                    }
                }

                HoverHandler {
                    id: pillHov
                    cursorShape: Qt.PointingHandCursor
                }
                TapHandler {
        // Grab on press. The default policy does not, so the press reaches
        // whatever is underneath and acts there while this only sees the tap.
        gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: root.tabSelected(tabDelegate.modelData.id)
                }

                // Icon-only mode drops the label, so surface it on hover.
                Loader {
                    anchors.fill: parent
                    // Also when a tab is simply not the active one: an inactive
                    // pill is an icon with no words, and a row of nine folders
                    // that all look alike is a row nobody can navigate.
                    active: String(tabDelegate.modelData.label ?? "").length > 0 && (root.iconOnly || !tabDelegate.expanded)
                    sourceComponent: StyledToolTip {
                        visible: pillHov.hovered
                        text: tabDelegate.modelData.label
                    }
                }

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 2
                    radius: height / 2
                    color: (pillHov.hovered && !tabDelegate.active) ? root.hoverBackground : root.offColor
                    Behavior on color {
                        animation: Appearance.animation.stateChange.colorAnimation.createObject(this)
                    }
                }

                Row {
                    id: btnRow
                    // Always centred: implicitWidth already reserves the side
                    // padding, so this looks identical to left/right anchoring
                    // without swapping anchors at runtime — which is what
                    // leaves a collapsing tab's icon mispositioned.
                    anchors.centerIn: parent
                    spacing: 6

                    MaterialSymbol {
                        anchors.verticalCenter: parent.verticalCenter
                        text: tabDelegate.modelData.icon ?? ""
                        iconSize: tabDelegate.expanded ? Appearance.font.pixelSize.small : Appearance.font.pixelSize.normal
                        fill: tabDelegate.active ? 1 : 0
                        color: tabDelegate.active ? root.activeForeground : root.inactiveForeground
                    }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: tabDelegate.expanded
                        text: tabDelegate.modelData.label ?? ""
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        font.weight: Font.Medium
                        color: tabDelegate.active ? root.activeForeground : root.inactiveForeground

                        Behavior on color {
                            animation: Appearance.animation.stateChange.colorAnimation.createObject(this)
                        }
                    }
                }
            }
        }
    }
}
