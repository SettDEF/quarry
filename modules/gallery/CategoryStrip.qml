import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

/*
 * SOMEWHERE TO START — BEHIND A BUTTON.
 *
 * A query bar is only useful to someone who already knows what to type, and the
 * sources publish their own answer to "what do people come here for". But those
 * answers are a shelf of two dozen words, and a shelf that is always open is
 * just clutter above the pictures: worth one line, not six.
 *
 * It also only offers itself where the vocabulary applies. The terms come from
 * pfps.gg's own categories, so a wallhaven or booru result gets nothing — a
 * list of profile-picture subjects is noise in front of a wallpaper.
 */
ColumnLayout {
    id: root

    property bool open: false

    /// Only the ACTIVE source's own categories.
    ///
    /// A site's categories are its table of contents and mean nothing away from
    /// it — showing pfps.gg's profile-picture subjects above a wallpaper search
    /// is noise, and showing every source's at once is a screenful of it. So
    /// this is empty unless you are on a source's page.
    readonly property var groups: (Catalog.suggestions || [])
        .filter(g => g.source === Catalog.source)

    readonly property bool relevant: Catalog.source.length > 0
        && root.groups.length > 0
        && Catalog.query.trim().length === 0

    visible: relevant
    spacing: 4

    MenuRow {
        Layout.fillWidth: true
        text: "Categories"
        icon: root.open ? "expand_more" : "chevron_right"
        hint: Catalog.source
        onTriggered: root.open = !root.open
    }

    // Height only, so opening is a reveal rather than a rebuild.
    Item {
        Layout.fillWidth: true
        clip: true
        // clip only stops painting. `inner` keeps its full implicit height and
        // sits at its normal position regardless of this wrapper's collapsed
        // height, so its PillTabs stayed pressable at their real geometry —
        // right where the panel below slides up to fill the reclaimed space.
        enabled: root.open
        implicitHeight: root.open ? inner.implicitHeight : 0
        Behavior on implicitHeight {
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
        }

        ColumnLayout {
            id: inner
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: 6

            Repeater {
                model: root.groups

                delegate: ColumnLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 3

                    StyledText {
                        text: modelData.group || ""
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                    }

                    Flow {
                        Layout.fillWidth: true
                        spacing: 5

                        Repeater {
                            model: modelData.terms

                            delegate: PillTab {
                                required property string modelData
                                label: modelData
                                accent: "secondary"
                                // The slot's constraint stays in force, so
                                // "Avatar" + "naruto" is still square.
                                onTriggered: {
                                    const slot = Slots.current;
                                    Catalog.query = slot
                                        ? `${modelData} ${slot.query}`
                                        : modelData;
                                    root.open = false;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
