import qs.modules.common
import QtQuick
import QtQuick.Layouts

// A group of settings as a card. Bare columns of rows made eleven groups read
// as one list of forty; an edge is what lets you find the group before the row.
ColumnLayout {
    id: root

    property string title: ""
    property string footer: ""
    /// Short word on the right of the caption — which page a search hit is on.
    property string note: ""

    /// Rows still showing after the search. A filter that leaves empty cards
    /// standing has not filtered anything, so the card hides at zero.
    ///
    /// Counted from each row's own `wanted`, never its `visible`: `visible` is
    /// effective, so once the card hides every row inside it reports invisible
    /// and the count can never climb back. Rows without `wanted` do not count.
    property int visibleRows: 0

    default property alias rows: holder.data

    Layout.fillWidth: true
    spacing: 0

    visible: root.visibleRows > 0

    // Already-connected children, so a Repeater filling does not connect the
    // same row a dozen times. Destroyed children take their connections along.
    property var _watched: []

    function _recount() {
        let n = 0;
        for (let i = 0; i < holder.children.length; i++) {
            const w = holder.children[i].wanted;
            if (w === true)
                n++;
        }
        root.visibleRows = n;
    }

    // Coalesced: one keystroke changes forty rows, and that is one recount.
    function _bump() {
        Qt.callLater(root._recount);
    }

    function _rewatch() {
        const now = [];
        for (let i = 0; i < holder.children.length; i++) {
            const c = holder.children[i];
            now.push(c);
            if (root._watched.indexOf(c) < 0 && c.wantedChanged)
                c.wantedChanged.connect(root._bump);
        }
        root._watched = now;
        root._bump();
    }

    Component.onCompleted: root._rewatch()

    RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: 6
        Layout.bottomMargin: 6
        visible: root.title.length > 0
        spacing: 8

        // Small, dim, caps: a caption that outweighs its own rows is noise.
        StyledText {
            Layout.fillWidth: true
            text: root.title
            font.pixelSize: Appearance.font.pixelSize.smallest
            font.weight: Font.DemiBold
            font.capitalization: Font.AllUppercase
            font.letterSpacing: 0.8
            color: Appearance.colors.colSubtext
            elide: Text.ElideRight
        }

        StyledText {
            visible: root.note.length > 0
            text: root.note
            font.pixelSize: Appearance.font.pixelSize.smallest
            font.capitalization: Font.AllUppercase
            font.letterSpacing: 0.8
            color: Appearance.colors.colSubtext
            opacity: 0.8
        }
    }

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: holder.implicitHeight + 12
        radius: Appearance.rounding.normal
        // No border: the tone step against the pane is the edge already.
        color: Appearance.colors.colLayer1

        ColumnLayout {
            id: holder
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 6
            anchors.rightMargin: 6
            spacing: 0

            onChildrenChanged: root._rewatch()
        }
    }

    // Outside the card: a sentence about the group is not a row you can press.
    StyledText {
        visible: root.footer.length > 0
        Layout.fillWidth: true
        Layout.leftMargin: 6
        Layout.rightMargin: 6
        Layout.topMargin: 6
        text: root.footer
        font.pixelSize: Appearance.font.pixelSize.smaller
        color: Appearance.colors.colSubtext
        wrapMode: Text.WordWrap
    }
}
