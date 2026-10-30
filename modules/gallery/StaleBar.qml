import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

/*
 * SAYS THE DAEMON IS RUNNING YESTERDAY'S CODE.
 *
 * A package upgrade replaces `/usr/bin/quarryd` while the old process keeps the
 * inode it already opened and carries on executing the old build. Nothing about
 * that is visible: the version number it reports is read from the package, so
 * it is the NEW one, and `/proc/<pid>/exe` quietly starts reading
 * `/usr/bin/quarryd (deleted)` where nobody is looking.
 *
 * Four debugging rounds here ended at "the fix is installed and does nothing"
 * before anyone thought to check. Each time the answer was the same sentence,
 * and each time it cost a round of narrowing to arrive at it. So the daemon
 * says it at the door now (`stale` on `hello`, see PROTOCOL.md) and this is
 * where it gets said out loud.
 *
 * A strip rather than a dialog, like the offline and damaged ones: the old
 * daemon still answers, so this is advice with a button on it, not an
 * interruption. It is the gentlest of the three — nothing is broken, something
 * is merely older than you think — so it uses the ordinary container colours
 * rather than the error ones.
 */
Rectangle {
    id: root

    readonly property string restartScript: 'pid="$1"; main=$(systemctl --user show -p MainPID --value quarryd 2>/dev/null); '
        + 'if [ "$pid" -gt 0 ] && [ "$pid" != "$main" ] && [ "$(cat /proc/$pid/comm 2>/dev/null)" = quarryd ]; then '
        + 'kill "$pid"; for i in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done; fi; '
        + 'systemctl --user restart quarryd 2>/dev/null || { setsid /usr/bin/quarryd --quiet >/dev/null 2>&1 & }'

    visible: Client.connected && Client.stale
    implicitHeight: 38
    radius: Appearance.rounding.small
    color: Appearance.colors.colSecondaryContainer
    border.width: 1
    border.color: Appearance.colors.colOutlineVariant

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
            text: "update"
            iconSize: Appearance.font.pixelSize.normal
            color: Appearance.colors.colOnSecondaryContainer
        }

        StyledText {
            Layout.fillWidth: true
            elide: Text.ElideRight
            text: "quarry was updated — the running daemon is still the old build, so a fix you installed is not in effect yet."
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colOnLayer1

            StyledToolTip {
                visible: why.hovered
                text: "The binary on disk was replaced after this daemon started. It goes on answering from the code it was launched with until it is restarted."
            }
            HoverHandler {
                id: why
            }
        }

        Timer {
            id: verifyRestart

            // Long enough for systemd to start one and for it to fail.
            interval: 5000
            onTriggered: {
                if (!Client.stale)
                    return ;

                Toast.error(Client.daemonPid > 0 ? `Still the old daemon (pid ${Client.daemonPid}) — another quarryd is holding the catalogue. Stop it: kill ${Client.daemonPid}` : "Still the old daemon — another quarryd is holding the catalogue. Stop every quarryd, then start one.");
            }
        }

        TextButton {
            text: "Restart quarryd"
            onClicked: {
                Toast.show("Restarting quarryd…");
                /*
                 * THE DAEMON THAT IS RUNNING, NOT THE UNIT'S.
                 *
                 * The launcher starts quarryd by itself when there is no socket,
                 * outside systemd. `systemctl restart` then started a SECOND one,
                 * which found catalog.db held, exited 3, and was retried every
                 * two seconds for ever — while the old build went on answering
                 * and this bar never left. So the running one is stopped first
                 * (only if it is a quarryd and not the unit's own), then the
                 * unit starts the new build.
                 */
                Sys.run(["sh", "-c", root.restartScript, "sh", String(Client.daemonPid || 0)], function (ok) {
                    if (ok) {
                        Client.reconnect();
                        /*
                         * ACCEPTED IS NOT THE SAME AS DONE.
                         *
                         * systemd answers 0 for a restart it has merely
                         * scheduled. If a second quarryd still holds
                         * catalog.db the new process refuses it and exits, and
                         * systemd retries forever — seen on this machine with
                         * the restart counter at 17 while an orphan from a
                         * previous day went on answering. Every part behaved
                         * correctly and the bar simply never went away.
                         *
                         * So the claim is checked rather than assumed.
                         */
                        verifyRestart.restart();
                        return;
                    }
                    /*
                     * The unit is `disabled` on this machine and the daemon is
                     * often started by hand, which is half of why this bar
                     * exists — so failing to restart it is a likely outcome and
                     * has to say what to do rather than just "failed".
                     */
                    Toast.error("Could not restart it — stop quarryd and start it again yourself (" + Sys.lastError + ")");
                });
            }
        }
    }
}
