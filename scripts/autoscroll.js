// ==QuarryScript==
// @name        Autoscroll
// @version     1.0
// @description Scrolls the wall by itself. `a` starts and stops it, the digits set the speed, `n`/`p` jump between videos. Waiting on videos is the Autoplay extension's.
// @author      quarry
// @match       *
// @grant       view, keys, toast, storage, dock
// @setting     speed | number | 60 | Speed | 10..400 step 10 | Pixels a second. The digit keys set this too.
// @setting     up | switch | false | Scroll upward | | Starts going up instead of down. The dock switches it either way.
// @setting     atEnd | choice | stop | At the end | stop,turn around | Stop there, or reverse and come back.
// @setting     announce | switch | true | Say when it stops | | A toast when it reaches an end. Off, it just stops.
// @setting     immersive | switch | false | Just the pictures | | Hides the search bar and the rail while it scrolls.
// ==/QuarryScript==

/*
 * A WALL THAT READS ITSELF.
 *
 * Two hundred thousand pictures is not a thing you flick through: past the
 * first screen your hand is doing the same motion over and over while your
 * eyes do the actual work. Letting it move on its own turns browsing into
 * watching, which is a different — and for a big catalogue, better — way to
 * look at it.
 *
 * The scrolling itself belongs to quarry (`@grant view`), not to this file:
 * a script driving `contentY` on its own timer has to reimplement easing,
 * clamping and the end of the list, and would get at least one of them wrong.
 * This says how fast, and stops caring.
 */
const SPEEDS = [10, 20, 40, 60, 90, 130, 180, 250, 340];   // 1…9, pixels a second

let speed = quarry.storage.get("speed", 60);
/*
 * WHICH WAY, CHOSEN RATHER THAN GUESSED.
 *
 * Down is right for a wall, which fills downwards. It is wrong for a chat,
 * where what you have not read is ABOVE where you are sitting, and wrong again
 * for anything you are re-reading. Nothing about the view says which of those
 * you are doing, so the view is the wrong place to ask: this is a switch.
 *
 * Increasing `contentY` is visually downward in every layout, including the
 * bottom-to-top lists a conversation uses (measured), so the sign is all it
 * takes — there is no per-view special case behind this.
 */
let up = quarry.storage.get("up", false);
/*
 * WHAT THE END OF THE LIST MEANS, which is not one thing.
 *
 * Stopping is right for a finite list you have now seen all of. On a list you
 * are reading rather than filling, turning around and coming back is better.
 *
 * "Carry on until more arrives" is not a choice here because the host already
 * does it: a boundary starts a two-second count and a list that grows resets
 * it, at both ends. So `scrollend` means the list really stopped growing.
 */
const atEnd = quarry.storage.get("atEnd", "stop");
const announce = quarry.storage.get("announce", true);
// Neither the search bar nor the rail is a picture, and neither is
// something you touch while the wall reads itself.
const immersive = quarry.storage.get("immersive", false);
let running = false;

function apply() {
    quarry.scroll(running ? (up ? -speed : speed) : 0);
    if (immersive)
        quarry.chrome(!running);
    quarry.dockSet("run", { value: running });
    quarry.dockSet("speed", { value: speed });
    /*
     * THE DIRECTION CONTROL NAMES THE DIRECTION IT IS IN.
     *
     * It was a toggle labelled "Up" whatever its state, with only a colour to
     * tell the two apart — so "↑ Up" could equally mean "going up" or "press
     * for up", and the only way to find out was to press it and watch. The
     * label and the arrow now say which way it is scrolling right now.
     */
    quarry.dockSet("up", {
        value: up,
        label: up ? "Up" : "Down",
        icon: up ? "arrow_upward" : "arrow_downward"
    });
}

/*
 * THE SAME TWO CONTROLS, DRAWN.
 *
 * `a` and the digits still work and always will — but a keybind nobody told
 * you about is a feature that does not exist, and the speed was a number you
 * could only discover by reading this file. Switch the dock on from the ⋮
 * menu and it is a switch and a slider.
 */
quarry.dock({
    title: "Autoscroll",
    /*
     * `swap_vert` rather than `swipe_down`: the icon has to say "both ways",
     * because the direction control right next to it switches between them,
     * and a downward arrow beside a control reading "Up" is the dock
     * contradicting itself.
     */
    icon: "swap_vert",
    /*
     * KEPT WHILE A PICTURE IS OPEN.
     *
     * Docks that drive the wall are dropped in the viewer, on the grounds that
     * the wall is not what you are looking at. That is wrong for this one: a
     * lens viewer scrolls — a thread, a feed, a comment list — and "read this
     * by itself" is wanted there more than anywhere. quarry picks whichever
     * surface is actually scrollable, so the same control drives whatever is
     * in front of you.
     */
    overViewer: true,
    items: [
        // `menu` is what the row is called in the ⋮ menu, where there is no
        // title above it to say which script it belongs to.
        { id: "run", kind: "toggle", label: "Scroll", menu: "Autoscroll the wall", icon: "play_arrow", value: false,
          on: on => { running = on; apply(); } },
        { id: "speed", kind: "slider", label: "px/s", menu: "Scroll speed", min: 10, max: 340, step: 10, value: speed,
          on: v => { speed = Math.round(v); quarry.storage.set("speed", speed); running = true; apply(); } },
        // Flipping direction while it is stopped does not start it: unlike the
        // speed digits, "which way" is a thing you set before you begin.
        { id: "up", kind: "toggle", label: up ? "Up" : "Down", menu: "Scroll upward",
          icon: up ? "arrow_upward" : "arrow_downward", value: up,
          on: on => { up = on; quarry.storage.set("up", up); apply(); } }
    ]
});

/*
 * THE SWITCH HAS TO FOLLOW WHAT ACTUALLY HAPPENED.
 *
 * quarry stops the scroll on its own at either end of the view — and used to do
 * it silently, so this script went on believing it was running. The toggle
 * stayed lit at the bottom of the wall, the dock said "Scroll · on" over
 * something that had not moved in minutes, and the only way to find out was to
 * press stop on something already stopped.
 */
quarry.on("scrollend", function (info) {
    if (!running)
        return;

    const reason = info && info.reason;
    const where = reason === "top" ? "the top" : "the end";

    // Nothing to scroll is not an end to turn around at: there is no list.
    if (reason !== "gone" && atEnd === "turn around") {
        up = !up;
        apply();
        if (announce)
            quarry.toast(`Turned around at ${where}`);
        return;
    }

    running = false;
    apply();
    if (announce)
        quarry.toast(reason === "gone" ? "Nothing to scroll here" : `Stopped at ${where}`);
});

quarry.key("a", function () {
    running = !running;
    apply();
    quarry.toast(running ? `Scrolling ${up ? "up" : "down"} — ${speed} px/s · a stops it, 1-9 change the speed` : "Scrolling stopped");
});

/*
 * N / P, from the Reddtastic userscript: the next or previous video centred
 * (held on while scrolling). Sound (`m`) lives in the Autoplay extension.
 * Only on the wall: in an open picture these letters belong to the viewer.
 */
quarry.key("n", function () {
    if (quarry.viewerOpen())
        return;
    if (!quarry.jumpVideo(1))
        quarry.toast("No video below yet — moved a screen");
});
quarry.key("p", function () {
    if (quarry.viewerOpen())
        return;
    if (!quarry.jumpVideo(-1))
        quarry.toast("No video above — moved a screen");
});

// Digits pick a speed, and picking one while it is stopped starts it: nobody
// presses 7 at a still screen to mean "remember 7 for later".
for (let i = 1; i <= 9; i++) {
    quarry.key(String(i), function () {
        speed = SPEEDS[i - 1];
        quarry.storage.set("speed", speed);
        running = true;
        apply();
        quarry.toast(`${speed} px/s`);
    });
}
