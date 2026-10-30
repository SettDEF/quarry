import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

pragma ComponentBehavior: Bound

// The address bar: site indicators, the URL with its host emphasised, and the
// bookmark star.
//
// Emphasising the host is a security affordance, not decoration. A long path
// can be crafted to look like a domain (`bank.com` buried in a query string),
// so the part that actually determines identity is the part that stays bright.
Item {
    id: root

    required property var theme
    required property var page
    required property bool bookmarked

    property bool blockingEnabled: false

    signal addressActivated()
    signal bookmarkToggled()
    signal blockingToggled()
    // Carries which indicator was pressed: each opens its own panel.
    signal panelRequested(string mode)

    implicitHeight: 34

    readonly property string fullUrl: page ? String(page.url) : ""

    // Split into the three pieces the eye should weight differently.
    readonly property var parts: {
        const url = root.fullUrl;
        if (url.length === 0)
            return { scheme: "", host: "", rest: "", secure: false };

        const schemeEnd = url.indexOf("://");
        if (schemeEnd < 0)
            return { scheme: "", host: url, rest: "", secure: false };

        const scheme = url.slice(0, schemeEnd + 3);
        const after = url.slice(schemeEnd + 3);
        const slash = after.indexOf("/");
        const host = slash < 0 ? after : after.slice(0, slash);
        const rest = slash < 0 ? "" : after.slice(slash);

        return {
            scheme: scheme,
            host: host,
            rest: rest,
            secure: scheme === "https://"
        };
    }

    Rectangle {
        anchors.fill: parent
        radius: root.theme.rounding
        color: barHover.hovered ? root.theme.surfaceHover : "transparent"

        Behavior on color { ColorAnimation { duration: root.theme.durFast } }

        HoverHandler { id: barHover }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 6
            spacing: 4

            // ── Site indicators ────────────────────────────────────────
            Indicator {
                theme: root.theme
                glyph: root.parts.secure ? "shield" : "shield_with_heart"
                tip: root.parts.secure ? "Connection is encrypted"
                                       : "Connection is not encrypted"
                tone: root.parts.secure ? root.theme.textDim : root.theme.error
                onTriggered: root.panelRequested("security")
            }

            Indicator {
                theme: root.theme
                glyph: "key_vertical"
                tip: "Site permissions"
                tone: root.theme.textDim
                onTriggered: root.panelRequested("permissions")
            }

            Indicator {
                theme: root.theme
                glyph: "videocam_off"
                tip: "Camera blocked"
                tone: root.theme.textFaint
                onTriggered: root.panelRequested("camera")
            }

            Indicator {
                theme: root.theme
                glyph: "mic_off"
                tip: "Microphone blocked"
                tone: root.theme.textFaint
                onTriggered: root.panelRequested("microphone")
            }

            Item { Layout.preferredWidth: 4 }

            // ── URL ────────────────────────────────────────────────────
            // One Text with rich markup rather than three Labels: the pieces
            // must wrap and elide as a single run, which separate items cannot
            // do without fighting the layout.
            Text {
                id: address

                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                textFormat: Text.StyledText
                elide: Text.ElideRight
                font.family: root.theme.fontMain
                font.pixelSize: root.theme.fontSmall
                color: root.theme.textDim

                function escapeHtml(value) {
                    return String(value)
                        .replace(/&/g, "&amp;")
                        .replace(/</g, "&lt;")
                        .replace(/>/g, "&gt;");
                }

                text: {
                    const p = root.parts;
                    if (p.host.length === 0)
                        return "";
                    const dim = root.theme.textFaint;
                    const bright = root.theme.text;
                    return "<span style='color:" + dim + "'>" + escapeHtml(p.scheme) + "</span>"
                         + "<span style='color:" + bright + "'>" + escapeHtml(p.host) + "</span>"
                         + "<span style='color:" + dim + "'>" + escapeHtml(p.rest) + "</span>";
                }

                TapHandler { onTapped: root.addressActivated() }
            }

            // ── Blocking state ─────────────────────────────────────────
            Rectangle {
                visible: root.blockingEnabled
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: shieldText.implicitWidth + 16
                implicitHeight: 20
                radius: height / 2
                color: root.theme.accentContainer

                TapHandler { onTapped: root.blockingToggled() }

                Label {
                    id: shieldText
                    anchors.centerIn: parent
                    text: "blocking"
                    color: root.theme.onAccentContainer
                    font.family: root.theme.fontMain
                    font.pixelSize: root.theme.fontSmallest
                }
            }

            // ── Bookmark ───────────────────────────────────────────────
            Indicator {
                theme: root.theme
                glyph: root.bookmarked ? "star" : "star_outline"
                tip: root.bookmarked ? "Remove bookmark  ⌃D" : "Bookmark this page  ⌃D"
                tone: root.bookmarked ? root.theme.accent : root.theme.textDim
                onTriggered: root.bookmarkToggled()
            }
        }
    }

    component Indicator: Rectangle {
        id: indicator

        required property var theme
        required property string glyph
        property string tip: ""
        property color tone: theme.textDim

        signal triggered()

        Layout.alignment: Qt.AlignVCenter
        implicitWidth: 24
        implicitHeight: 24
        radius: 6
        color: indicatorHover.hovered ? indicator.theme.surfaceActive : "transparent"

        Behavior on color { ColorAnimation { duration: indicator.theme.durFast } }

        HoverHandler { id: indicatorHover }
        TapHandler { onTapped: indicator.triggered() }

        ToolTip.visible: indicatorHover.hovered && indicator.tip.length > 0
        ToolTip.text: indicator.tip
        ToolTip.delay: 500

        Label {
            anchors.centerIn: parent
            text: indicator.glyph
            color: indicator.tone
            font.family: indicator.theme.fontIcon
            font.pixelSize: indicator.theme.iconSizeSmall

            Behavior on color { ColorAnimation { duration: indicator.theme.durFast } }
        }
    }
}
