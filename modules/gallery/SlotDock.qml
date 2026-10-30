import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

/*
 * WHAT YOU ARE FILLING, AND THE WAY OUT OF IT.
 *
 * The dock that was here first held four navigation buttons, every one of which
 * already existed in the toolbar — permanent space over the pictures for
 * nothing. This holds the one piece of state everything else depends on and
 * nothing was showing: the destination. It earns the space because it is
 * context rather than navigation, so it is relevant on every frame you are
 * looking at, not the rare one where you want to go elsewhere.
 *
 * SHAPE FROM RODDED'S NavDock: the destinations are icon circles and the active
 * one expands behind a sliding indicator to show its label. A dropdown made you
 * open a menu to learn where you were; this says it, and switching is one click
 * on a thing already on screen. All of them are on the dock — see `shown`.
 */
Rectangle {
    id: root

    readonly property var slot: Slots.current

    /*
     * Every destination is on the dock. There is no overflow menu.
     *
     * A dock of six things does not need a "more" button — hiding one or three
     * of them behind three dots made the cheapest control on screen (pick a
     * destination) cost two clicks and a guess about which ones got cut.
     *
     * "Everything" is always first: it is the way back out.
     */
    /*
     * WHAT THE DOCK IS FOR, RECONSIDERED.
     *
     * It listed destinations — every slot you could send a picture to — which
     * is a thing you choose ONCE, at the end, and never while browsing. So the
     * one permanent control floating over the pictures was the one you needed
     * least often, and the choice you actually make constantly (am I looking at
     * pictures, or at video, or at both) was not on screen anywhere.
     *
     * They have swapped places. The media type lives here, where it is one
     * click from anything; the destinations moved into the item menu and the
     * export sheet, which is where you already are when you have decided to
     * send something somewhere.
     */
    readonly property var shown: [
        { "id": "all", "icon": "auto_awesome_mosaic", "label": "Mix" },
        { "id": "pic", "icon": "image", "label": "Images" },
        { "id": "vid", "icon": "movie", "label": "Video" }
    ]

    /// Which one is on, read from the query rather than held here — the query
    /// is the single source of filter truth, and typing `family:video` by hand
    /// must light the same button.
    readonly property string mediaType: {
        const q = Catalog.query || "";
        if (/(^|\s)family:video(\s|$)/.test(q))
            return "vid";
        if (/(^|\s)-family:video(\s|$)/.test(q))
            return "pic";
        return "all";
    }

    function chooseMedia(id) {
        if (id === "vid")
            Catalog.setFilter("family", "video");
        else if (id === "pic")
            // Everything that is not video: a negated token, which the DSL
            // already understands and the bar can show.
            Catalog.query = (Catalog.query || "")
                .replace(/(^|\s)-?family:video(\s|$)/g, " ")
                .replace(/\s+/g, " ")
                .trim() + " -family:video";
        else
            Catalog.query = (Catalog.query || "")
                .replace(/(^|\s)-?family:video(\s|$)/g, " ")
                .replace(/\s+/g, " ")
                .trim();
    }

    implicitWidth: row.implicitWidth + 16
    implicitHeight: 52
    radius: height / 2
    color: Appearance.colors.colLayer2
    border.width: 1
    border.color: Appearance.colors.colLayer0Border

    /*
     * NOTHING BEHIND A FLOATING SURFACE IS CLICKABLE THROUGH IT.
     *
     * The dock is drawn over the wall, so a press that lands on its background
     * — the padding, the gaps between controls, the rounded corners — went to
     * whatever tile was underneath. The controls have their own handlers; this
     * catches everything else, which is the part that was falling through.
     *
     * This is the third time this exact bug has appeared (menu rows, the menu's
     * background, now here). The rule: a surface that floats over content must
     * accept events across its whole area, not only where its children happen
     * to be.
     */
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        hoverEnabled: true
        onWheel: wheel => wheel.accepted = true
    }

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 4

        PillTabBar {
            id: dests
            Layout.alignment: Qt.AlignVCenter
            tabs: root.shown
            current: root.mediaType
            onTabSelected: id => root.chooseMedia(id)
        }

        /*
         * No action button here.
         *
         * You export a PICTURE, and the dock does not know which one — with no
         * detail view open it fell back to whatever tile happened to be first
         * in the grid, which is why the button read as arbitrary no matter what
         * it was called. The action lives where the subject is: the detail
         * view's primary button, the tile's context menu, the item menu.
         *
         * The dock says what you are filling. That is all it should say.
         */
    }
}
