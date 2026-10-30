import QtQuick
import qs.modules.common
import qs.modules.widgets

/*
 * WHETHER A PICTURE IS COMING, OR HAS GIVEN UP.
 *
 * Small and quiet, and absent entirely once the picture is here — the blur
 * under it is already doing the work of saying "not yet", and a badge on
 * every tile in a wall would be a wall of badges.
 *
 * Two states only, because two is all the daemon knows: `file.download` is
 * one request and one answer, with no progress in between. So this is a ring
 * that turns while the answer is outstanding, and a button that asks again
 * when the answer was no. Inventing a percentage would be a lie drawn in the
 * shape of a fact.
 */
Item {
    id: badge

    /// "", "fetching" or "failed" — what `lens.fileStateOf` said.
    property string state: ""
    readonly property bool shown: badge.state === "fetching" || badge.state === "failed"

    /// Pressed when it failed; the lens asks for the file again.
    signal retried()

    visible: badge.shown
    implicitWidth: 34
    implicitHeight: 34

    Rectangle {
        anchors.fill: parent
        radius: width / 2
        // Dark rather than themed: it sits on a photograph, and a photograph
        // can be any colour at all.
        color: "#99000000"

        // Turning, not filling: there is no progress to fill with.
        Item {
            anchors.centerIn: parent
            width: 18
            height: 18
            visible: badge.state === "fetching"

            Rectangle {
                id: arc

                anchors.fill: parent
                radius: width / 2
                color: "transparent"
                border.width: 2
                border.color: "#ccffffff"
                // A gap in the ring is what makes the turn visible.
                opacity: 0.9

                Rectangle {
                    width: 7
                    height: 7
                    radius: 4
                    color: "#99000000"
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                }

                RotationAnimation on rotation {
                    running: badge.state === "fetching" && badge.visible
                    from: 0
                    to: 360
                    duration: 1100
                    loops: Animation.Infinite
                }

            }

        }

        MaterialSymbol {
            anchors.centerIn: parent
            visible: badge.state === "failed"
            text: "refresh"
            iconSize: 18
            color: "white"
        }

        MouseArea {
            anchors.fill: parent
            enabled: badge.state === "failed"
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: badge.retried()
        }

    }

}
