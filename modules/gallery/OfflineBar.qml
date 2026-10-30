import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

/*
 * SAYS THE DAEMON IS DOWN, WHERE YOU ARE ALREADY LOOKING.
 *
 * Without quarryd the app keeps working in a way that looks broken rather than
 * offline: the fixture still fills the wall, but thumbnails fall back to
 * fetching straight from the source CDN, most of those fail, and you get a
 * screen of blank tiles. The only thing that named the cause lived inside the
 * settings panel and the overflow menu — you had to already suspect it.
 *
 * A strip, not a dialog: the app is still usable on what it has cached, so this
 * explains and offers a way out rather than blocking.
 */
Rectangle {
    id: root

    visible: !Client.connected
    implicitHeight: 38
    radius: Appearance.rounding.small
    color: Appearance.colors.colErrorContainer
    border.width: 1
    border.color: Appearance.colors.colError

    // Nothing behind a strip drawn over the content should take its clicks.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        hoverEnabled: true
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 6
        spacing: 10

        MaterialSymbol {
            text: "cloud_off"
            iconSize: Appearance.font.pixelSize.normal
            color: Appearance.colors.colError
        }

        StyledText {
            Layout.fillWidth: true
            elide: Text.ElideRight
            text: "quarryd is not running — this is the offline fixture. Nothing can be fetched, exported or compared."
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colOnLayer1
        }

        // The client already retries on its own watchdog; this is for someone
        // who has just started the daemon and does not want to wait for it.
        TextButton {
            text: "Retry"
            onClicked: Client.reconnect()
        }

        TextButton {
            text: "Start it"
            onClicked: {
                Toast.show("Starting quarryd…");
                Sys.run(["systemctl", "--user", "start", "quarryd"], function (ok) {
                    if (ok) {
                        Client.reconnect();
                        return;
                    }
                    // Running from a checkout there is no unit to start, and
                    // guessing a path would be worse than saying so.
                    Toast.error("Could not start it — run quarryd yourself (" + Sys.lastError + ")");
                });
            }
        }
    }
}
