import qs.modules.common
import qs.modules.widgets
import QtQuick
import QtQuick.Layouts

/*
 * THE CARD A MOCKUP IS DRAWN IN.
 *
 * The in-context layout's three panes were three hand-written cards that each
 * re-derived the same two things: the scale that fits a device-pixel design
 * into a logical-pixel card, and the caption that says what that scale came out
 * as. Extracted so an extension can ship a mock without reimplementing either
 * -- and so a pack's mock is indistinguishable from a built-in one, which is
 * the point of a pack.
 *
 * The contract for the drawing itself is `mock`: `mock.u(px)` turns a
 * device-pixel measurement into logical units, `mock.fit` is the scale, and
 * `mock.record` is the picture. Everything inside a mock is specified in device
 * pixels, because that is the unit a slot is specified in.
 */
Rectangle {
    id: root

    property string label: ""
    property string detail: ""
    /// Which export this pane is previewing. The caption's crop button hands
    /// this back, so the export that follows a preview is the one previewed.
    property string targetId: ""

    /// The design, in device pixels.
    property int designW: 100
    property int designH: 100

    /// The picture on the stage.
    property var record: null
    /// Logical pixels per device pixel, from the layout that owns the stage.
    property real dpr: 1

    property Component content: null

    signal exportClicked

    Layout.fillWidth: true
    Layout.fillHeight: true
    radius: Appearance.rounding.normal
    color: Appearance.colors.colLayer2

    /*
     * NEVER MAGNIFY.
     *
     * A 32px avatar blown up to fill a card is exactly the mistake this layout
     * was built to catch, so the scale is capped at 1. At 100% the avatar on
     * screen is the same number of physical pixels as the avatar on Steam.
     */
    readonly property real fit: {
        const availW = root.width - 24;
        const availH = root.height - 52;
        if (root.designW <= 0 || root.designH <= 0 || availW <= 0 || availH <= 0)
            return 1;
        return Math.min(1, Math.min(availW * root.dpr / root.designW, availH * root.dpr / root.designH));
    }

    function u(px) {
        return px * root.fit / root.dpr;
    }

    /// Nearest ladder step at or above the size the mock actually draws.
    function ladderFor(devicePixels) {
        for (const step of [160, 320, 640, 1280])
            if (step >= devicePixels)
                return step;
        return 1280;
    }

    /// What a mock reads. One object so a pack binds to a single property and
    /// keeps working when this grows a field.
    readonly property var mock: ({
        "u": root.u,
        "fit": root.fit,
        "dpr": root.dpr,
        "record": root.record,
        "ladderFor": root.ladderFor
    })

    Item {
        id: caption
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 34

        /*
         * A ROW, NOT TWO ANCHORED LABELS.
         *
         * Both were anchored to their own edge and neither knew the other was
         * there, so in a narrow window "Discord member list" ran straight
         * through "shown at 32px · 100%" and both became unreadable. The scale
         * is the number the pane exists to report, so it keeps its width and
         * the name gives way.
         */
        RowLayout {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 12
            anchors.rightMargin: 4
            spacing: 6

            StyledText {
                Layout.fillWidth: true
                text: root.label
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colOnLayer2
                elide: Text.ElideRight
            }

            StyledText {
                text: `${root.detail} · ${Math.round(root.fit * 100)}%`
                font.family: Appearance.font.family.monospace
                font.pixelSize: Appearance.font.pixelSize.smallest
                // The accent means "this is life size" — the one number on the
                // card that changes what you conclude from looking at it.
                color: root.fit >= 0.999 ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
            }

            IconButton {
                icon: "crop"
                size: 28
                iconSize: Appearance.font.pixelSize.normal
                tooltip: "Export for this slot"
                onClicked: root.exportClicked()
            }
        }
    }

    Loader {
        id: drawing
        width: root.u(root.designW)
        height: root.u(root.designH)
        anchors.centerIn: parent
        anchors.verticalCenterOffset: 14
        sourceComponent: root.content
        // Assigned rather than bound into the component: a Loader's item is
        // created after the component is set, so a binding written the other
        // way round reads null on the frame that matters.
        onLoaded: {
            if (item)
                item.mock = Qt.binding(() => root.mock);
        }
    }
}
