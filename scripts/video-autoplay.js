// ==QuarryScript==
// @name        Autoplay
// @version     1.2
// @description Videos play as you scroll and autoscroll waits on each; in an open picture, a slideshow (`p`) moves on by itself. `m` toggles sound.
// @author      quarry
// @match       *
// @grant       play, view, timer, keys, toast, dock, storage
// @setting     max | choice | all in view | How many play at once | all in view,1,3,5 | Every video on screen, or only the few nearest the middle. Each one is a live decoder.
// @setting     threshold | choice | 60 | How much must show (%) | 25,60,100 | A video starts once this much of it is on screen, and stops below it.
// @setting     watch | choice | whole video | How long each video gets | whole video,part of it,fixed seconds | Autoscroll waits this long on a video (Wait on), and the slideshow plays it this long before moving on.
// @setting     percent | number | 80 | Part of it (%) | 5..100 step 5 | With "part of it": how much of each video.
// @setting     seconds | number | 5 | Fixed seconds | 1..60 step 1 | With "fixed seconds", and for any video whose length is unknown.
// @setting     longest | number | 30 | Longest wait (seconds) | 5..600 step 5 | "Whole video" and "part of it" never wait longer than this, so a long clip cannot park the wall.
// @setting     pictureSeconds | number | 8 | Slideshow: seconds per picture | 2..60 step 1 | How long the slideshow shows a picture before the next.
// ==/QuarryScript==

/*
 * VIDEOS THAT PLAY THEMSELVES, AND A WALL THAT WAITS FOR THEM.
 *
 * From the Reddtastic userscript: every video in view plays, muted, and
 * autoscroll stops on each one as it reaches the middle — centred, held for
 * the watch time, then on. The playing and the holding live in quarry
 * (`@grant play`); this is their switchboard, next to Autoscroll's.
 *
 * THE SLIDESHOW IS THE SAME IDEA IN THE VIEWER. With a picture open, the
 * Slideshow switch (or `p`) moves on by itself: a picture after its seconds,
 * a video after the same watch time autoscroll uses — to its end, part of it,
 * or fixed seconds. While it runs the viewer plays videos once rather than on
 * a loop, so "the end" exists.
 *
 * Settings › Video has the same switches. This script's settings and that
 * page write the same preferences: a value changed here is applied when the
 * script loads, and one changed there is written back here, so the two never
 * disagree.
 */
const WATCH = { "whole video": "full", "part of it": "percent", "fixed seconds": "fixed" };
const WATCH_NAME = { full: "whole video", percent: "part of it", fixed: "fixed seconds" };

let state = quarry.autoplay();

// What this page holds, in its own words, for a given state.
function asSettings(s) {
    return {
        max: s.slots === 0 ? "all in view" : String(s.slots),
        threshold: String(s.threshold),
        watch: WATCH_NAME[s.watch] || "whole video",
        percent: s.percent,
        seconds: s.seconds,
        longest: s.longest
    };
}

// On load: a value saved on this page wins; anything never set here takes quarry's.
(function sync() {
    const mine = asSettings(state);
    for (const key of Object.keys(mine)) {
        const saved = quarry.storage.get(key, null);
        if (saved === null) {
            quarry.storage.set(key, mine[key]);
            continue;
        }
        if (String(saved) === String(mine[key]))
            continue;
        if (key === "max")
            state = quarry.setAutoplay("slots", saved === "all in view" ? 0 : Number(saved));
        else if (key === "watch")
            state = quarry.setAutoplay("watch", WATCH[saved] || "full");
        else
            state = quarry.setAutoplay(key, Number(saved));
    }
})();

function show() {
    quarry.dockSet("play", { value: state.on });
    quarry.dockSet("all", { value: state.all });
    quarry.dockSet("sound", { value: state.sound, icon: state.sound ? "volume_up" : "volume_off" });
    quarry.dockSet("hold", { value: state.hold });
    quarry.dockSet("centre", { value: state.centre });
}

function set(key, on) {
    state = quarry.setAutoplay(key, on);
    show();
}

quarry.dock({
    title: "Autoplay",
    icon: "autoplay",
    items: [
        { id: "play", kind: "toggle", primary: true, label: "Play", menu: "Play videos as they come into view",
          icon: "play_arrow", value: state.on, on: on => set("on", on) },
        { id: "all", kind: "toggle", label: "All in view", menu: "Every video in view, not just the nearest few",
          icon: "select_all", value: state.all, on: on => set("all", on) },
        // Icon-only: the speaker says it, and the dock stays short.
        { id: "sound", kind: "toggle", label: "", menu: "Sound for the video in the middle",
          icon: state.sound ? "volume_up" : "volume_off", value: state.sound, on: on => set("sound", on) },
        // The tie to Autoscroll: it holds on each video while this is on.
        { id: "hold", kind: "toggle", label: "Wait", menu: "Autoscroll waits on each video",
          icon: "motion_photos_pause", value: state.hold, on: on => set("hold", on) },
        { id: "centre", kind: "toggle", label: "", menu: "Centre each video before waiting",
          icon: "center_focus_strong", value: state.centre, on: on => set("centre", on) },
        { id: "slide", kind: "toggle", label: "Slideshow", menu: "Slideshow in the open picture",
          icon: "slideshow", value: false, on: on => slide(on) }
    ],
    // Kept in the viewer too: the slideshow is about the picture that is open.
    overViewer: true
});

// ── the slideshow ────────────────────────────────────────────────────────────
const PICTURE_SECONDS = quarry.storage.get("pictureSeconds", 8);
let sliding = false;
let elapsed = 0;
let lastId = "";
let ended = false;
let steppedFrom = "";

function slide(on) {
    if (on && !quarry.viewerOpen()) {
        quarry.toast("Open a picture first — the slideshow moves through the viewer");
        on = false;
    }
    sliding = on;
    quarry.slideshow(on);
    elapsed = 0;
    lastId = "";
    ended = false;
    steppedFrom = "";
    quarry.dockSet("slide", { value: sliding });
}

/// Has the open item had its time? Pictures by seconds, videos by the watch time.
function due(v) {
    if (!v.video)
        return elapsed >= PICTURE_SECONDS;
    const length = v.duration;
    if (!(length > 0))
        return elapsed >= state.seconds;
    if (state.watch === "full")
        return ended || v.position >= Math.min(length, state.longest) - 0.4;
    if (state.watch === "percent")
        return v.position >= Math.min(length * state.percent / 100, state.longest);
    return elapsed >= state.seconds;
}

quarry.on("videoend", function () {
    ended = true;
});

quarry.every(1, function () {
    if (!sliding)
        return;
    if (!quarry.viewerOpen()) {
        slide(false);
        return;
    }
    const v = quarry.viewerVideo();
    if (steppedFrom.length > 0 && v.id === steppedFrom) {
        // Stepping did not move: the end of the list.
        slide(false);
        quarry.toast("Slideshow: that was the last one");
        return;
    }
    steppedFrom = "";
    if (v.id !== lastId) {
        lastId = v.id;
        elapsed = 0;
        ended = false;
    }
    elapsed++;
    if (due(v)) {
        steppedFrom = v.id;
        quarry.step(1);
    }
});

quarry.key("p", function () {
    // On the wall `p` is autoscroll's "previous video"; in a picture it is the slideshow.
    if (!quarry.viewerOpen())
        return;
    slide(!sliding);
    quarry.toast(sliding ? "Slideshow on — p stops it" : "Slideshow off");
});

// Settings › Video changed something: follow it, here and on this page.
quarry.on("autoplay", function (next) {
    state = next;
    const mine = asSettings(state);
    for (const key of Object.keys(mine))
        quarry.storage.set(key, mine[key]);
    show();
});

quarry.key("m", function () {
    set("sound", !state.sound);
    quarry.toast(state.sound ? "Sound on — the video in the middle" : "Sound off");
});
