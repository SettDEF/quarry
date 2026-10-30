import qs.modules.common
import QtQuick
import QtQuick.Controls

/*
 * THE MATERIAL 3 EXPRESSIVE SLIDER — the shape Rodded uses.
 *
 * This was the old Material look: a 4px line with a circle sliding along it.
 * The expressive one is a different object. A THICK track, split into a filled
 * left and an unfilled right with a GAP between them, and the handle is a thin
 * vertical BAR standing in that gap rather than a knob riding on a wire. The
 * bar narrows while pressed, so the thing under your finger gets out of the way
 * of the thing you are trying to see.
 *
 * It also fixes the scrubber's real problem. `value` must not be bound straight
 * to `player.position`: the player emits positionChanged several times a second
 * and fights the drag, snapping the handle back to the playhead. `held` is what
 * the owner suspends its binding on, and the seek is issued on release —
 * seeking on every pixel of a drag is a request per frame, which on a streamed
 * source stutters far worse than a handle that is briefly ahead of the picture.
 */
Slider {
    id: root

    enum Configuration {
        XS = 12,
        S = 18,
        M = 30,
        L = 42,
        XL = 72
    }

    property int configuration: StyledSlider.Configuration.S

    property real handleDefaultWidth: 3
    property real handlePressedWidth: 1.5
    property real handleMargins: 4

    /// 0..1, how much of the media is actually on hand. Negative hides it.
    /// A scrubber that shows only the playhead cannot tell "the network
    /// stopped" from "the video ended".
    property real buffered: -1

    /// Shown in a bubble above the handle while dragging.
    property string readout: ""

    property color highlightColor: Appearance.colors.colPrimary
    property color trackColor: Appearance.colors.colSecondaryContainer
    property color handleColor: Appearance.colors.colPrimary

    /// True while the handle is down. Deliberately named: `pressed` is also
    /// true for a click on the track, and a scrubber must treat both alike.
    readonly property bool held: root.pressed

    readonly property real trackWidth: root.configuration
    readonly property real trackRadius: trackWidth >= StyledSlider.Configuration.XL ? 21
        : trackWidth >= StyledSlider.Configuration.L ? 12
        : trackWidth >= StyledSlider.Configuration.M ? 9
        : trackWidth >= StyledSlider.Configuration.S ? 6
        : height / 2
    readonly property real handleHeight: Math.max(33, trackWidth + 9)
    readonly property real handleWidth: root.pressed ? root.handlePressedWidth : root.handleDefaultWidth

    /*
     * Smoothing is measured in VALUE UNITS PER SECOND, so the DEFAULT velocity
     * only makes sense on a small range: a scrubber whose range is a clip's
     * length in milliseconds would crawl toward the playhead at 850ms per
     * second of real time and never arrive.
     *
     * The answer is not to switch smoothing off — that is what made the
     * playhead jump. A player reports its position a few times a second at
     * best, so an unsmoothed handle stands still and then leaps, over and over,
     * for the whole clip. The answer is a velocity in the RANGE'S OWN UNITS:
     * a scrubber sets `smoothVelocity` to 1000 × the playback rate, which is
     * exactly how fast the playhead really moves, so between two reports the
     * handle glides at the speed the video is actually playing.
     *
     * `maximumEasingTime` is what keeps a SEEK instant-ish: without it, a jump
     * of five minutes at that velocity would take five minutes to animate.
     */
    property bool smoothValue: true
    property real smoothVelocity: Appearance.animation.elementMoveFast.velocity
    /// The longest any single change may take to catch up, however far it is.
    property int smoothCatchUpMs: 220

    leftPadding: root.handleMargins
    rightPadding: root.handleMargins
    readonly property real effectiveDraggingWidth: width - leftPadding - rightPadding

    implicitHeight: Math.max(root.handleHeight, root.trackWidth)

    /*
     * Smooth a change that came from somewhere else, never one that came from
     * the finger: animating toward the cursor makes the handle lag it.
     *
     * `smoothPaused` is the other half. A glide is right while the picture is
     * moving — it bridges the gap between a player's position reports — and
     * wrong the moment it stops: a paused clip whose handle is still sliding,
     * or a seek that crawls to where you dropped it, both read as the control
     * being broken. The owner sets this false whenever the value it is
     * following has stopped moving on its own.
     */
    property bool smoothPaused: false

    Behavior on value {
        enabled: root.smoothValue && !root.pressed && !root.smoothPaused
        SmoothedAnimation {
            velocity: root.smoothVelocity
            maximumEasingTime: root.smoothCatchUpMs
        }
    }

    MouseArea {
        anchors.fill: parent
        // Does not consume the press — the Slider still needs it.
        onPressed: mouse => mouse.accepted = false
        cursorShape: root.pressed ? Qt.ClosedHandCursor : Qt.PointingHandCursor
    }

    background: Item {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        implicitHeight: root.trackWidth

        // Played, stopping short of the handle.
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            width: Math.max(0, root.handleMargins + (root.visualPosition * root.effectiveDraggingWidth)
                - (root.handleWidth / 2 + root.handleMargins))
            height: root.trackWidth
            radius: root.trackRadius
            color: root.highlightColor
        }

        // Still to come, starting after the handle.
        Rectangle {
            id: remaining
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            width: Math.max(0, root.handleMargins + ((1 - root.visualPosition) * root.effectiveDraggingWidth)
                - (root.handleWidth / 2 + root.handleMargins))
            height: root.trackWidth
            radius: root.trackRadius
            color: root.trackColor
            clip: true

            /*
             * Buffered, drawn INSIDE the unplayed track.
             *
             * Anchored to the left of the remaining piece and clipped by it, so
             * it can only ever show the part that is downloaded but not yet
             * played — which is the only part the number means anything about.
             */
            Rectangle {
                visible: root.buffered >= 0
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                height: parent.height
                radius: parent.radius
                width: {
                    const ahead = Math.max(0, Math.min(1, root.buffered) - root.visualPosition);
                    return ahead * root.effectiveDraggingWidth;
                }
                color: ColorUtils.mix(root.highlightColor, root.trackColor, 0.35)
            }
        }
    }

    handle: Rectangle {
        id: bar
        implicitWidth: root.handleWidth
        implicitHeight: root.handleHeight
        x: root.handleMargins + (root.visualPosition * root.effectiveDraggingWidth) - (root.handleWidth / 2)
        anchors.verticalCenter: parent.verticalCenter
        radius: Appearance.rounding.full
        color: root.handleColor
        antialiasing: true

        Behavior on implicitWidth {
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(bar)
        }

        // Follows the handle rather than sitting at a fixed end: during a drag
        // the number and the thing it describes must be in the same place, or
        // you read one and look at the other.
        StyledToolTip {
            visible: root.pressed && root.readout.length > 0
            delay: 0
            text: root.readout
            side: Qt.TopEdge
        }
    }
}
