import qs.modules.common
import qs.services
import QtQuick
import QtQuick.Layouts

/*
 * One category of sources, as a card that starts shut.
 *
 * Thirty-six identical rows in one list is not a setting you can find; seven
 * headings you can read in a glance is. The header carries the two facts you
 * would have opened it for — how many are on, and how much the category has
 * actually contributed — and its switch turns the whole lot on or off, which
 * is the thing you came here to do nine times out of ten.
 *
 * Nothing inside is built until it is opened or searched for.
 */
ColumnLayout {
    id: root

    required property string category
    property string label: ""
    property string icon: "cloud"
    /// Source ids in this category, already in the order they should appear.
    property var ids: []
    /// id -> rows in the catalogue, and the biggest of them, computed once by
    /// the panel: a find() per delegate is 1300 comparisons on every refresh.
    property var rowsById: ({})
    property int maxRows: 0

    /// Lower case, already trimmed.
    property string filter: ""
    /// Shown instead of the rows — adult sources while adult results are off.
    property bool locked: false
    property string lockedNote: ""

    property bool expanded: false

    readonly property var matchedIds: {
        if (root.filter.length === 0)
            return root.ids;
        return root.ids.filter(id => (id + " " + root.category).toLowerCase().indexOf(root.filter) >= 0);
    }
    // A search opens what it found; closing it again by hand is one more step
    // between you and the row you asked for.
    readonly property bool open_: root.expanded || root.filter.length > 0

    readonly property int onCount: {
        let n = 0;
        for (let i = 0; i < root.ids.length; i++)
            if ((Catalog.sourcePrefMap[root.ids[i]] || {}).enabled === true)
                n++;
        return n;
    }
    readonly property int totalRows: {
        let n = 0;
        for (let i = 0; i < root.ids.length; i++)
            n += root.rowsById[root.ids[i]] || 0;
        return n;
    }

    function _compact(n) {
        if (!(n > 0))
            return "nothing yet";
        if (n >= 1000000)
            return (n / 1000000).toFixed(1) + "M";
        if (n >= 1000)
            return (n / 1000).toFixed(n >= 10000 ? 0 : 1) + "k";
        return `${n}`;
    }

    /// All on unless they already are, then all off. A tri-state switch would
    /// need a third press to say what two can, and nobody reads the third.
    function _toggleAll() {
        const on = root.onCount < root.ids.length;
        for (let i = 0; i < root.ids.length; i++)
            Catalog.setSourcePref({
                "id": root.ids[i],
                "enabled": on
            });
    }

    Layout.fillWidth: true
    spacing: 0
    /// Stated rather than read back off `visible`, so the panel can count the
    /// cards it is about to hide. See SettingSection.
    readonly property bool wanted: root.ids.length > 0 && root.matchedIds.length > 0
    visible: root.wanted

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: head.implicitHeight + (root.open_ ? body.implicitHeight + 8 : 0)
        Behavior on implicitHeight {
            animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
        }
        radius: Appearance.rounding.normal
        color: Appearance.colors.colLayer1
        clip: true

        // Header. Unlike a source row, the header opens the group rather than
        // switching it: shutting a category you meant to read would be worse.
        Rectangle {
            id: head
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            implicitHeight: 46
            height: implicitHeight
            radius: Appearance.rounding.normal
            color: headTap.pressed ? Appearance.colors.colLayer2Active : headHover.hovered ? Appearance.colors.colLayer2Hover : ColorUtils.transparentize(Appearance.colors.colLayer2Hover, 1)
            Behavior on color {
                animation: Appearance.animation.stateChange.colorAnimation.createObject(this)
            }

            HoverHandler {
                id: headHover
                cursorShape: Qt.PointingHandCursor
            }
            TapHandler {
                id: headTap
                gesturePolicy: TapHandler.ReleaseWithinBounds
                onTapped: root.expanded = !root.expanded
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 8
                spacing: 12

                MaterialSymbol {
                    Layout.alignment: Qt.AlignVCenter
                    text: root.icon
                    iconSize: Appearance.font.pixelSize.larger
                    fill: root.onCount > 0 ? 1 : 0
                    color: root.onCount > 0 ? Appearance.colors.colOnLayer1 : Appearance.colors.colSubtext
                }

                StyledText {
                    text: root.label
                    font.pixelSize: Appearance.font.pixelSize.small
                    font.weight: Font.DemiBold
                    color: Appearance.colors.colOnLayer1
                }

                StyledText {
                    Layout.fillWidth: true
                    text: `${root.onCount} of ${root.ids.length} on · ${root._compact(root.totalRows)}`
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                    elide: Text.ElideRight
                }

                StyledSwitch {
                    Layout.alignment: Qt.AlignVCenter
                    // Its own target, because the header opens the group.
                    checked: root.onCount === root.ids.length && root.ids.length > 0
                    enabled: !root.locked
                    onToggled: root._toggleAll()
                }

                MaterialSymbol {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.rightMargin: 6
                    text: "expand_more"
                    iconSize: Appearance.font.pixelSize.large
                    color: Appearance.colors.colSubtext
                    rotation: root.open_ ? 180 : 0
                    Behavior on rotation {
                        animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
                    }
                }
            }
        }

        ColumnLayout {
            id: body
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: head.bottom
            anchors.leftMargin: 6
            anchors.rightMargin: 6
            spacing: 4
            opacity: root.open_ ? 1 : 0
            visible: opacity > 0
            Behavior on opacity {
                animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
            }

            StyledText {
                Layout.fillWidth: true
                Layout.leftMargin: 8
                Layout.rightMargin: 8
                Layout.topMargin: 2
                Layout.bottomMargin: 6
                visible: root.locked
                text: root.lockedNote
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colSubtext
                wrapMode: Text.WordWrap
            }

            Repeater {
                // Empty while shut: this is what keeps 36 rows from being built
                // the moment the panel opens.
                model: root.open_ && !root.locked ? root.matchedIds : []

                delegate: SourceRow {
                    required property string modelData

                    // Read through the map, so a refresh changes VALUES on a row
                    // that is already on screen instead of replacing it.
                    readonly property var pref: Catalog.sourcePrefMap[modelData] || ({})

                    sourceId: modelData
                    category: pref.category || root.category
                    video: pref.video === true
                    rows: root.rowsById[modelData] || 0
                    share: root.maxRows > 0 ? (root.rowsById[modelData] || 0) / root.maxRows : 0
                    enabled_: pref.enabled === true
                    pages: pref.pages || 0
                    weight: pref.weight || 0

                    onSetEnabled: on => Catalog.setSourcePref({
                        "id": modelData,
                        "enabled": on
                    })
                    onSetPages: p => Catalog.setSourcePref({
                        "id": modelData,
                        "pages": p
                    })
                    onSetWeight: w => Catalog.setSourcePref({
                        "id": modelData,
                        "weight": w
                    })
                }
            }

            Item {
                implicitHeight: 2
            }
        }
    }
}
