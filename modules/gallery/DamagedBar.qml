import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

/*
 * SAYS THE CATALOGUE IS BROKEN, INSTEAD OF SAYING "NOTHING MATCHED".
 *
 * A damaged SQLite file does not fail loudly. It answers what it can and
 * returns nothing for the rest — so a wrecked search index spent a day making
 * every word answer zero rows over fifteen thousand pictures, and the wall drew
 * the same empty state it draws for a search with no results. The rail emptied
 * the same way, because the facet query touched the damaged pages and the
 * daemon handed back an empty list.
 *
 * The daemon now says so in every answer (`damaged`), and this is where that
 * gets said out loud. A strip rather than a dialog, like the offline one: what
 * is already cached still works, and restarting is a choice rather than an
 * interruption — the daemon moves a wrecked catalogue aside on the way up and
 * puts your collections and boards back from the copy beside it.
 */
Rectangle {
    id: root

    /// Either half of "your data is in trouble": the catalogue cannot be read,
    /// or the copy of what you chose cannot be written. Both are quiet enough
    /// to go unnoticed for a day, which is exactly why they get a strip.
    readonly property bool broken: Catalog.damaged.length > 0
    visible: Client.connected && (root.broken || Catalog.userDataError.length > 0)
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
            text: root.broken ? "database" : "bookmark_manager"
            iconSize: Appearance.font.pixelSize.normal
            color: Appearance.colors.colError
        }

        StyledText {
            Layout.fillWidth: true
            elide: Text.ElideRight
            text: root.broken ? "The catalogue is damaged — searches and the rail will come back empty. Restarting rebuilds it; your boards and collections are kept." : "Your boards and collections are not being saved. The catalogue still works, but nothing you arrange is being written down."
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colOnLayer1

            // The daemon's own words, for whoever wants them.
            StyledToolTip {
                visible: reason.hovered
                text: root.broken ? Catalog.damaged : Catalog.userDataError
            }
            HoverHandler {
                id: reason
            }
        }

        TextButton {
            text: root.broken ? "Restart quarryd" : "Restart it"
            onClicked: {
                Toast.show("Restarting quarryd…");
                Sys.run(["systemctl", "--user", "restart", "quarryd"], function (ok) {
                    if (ok) {
                        Client.reconnect();
                        return;
                    }
                    // Running from a checkout there is no unit to restart, and
                    // guessing a path would be worse than saying so.
                    Toast.error("Could not restart it — restart quarryd yourself (" + Sys.lastError + ")");
                });
            }
        }
    }
}
