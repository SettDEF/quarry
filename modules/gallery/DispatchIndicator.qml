import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick

/*
 * Is Morse reachable at all?
 *
 * (Placeholder name — see the header of services/Dispatch.qml.)
 *
 * Small on purpose. Sending a picture to a chat is one thing quarry can do out
 * of a hundred, and a strip across the window for it would be out of all
 * proportion — this is a dot with a tooltip, the size of the other chrome in
 * the bar it sits in.
 *
 * IT DOES NOT APPEAR ON A MACHINE WITHOUT MORSE. An icon that is permanently
 * off is not information, it is a question the app keeps asking about software
 * you never installed. It shows itself the first time an endpoint file exists
 * and stays from then on, so "Morse died" is visible and "Morse was never
 * here" is silent.
 */
Item {
    id: root

    /// Show it even before Morse has ever been seen — for a settings row that
    /// is explaining this feature and needs to draw its own state.
    property bool always: false

    visible: root.always || Dispatch.everSeen
    implicitWidth: 28
    implicitHeight: 28

    readonly property color tone: {
        switch (Dispatch.state) {
        case "ready":
            return Appearance.colors.colPrimary;
        case "connecting":
            return Appearance.colors.colSubtext;
        case "signedOut":
            return Appearance.colors.colTertiary;
        }
        return Appearance.colors.colError;
    }

    readonly property string glyph: {
        switch (Dispatch.state) {
        case "ready":
            return "send";
        case "connecting":
            return "sync";
        case "signedOut":
            return "no_accounts";
        }
        return "cloud_off";
    }

    Rectangle {
        id: pad
        anchors.fill: parent
        radius: Appearance.rounding.full
        color: mouse.containsMouse ? Appearance.colors.colLayer1Hover : "transparent"

        Behavior on color {
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(pad)
        }
    }

    MaterialSymbol {
        id: symbol
        anchors.centerIn: parent
        text: root.glyph
        iconSize: 17
        color: root.tone

        Behavior on color {
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(symbol)
        }
    }

    // The one live state deserves the only motion: a spinning glyph while the
    // socket is coming up, still the rest of the time.
    RotationAnimator {
        target: symbol
        running: Dispatch.state === "connecting"
        from: 0
        to: 360
        duration: 1400
        loops: Animation.Infinite
        onRunningChanged: if (!running)
            symbol.rotation = 0
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        // Nothing here can fix a missing daemon, so the click does the only
        // useful thing there is: ask again, now.
        onClicked: Dispatch.available ? Dispatch.refreshChats() : Dispatch.retry()
    }

    StyledToolTip {
        visible: mouse.containsMouse
        text: Dispatch.available ? (Dispatch.mock ? `Morse is here — mock backend, ${Dispatch.chats.length} chats` : `Morse is here — ${Dispatch.chats.length} chats`) : Dispatch.reason
    }
}
