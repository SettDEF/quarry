import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

pragma ComponentBehavior: Bound

// Find in page. Floats over the top-right of the content rather than pushing
// it down, so the page does not reflow while you are reading it.
Rectangle {
    id: root

    required property var theme
    /// The tab wrapper to search in; may be null.
    property var page: null

    property int matchCount: 0
    property int activeMatch: 0

    visible: false
    implicitWidth: 340
    implicitHeight: 44
    radius: theme.rounding
    color: theme.surfaceHigh
    border.color: theme.border
    border.width: theme.borderWidth

    opacity: visible ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: theme.durFast } }

    function show() {
        visible = true;
        input.forceActiveFocus();
        input.selectAll();
        if (input.text.length > 0)
            search(input.text, false);
    }

    function hide() {
        visible = false;
        clear();
    }

    function clear() {
        matchCount = 0;
        activeMatch = 0;
        if (page && page.webView)
            page.webView.findText("");
    }

    function search(term, backwards) {
        if (!page || !page.webView)
            return;
        if (term.length === 0) {
            clear();
            return;
        }

        const flags = backwards ? WebEngineView.FindBackward : 0;
        page.webView.findText(term, flags, function (result) {
            root.matchCount = result.numberOfMatches;
            root.activeMatch = result.activeMatch;
        });
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 6
        spacing: 6

        Label {
            text: "search"
            color: root.theme.textDim
            font.family: root.theme.fontIcon
            font.pixelSize: root.theme.iconSizeSmall
        }

        TextField {
            id: input

            Layout.fillWidth: true
            placeholderText: "Find in page"
            color: root.theme.text
            placeholderTextColor: root.theme.textFaint
            font.family: root.theme.fontMain
            font.pixelSize: root.theme.fontSmall
            background: null

            onTextEdited: root.search(text, false)
            onAccepted: root.search(text, false)

            Keys.onEscapePressed: root.hide()
        }

        Label {
            visible: input.text.length > 0
            text: root.matchCount > 0 ? root.activeMatch + "/" + root.matchCount : "none"
            color: root.matchCount > 0 ? root.theme.textDim : root.theme.error
            font.family: root.theme.fontMono
            font.pixelSize: root.theme.fontSmallest
        }

        FindButton {
            theme: root.theme
            glyph: "keyboard_arrow_up"
            onTriggered: root.search(input.text, true)
        }
        FindButton {
            theme: root.theme
            glyph: "keyboard_arrow_down"
            onTriggered: root.search(input.text, false)
        }
        FindButton {
            theme: root.theme
            glyph: "close"
            onTriggered: root.hide()
        }
    }

    component FindButton: Rectangle {
        id: button

        required property var theme
        required property string glyph

        signal triggered()

        implicitWidth: 28
        implicitHeight: 28
        radius: button.theme.roundingSmall
        color: buttonHover.hovered ? button.theme.surfaceHover : "transparent"

        Behavior on color { ColorAnimation { duration: button.theme.durFast } }

        HoverHandler { id: buttonHover }
        TapHandler { onTapped: button.triggered() }

        Label {
            anchors.centerIn: parent
            text: button.glyph
            color: button.theme.textDim
            font.family: button.theme.fontIcon
            font.pixelSize: button.theme.iconSizeSmall
        }
    }
}
