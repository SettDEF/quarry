import qs.modules.common
import QtQuick

// M3 indeterminate circular progress — an arc that spins while its sweep
// breathes, which reads as motion even at small sizes.
Item {
    id: root

    property real size: 32
    property real strokeWidth: 3
    property color color: Appearance.colors.colPrimary
    property bool running: true

    implicitWidth: size
    implicitHeight: size
    visible: root.running
    opacity: root.running ? 1 : 0

    Behavior on opacity {
        NumberAnimation {
            duration: Appearance.animation.elementMoveFast.duration
        }
    }

    Canvas {
        id: canvas
        anchors.fill: parent
        antialiasing: true

        property real rotationAngle: 0
        property real sweep: 60

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            const cx = width / 2;
            const cy = height / 2;
            const r = Math.max(1, Math.min(cx, cy) - root.strokeWidth / 2);
            ctx.beginPath();
            ctx.lineWidth = root.strokeWidth;
            ctx.lineCap = "round";
            ctx.strokeStyle = root.color;
            const start = rotationAngle * Math.PI / 180;
            ctx.arc(cx, cy, r, start, start + sweep * Math.PI / 180, false);
            ctx.stroke();
        }

        onRotationAngleChanged: requestPaint()
        onSweepChanged: requestPaint()

        RotationAnimation on rotationAngle {
            running: root.running
            loops: Animation.Infinite
            from: 0
            to: 360
            duration: 1100
        }

        SequentialAnimation on sweep {
            running: root.running
            loops: Animation.Infinite
            NumberAnimation {
                from: 30
                to: 280
                duration: 900
                easing.type: Easing.InOutCubic
            }
            NumberAnimation {
                from: 280
                to: 30
                duration: 900
                easing.type: Easing.InOutCubic
            }
        }
    }
}
