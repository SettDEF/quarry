pragma Singleton

import qs.modules.common
import QtQuick
import Quickshell

/*
 * WHAT YOU ARE FILLING.
 *
 * The app is not a picture browser; it fits a picture to a destination. That
 * destination was never stated anywhere, and everything downstream suffered for
 * it: the detail view's primary button was whichever target you happened to use
 * last (so it read as arbitrary), avatars and icons had no way in from inside
 * the app at all, and matching a screen's shape meant typing `ratio>=2.3` at a
 * query bar and knowing to.
 *
 * A slot is a TARGET plus the query that finds candidates for it. The target
 * half already existed — `Targets.monitorTargets` even generates one per
 * connected monitor at its real pixel size — so this adds the missing half and
 * names the pair.
 */
Singleton {
    id: root

    /// The slot in force. Null means "Everything": browsing with no destination
    /// in mind, which is a legitimate thing to do and stays available — it is
    /// just no longer the only thing on offer.
    property var current: null

    /// Slots for the screens actually attached, ahead of the fixed ones: this
    /// is a desktop tool first, and a monitor is the destination that matters
    /// most. Ratio comes from the panel itself, so nobody types it.
    readonly property var screenSlots: {
        const out = [];
        for (const screen of Quickshell.screens) {
            const dpr = screen.devicePixelRatio || 1;
            const w = Math.round(screen.width * dpr);
            const h = Math.round(screen.height * dpr);
            const ratio = h > 0 ? (w / h) : 1.6;
            out.push({
                "id": "slot-wallpaper-" + screen.name,
                "label": `Wallpaper · ${screen.name}`,
                "detail": `${w}×${h}`,
                "icon": "wallpaper",
                "targetId": "wallpaper-" + screen.name,
                // A window of ±8% around the panel's own aspect. Exact equality
                // would reject a 16:10 picture for a 16:9 screen, which is a
                // crop away from perfect and worth offering.
                "query": `kind:wallpaper ratio>${(ratio * 0.92).toFixed(2)} ratio<${(ratio * 1.08).toFixed(2)} -nsfw`,
                "verb": "Set wallpaper"
            });
        }
        return out;
    }

    readonly property var fixedSlots: [
        {
            "id": "slot-avatar",
            "label": "Avatar",
            "detail": "square",
            "icon": "account_circle",
            "targetId": "steam-avatar",
            "query": "kind:avatar ratio>0.9 ratio<1.1 -nsfw",
            // Named for what it does, not for the file it happens to write.
            "verb": "Copy for Steam"
        },
        {
            "id": "slot-banner",
            "label": "Banner",
            "detail": "wide",
            "icon": "panorama",
            "targetId": "discord-banner",
            "query": "kind:banner ratio>2.4 -nsfw",
            "verb": "Save banner"
        },
        {
            "id": "slot-icon",
            "label": "Icon",
            "detail": "vector",
            "icon": "apps",
            "targetId": "app-icon",
            "query": "family:vector tintable",
            "verb": "Save icon"
        }
    ]

    readonly property var all: root.screenSlots.concat(root.fixedSlots)

    /*
     * The slot a query is asking for, if it is asking for one.
     *
     * `quarry --kind avatar` set a query string and nothing else, so the app
     * knew what to SEARCH for and still had no idea what you were FILLING —
     * the dock said "Everything" while the results were avatars, and the
     * primary action fell back to whatever was used last. The launcher already
     * names the slot; this reads it.
     */
    function matchQuery(q) {
        if (!q || q.length === 0)
            return null;
        const text = q.toLowerCase();
        const kind = (text.match(/kind:([a-z0-9-]+)/) || [])[1] || "";
        if (kind === "wallpaper") {
            // The screen you are on, not merely the first one attached.
            return root.screenSlots[0] || null;
        }
        if (kind === "avatar")
            return root.byId("slot-avatar");
        if (kind === "banner")
            return root.byId("slot-banner");
        if (text.indexOf("family:vector") >= 0)
            return root.byId("slot-icon");
        return null;
    }

    function byId(id) {
        return root.all.find(s => s.id === id) || null;
    }

    /// Choose a slot: the query and the export target move together, which is
    /// the whole point of naming the pair.
    function choose(slot) {
        root.current = slot;
        if (!slot) {
            Catalog.query = "";
            return;
        }
        Catalog.query = slot.query;
        Targets.remember(slot.targetId);
    }

    /// The target a commit should use — the slot's, or the last one used when
    /// browsing without a slot.
    readonly property string activeTargetId:
        root.current ? root.current.targetId
                     : (Targets.recent.length > 0 ? Targets.recent[0] : "original")
}
