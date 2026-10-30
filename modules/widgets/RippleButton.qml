import qs.modules.common
import QtQuick
import QtQuick.Controls
import Qt5Compat.GraphicalEffects

/*
 * Material 3 button with a touch ripple, matching the shell's RippleButton.
 *
 * The ripple is a plain circle that grows from the press point and fades out,
 * masked to the button's rounded rect. Set `toggled` for the selected state.
 */
Button {
    id: root

    property bool toggled: false
    property string buttonText: ""
    property bool pointingHandCursor: true
    property real buttonRadius: Appearance.rounding.small
    property int rippleDuration: 900
    property bool rippleEnabled: true

    property var altAction        // right click
    property var middleClickAction

    property color colBackground: ColorUtils.transparentize(Appearance.colors.colLayer1Hover, 1)
    property color colBackgroundHover: Appearance.colors.colLayer1Hover
    property color colBackgroundToggled: Appearance.colors.colPrimary
    property color colBackgroundToggledHover: Appearance.colors.colPrimaryHover
    property color colRipple: Appearance.colors.colLayer1Active
    property color colRippleToggled: Appearance.colors.colPrimaryActive

    readonly property color buttonColor: root.toggled ? (root.hovered ? colBackgroundToggledHover : colBackgroundToggled) : (root.hovered ? colBackgroundHover : colBackground)
    readonly property color rippleColor: root.toggled ? colRippleToggled : colRipple

    opacity: root.enabled ? 1 : 0.4
    padding: 8

    function startRipple(x, y) {
        // Radius has to reach the furthest corner or the fill looks clipped.
        const dist = (ox, oy) => ox * ox + oy * oy;
        rippleAnim.rippleX = x;
        rippleAnim.rippleY = y;
        rippleAnim.rippleRadius = Math.sqrt(Math.max(dist(x, y), dist(width - x, y), dist(x, height - y), dist(width - x, height - y)));
        rippleFadeAnim.complete();
        rippleAnim.restart();
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: root.pointingHandCursor ? Qt.PointingHandCursor : Qt.ArrowCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

        onPressed: event => {
            if (event.button === Qt.RightButton) {
                if (root.altAction)
                    root.altAction(event);
                return;
            }
            if (event.button === Qt.MiddleButton) {
                if (root.middleClickAction)
                    root.middleClickAction();
                return;
            }
            root.down = true;
            if (root.rippleEnabled)
                root.startRipple(event.x, event.y);
        }
        onReleased: event => {
            root.down = false;
            if (event.button !== Qt.LeftButton)
                return;
            root.click();   // the MouseArea already ate the event
            if (root.rippleEnabled)
                rippleFadeAnim.restart();
        }
        onCanceled: {
            root.down = false;
            if (root.rippleEnabled)
                rippleFadeAnim.restart();
        }
    }

    background: Rectangle {
        id: buttonBackground
        implicitHeight: 34
        radius: root.buttonRadius
        color: root.buttonColor

        Behavior on color {
            animation: Appearance.animation.stateChange.colorAnimation.createObject(this)
        }

        /*
         * Rectangular clip would leak the ripple past rounded corners — but a
         * layer is not free, and this one was making every round button look
         * like it had been drawn on graph paper.
         *
         * An offscreen layer renders at the item's LOGICAL size and is then
         * scaled to physical pixels. On a fractionally-scaled display (1.67
         * here) that is a resample of a texture that is too small, with
         * `smooth` defaulting to false — so the curve arrives stair-stepped no
         * matter how well Qt drew it. `textureSize` renders it at the real
         * pixel count and `smooth` filters what is left.
         *
         * The mask needs the same treatment for the same reason: OpacityMask
         * multiplies by the mask's alpha, so the edge is only ever as smooth
         * as the mask's own edge.
         */
        layer.enabled: root.rippleEnabled
        layer.smooth: true
        layer.textureSize: Qt.size(
            Math.ceil(buttonBackground.width * (Screen.devicePixelRatio || 1)),
            Math.ceil(buttonBackground.height * (Screen.devicePixelRatio || 1)))
        layer.effect: OpacityMask {
            maskSource: Rectangle {
                width: buttonBackground.width
                height: buttonBackground.height
                radius: root.buttonRadius
                antialiasing: true
                layer.enabled: true
                layer.smooth: true
                layer.textureSize: Qt.size(
                    Math.ceil(width * (Screen.devicePixelRatio || 1)),
                    Math.ceil(height * (Screen.devicePixelRatio || 1)))
            }
        }

        Rectangle {
            id: ripple
            width: rippleSize
            height: rippleSize
            radius: rippleSize / 2
            x: rippleAnim.rippleX - rippleSize / 2
            y: rippleAnim.rippleY - rippleSize / 2
            color: root.rippleColor
            opacity: 0
            visible: rippleSize > 0

            property real rippleSize: 0
        }

        SequentialAnimation {
            id: rippleAnim
            property real rippleX: 0
            property real rippleY: 0
            property real rippleRadius: 0

            PropertyAction {
                target: ripple
                property: "opacity"
                value: 0.5
            }
            NumberAnimation {
                target: ripple
                property: "rippleSize"
                from: 0
                to: rippleAnim.rippleRadius * 2
                duration: root.rippleDuration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.animationCurves.standardDecel
            }
        }

        NumberAnimation {
            id: rippleFadeAnim
            target: ripple
            property: "opacity"
            to: 0
            duration: Appearance.animation.elementMoveFast.duration * 2
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Appearance.animationCurves.standardDecel
        }
    }

    contentItem: StyledText {
        text: root.buttonText
        horizontalAlignment: Text.AlignHCenter
        color: root.toggled ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer1
        font.pixelSize: Appearance.font.pixelSize.small
    }
}
