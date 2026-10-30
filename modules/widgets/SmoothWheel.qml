import qs.modules.common
import QtQuick

/*
 * Scroll feel for a Flickable, for both input devices.
 *
 * The problem this solves: on Wayland a touchpad two-finger scroll arrives as
 * *wheel* events carrying pixel-precise deltas, not as touch. Flickable applies
 * wheel input straight to contentY and never accumulates flick velocity, so
 * scrolling stops dead the instant you lift your fingers — `flickDeceleration`
 * has nothing to decelerate, because it only governs real flicks.
 *
 * So both devices are handled here explicitly:
 *
 *   Touchpad (pixelDelta ≠ 0) — applied 1:1 so the content tracks your fingers,
 *     while recent deltas are sampled. When the gesture stops, the measured
 *     velocity is handed to Flickable.flick(), which then coasts and decelerates
 *     exactly as a drag would.
 *
 *   Mouse wheel (pixelDelta == 0) — coarse 120-unit notches, which Flickable
 *     turns into an instant jump. Animated into a short glide instead.
 *
 * Place it as a *sibling* overlaying the target, never as a child: a Flickable
 * reparents Item children into contentItem, so a handler declared inside one
 * attaches to the scrolling content rather than the viewport.
 */
Item {
    id: root

    property var flickable: null

    // Pixels travelled per mouse-wheel notch.
    property real step: Appearance.scroll.wheelStep
    property int duration: Appearance.animDur(200)

    // Momentum below this (px/s) isn't a flick, it's just letting go.
    property real minFlickVelocity: 90

    enabled: root.flickable !== null

    // ── touchpad velocity sampling ────────────────────────────────────
    // Recent {dy, t} pairs, newest last. Only the last few tens of ms matter:
    // the velocity at release is what should carry over, not the average of the
    // whole gesture.
    property var samples: []
    readonly property int sampleWindowMs: 90

    function sample(dy) {
        const now = Date.now();
        const kept = [];
        const list = root.samples;
        for (let i = 0; i < list.length; i++)
            if (now - list[i].t <= root.sampleWindowMs)
                kept.push(list[i]);
        kept.push({
            "dy": dy,
            "t": now
        });
        root.samples = kept;
    }

    function measuredVelocity() {
        const list = root.samples;
        if (list.length < 2)
            return 0;
        const span = (list[list.length - 1].t - list[0].t) / 1000;
        if (span <= 0.001)
            return 0;
        let total = 0;
        for (let i = 0; i < list.length; i++)
            total += list[i].dy;
        return total / span;
    }

    /*
     * Fires once the wheel events stop, which is what stands in for "fingers
     * lifted" — libinput sends no scroll-end that reaches us as a wheel event.
     */
    Timer {
        id: gestureEnd
        interval: 60
        onTriggered: {
            const f = root.flickable;
            root.samples = [];
            if (!f)
                return;
            const velocity = root.measuredVelocity();
            if (Math.abs(velocity) < root.minFlickVelocity)
                return;

            // pixelDelta.y is positive scrolling up, and contentY decreases
            // going up — which is the same sign convention flick() uses for
            // yVelocity, so this passes through unnegated.
            const capped = Math.max(-f.maximumFlickVelocity, Math.min(f.maximumFlickVelocity, velocity));
            f.flick(0, capped);
        }
    }

    WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        enabled: root.enabled

        onWheel: event => {
            const f = root.flickable;
            if (!f || f.contentHeight <= f.height) {
                event.accepted = false;
                return;
            }

            const min = -(f.topMargin || 0);
            const max = Math.max(min, f.contentHeight + (f.bottomMargin || 0) - f.height);
            const pixel = event.pixelDelta.y;

            if (pixel !== 0) {
                // ── touchpad ──
                // A new gesture overrides whatever the last one was still doing.
                if (f.flicking)
                    f.cancelFlick();
                scrollAnim.stop();

                f.contentY = Math.max(min, Math.min(max, f.contentY - pixel));
                root.sample(pixel);
                gestureEnd.restart();
                event.accepted = true;
                return;
            }

            // ── mouse wheel ──
            // Chain onto an in-flight glide so spinning accumulates rather than
            // restarting from wherever the animation happens to be.
            const from = scrollAnim.running ? scrollAnim.to : f.contentY;
            const notches = event.angleDelta.y / 120;
            const to = Math.max(min, Math.min(max, from - notches * root.step));

            if (Math.abs(to - f.contentY) < 0.5) {
                event.accepted = false;   // already at the end — let it through
                return;
            }

            scrollAnim.stop();
            scrollAnim.target = f;
            scrollAnim.to = to;
            scrollAnim.start();
            event.accepted = true;
        }
    }

    NumberAnimation {
        id: scrollAnim
        property: "contentY"
        duration: root.duration
        easing.type: Easing.OutCubic
    }
}
