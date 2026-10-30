pragma Singleton
import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Io

/*
 * Export targets — data, not code.
 *
 * A target is a named place a picture is going: a Steam avatar, a Discord
 * banner, a wallpaper for one particular monitor. Each carries the recipe the
 * daemon applies (see image::Recipe in PROTOCOL.md). Adding a platform is a
 * JSON object, never a branch.
 *
 * The built-ins below are a starting set, and the wallpaper targets are
 * generated from the monitors actually attached — a 3440×1440 export is only
 * correct if that is really the screen it is for.
 */
Singleton {
    id: root

    readonly property string configPath: `${Quickshell.env("HOME")}/.config/quarry/targets.json`

    readonly property var builtin: [
        {
            "id": "steam-avatar",
            "label": "Steam avatar",
            "group": "Steam",
            "icon": "account_circle",
            /*
             * WHAT HAPPENS WHEN THE FILE EXISTS.
             *
             * A wallpaper gets applied; an avatar just became a PNG in
             * ~/Pictures and left you to finish the job — find it, open the
             * site, upload it. So the destination finishes it: the picture
             * itself goes on the clipboard (not its path, which is what you
             * cannot paste into an upload box) and the page it belongs on
             * opens. Two steps you were doing by hand.
             */
            "after": {
                "copyImage": true,
                "open": "https://steamcommunity.com/my/edit/avatar",
                "say": "Copied · paste it on the Steam page"
            },
                        "recipe": {
                "width": 184,
                "height": 184,
                "fit": "cover",
                "gravity": "smart",
                "format": "png",
                "quality": 92,
                "radius": 0,
                "background": "#00000000"
            },
            "note": "Steam stores what you upload and derives 184/64/32 itself."
        },
        {
            "id": "steam-avatar-hi",
            "label": "Steam avatar (512)",
            "group": "Steam",
            "icon": "account_circle",
            "after": {
                "copyImage": true,
                "open": "https://steamcommunity.com/my/edit/avatar",
                "say": "Copied · paste it on the Steam page"
            },
            "recipe": {
                "width": 512,
                "height": 512,
                "fit": "cover",
                "gravity": "smart",
                "format": "png",
                "quality": 92,
                "radius": 0,
                "background": "#00000000"
            },
            "note": "Uploading larger renders crisper at every size Steam shows."
        },
        {
            "id": "discord-avatar",
            "label": "Discord avatar",
            "group": "Chat",
            "icon": "chat",
                        "recipe": {
                "width": 512,
                "height": 512,
                "fit": "cover",
                "gravity": "smart",
                "format": "png",
                "quality": 92,
                "radius": 0,
                "background": "#00000000"
            }
        },
        {
            "id": "discord-banner",
            "label": "Discord banner",
            "group": "Chat",
            "icon": "panorama",
                        "recipe": {
                "width": 600,
                "height": 240,
                "fit": "cover",
                "gravity": "smart",
                "format": "png",
                "quality": 92,
                "radius": 0,
                "background": "#00000000"
            }
        },
        /*
         * The rest of the places a profile picture goes.
         *
         * pfps.gg describes itself as pictures "to use on Discord, Instagram,
         * Tiktok and Twitter", and the app had destinations for two of those.
         * Sizes are each service's upload minimum rounded up to a square they
         * will not resample twice — uploading exactly the displayed size gives
         * a soft picture the moment anything shows it larger.
         */
        {
            "id": "instagram-avatar",
            "label": "Instagram picture",
            "group": "Social",
            "icon": "photo_camera",
            "recipe": {
                "width": 640, "height": 640, "fit": "cover", "gravity": "smart",
                "format": "jpg", "quality": 92, "radius": 0, "background": "#00000000"
            },
            "note": "Displays at 110px; 640 survives their re-encode."
        },
        {
            "id": "tiktok-avatar",
            "label": "TikTok picture",
            "group": "Social",
            "icon": "music_note",
            "recipe": {
                "width": 500, "height": 500, "fit": "cover", "gravity": "smart",
                "format": "jpg", "quality": 92, "radius": 0, "background": "#00000000"
            },
            "note": "200px minimum; 500 keeps it sharp on a profile page."
        },
        {
            "id": "x-avatar",
            "label": "X picture",
            "group": "Social",
            "icon": "tag",
            "recipe": {
                "width": 400, "height": 400, "fit": "cover", "gravity": "smart",
                "format": "png", "quality": 92, "radius": 0, "background": "#00000000"
            },
            "note": "400×400 is what X stores."
        },
        {
            "id": "x-header",
            "label": "X header",
            "group": "Social",
            "icon": "panorama",
            "recipe": {
                "width": 1500, "height": 500, "fit": "cover", "gravity": "smart",
                "format": "jpg", "quality": 92, "radius": 0, "background": "#00000000"
            },
            "note": "3:1. The middle is what survives on mobile."
        },
        {
            "id": "reddit-avatar",
            "label": "Reddit picture",
            "group": "Social",
            "icon": "forum",
            "recipe": {
                "width": 256, "height": 256, "fit": "cover", "gravity": "smart",
                "format": "png", "quality": 92, "radius": 0, "background": "#00000000"
            },
            "note": "256×256, and Reddit keeps transparency."
        },
        {
            "id": "favicon",
            "label": "Favicon (32)",
            "group": "Small",
            "icon": "web",
            "recipe": {
                "width": 32,
                "height": 32,
                "fit": "contain",
                "gravity": "center",
                "format": "png",
                "quality": 92,
                "radius": 0,
                "background": "#00000000"
            }
        },
        {
            "id": "app-icon",
            "label": "App icon (256)",
            "group": "Small",
            "icon": "apps",
            "recipe": {
                "width": 256,
                "height": 256,
                "fit": "contain",
                "gravity": "center",
                "format": "png",
                "quality": 92,
                "radius": 0,
                "background": "#00000000"
            }
        },
        /*
         * TELEGRAM.
         *
         * Three destinations, because Telegram treats them as three different
         * kinds of file and gets loud about it — a sticker that is 511px wide
         * is rejected outright, and a profile photo is squared whatever you
         * upload. See services/Dispatch.qml for the send path; these exist on
         * their own too, so "export a Telegram sticker to a file" works with
         * no Morse anywhere.
         */
        {
            "id": "telegram-profile-photo",
            "label": "Telegram profile photo",
            "group": "Chat",
            "icon": "account_circle",
            "recipe": {
                "width": 800,
                "height": 800,
                "fit": "cover",
                "gravity": "smart",
                "format": "jpeg",
                "quality": 92,
                "radius": 0,
                "background": "#000000ff"
            },
            "note": "Telegram squares it and keeps 800×800; everything smaller it derives itself."
        },
        {
            "id": "telegram-sticker",
            "label": "Telegram sticker",
            "group": "Chat",
            "icon": "sentiment_satisfied",
            "recipe": {
                "width": 512,
                "height": 512,
                "fit": "contain",
                "gravity": "center",
                "format": "png",
                "quality": 100,
                "radius": 0,
                // Transparent, and `contain` rather than `cover`: a sticker is
                // a cut-out, so the sides that do not reach 512 must be empty
                // rather than filled or cropped away.
                "background": "#00000000"
            },
            "note": "512 on the long side, transparent PNG, under 512 KB."
        },
        {
            "id": "telegram-animation",
            "label": "Telegram GIF",
            "group": "Chat",
            "icon": "gif",
            "recipe": {
                "width": 0,
                "height": 0,
                "fit": "none",
                "gravity": "center",
                "format": "png",
                "quality": 100,
                "radius": 0,
                "background": "#00000000",
                /*
                 * WRITTEN THROUGH, NOT RE-ENCODED.
                 *
                 * The still pipeline decodes one frame, so a GIF that went
                 * through it would arrive as a picture of the first frame —
                 * which is the failure that looks like a success. `verbatim`
                 * is a recipe flag quarryd does not have yet (serde ignores
                 * what it does not know, so an older daemon quietly falls back
                 * to the re-encode); Dispatch checks the reply for it and
                 * refuses rather than sending a still.
                 */
                "verbatim": true
            },
            "note": "The file untouched — Telegram converts a GIF to a looping MP4 on arrival."
        },
        {
            "id": "original",
            "label": "Original size",
            "group": "Plain",
            "icon": "photo_size_select_large",
            "recipe": {
                "width": 0,
                "height": 0,
                "fit": "none",
                "gravity": "center",
                "format": "png",
                "quality": 95,
                "radius": 0,
                "background": "#00000000"
            }
        }
    ]

    /*
     * One wallpaper target per connected monitor, at that monitor's real size.
     *
     * This is the reason targets are generated rather than listed: "wallpaper"
     * is not a size, it is whichever screen you meant.
     */
    readonly property var monitorTargets: {
        const out = [];
        for (const screen of Quickshell.screens) {
            /*
             * Physical pixels, not logical.
             *
             * `screen.width` is the compositor's logical size — on a 2560×1600
             * panel at 1.67 scale that reads 1536×960, and exporting a
             * wallpaper at 1536×960 for a 2560-wide screen is a soft
             * wallpaper. The panel's real pixel count is what a wallpaper has
             * to match.
             */
            const dpr = screen.devicePixelRatio > 0 ? screen.devicePixelRatio : 1;
            const pixelWidth = Math.round(screen.width * dpr);
            const pixelHeight = Math.round(screen.height * dpr);

            out.push({
                "id": "wallpaper-" + screen.name,
                "label": `Wallpaper · ${screen.name} (${pixelWidth}×${pixelHeight})`,
                "group": "Desktop",
                "icon": "wallpaper",
                "recipe": {
                    "width": pixelWidth,
                    "height": pixelHeight,
                    "fit": "cover",
                    "gravity": "smart",
                    "format": "png",
                    "quality": 95,
                    "radius": 0,
                    "background": "#000000ff"
                },
                /*
                 * EXPORTING A WALLPAPER IS NOT SETTING ONE.
                 *
                 * A file in ~/Pictures is not a desktop. The shell already owns
                 * that whole sequence — set the picture, regenerate the palette
                 * through tinct, rewrite the templates, append to recents — so
                 * this hands the exported path to it rather than reproducing
                 * any part of it. `{path}` is substituted with what the daemon
                 * wrote. Override the script with $QUARRY_WALLPAPER_HOOK.
                 */
                "apply": [
                    Quickshell.env("QUARRY_WALLPAPER_HOOK")
                        || `${Quickshell.env("HOME")}/.config/quickshell/ii/scripts/colors/switchwall.sh`,
                    "--image", "{path}"
                ],

                /*
                 * A MOVING WALLPAPER IS A DIFFERENT PROGRAM.
                 *
                 * `switchwall.sh` sets a picture and regenerates the palette
                 * from it; neither half means anything for an mp4. mpvpaper
                 * puts an mpv window on the background layer instead, and this
                 * is per-monitor because it takes the output name — the one
                 * piece of the wallpaper story that was already per-monitor
                 * here.
                 *
                 * The options are not decoration:
                 *   -f          fork, so quarry is not the video's parent and
                 *               closing the gallery does not kill the desktop
                 *   -p -a FULL  pause the moment anything is fullscreen. A
                 *               wallpaper that keeps decoding 4K video behind
                 *               a game is a frame rate you paid for wallpaper.
                 *   no-audio    a desktop background does not make noise —
                 *               unless asked to. `Prefs.wallpaperSound` drops
                 *               this flag and passes the viewer's volume, which
                 *               mpv takes as a percentage rather than 0..1.
                 *   loop        it is a wallpaper; it does not end
                 *   panscan     fill the screen rather than letterbox it
                 * Override the whole thing with $QUARRY_VIDEO_WALLPAPER_HOOK.
                 */
                "applyVideo": Quickshell.env("QUARRY_VIDEO_WALLPAPER_HOOK")
                    ? [Quickshell.env("QUARRY_VIDEO_WALLPAPER_HOOK"), "{path}", screen.name]
                    : [
                        "mpvpaper", "-f", "-p", "-a", "FULL",
                        "-o", Prefs.wallpaperSound
                            ? `loop panscan=1.0 volume=${Math.round(Prefs.videoVolume * 100)}`
                            : "no-audio loop panscan=1.0",
                        screen.name, "{path}"
                    ]
            });
        }
        return out;
    }

    // User targets override a built-in of the same id, the way extensions do.
    property var user: []

    /// Why `user` is empty when it is, or stale after an edit that didn't
    /// parse. A menu that is just missing the targets you added looks like it
    /// forgot them; this is the only place that would say the file is broken.
    property string configError: ""

    /*
     * A TARGET THAT CAME FROM OUTSIDE IS NOT NECESSARILY COMPLETE.
     *
     * The built-ins carry a group, an icon, a note and a full recipe. Something
     * written by hand in targets.json, or registered by an extension, carries
     * whatever its author thought of — and the menus read every one of those
     * fields. Measured with a four-field target: five "Unable to assign
     * [undefined] to QString" warnings and a TypeError out of TargetSheet,
     * because `recipe` was simply absent.
     *
     * So the shape is filled in rather than trusted. `width`/`height` at the
     * top level are accepted as a recipe, because that is what somebody writes
     * when they have not read this file.
     */
    function normalise(target) {
        if (!target || !target.id)
            return null;
        const recipe = target.recipe || {};
        const width = Number(recipe.width || target.width || 0);
        const height = Number(recipe.height || target.height || 0);
        /*
         * MERGED ONTO WHAT CAME IN, never rebuilt from a list of names.
         *
         * A rebuild is a whitelist, and a whitelist silently drops: `apply` and
         * `applyVideo` are what actually SET a wallpaper (Catalog runs them
         * after the export), so a contributed target carrying one would have
         * written the file and then done nothing at all — an export that looks
         * like it worked. Anything this does not know about travels through.
         */
        return Object.assign({}, target, {
            "id": String(target.id),
            "label": String(target.label || target.id),
            "group": String(target.group || "Other"),
            "icon": String(target.icon || "extension"),
            "note": String(target.note || ""),
            "recipe": {
                "width": width,
                "height": height,
                // No size given means "leave it alone", which is a real target
                // (Original is one) rather than a 0×0 crop.
                "fit": String(recipe.fit || (width > 0 && height > 0 ? "cover" : "none")),
                "gravity": String(recipe.gravity || "smart"),
                "format": String(recipe.format || "png"),
                "quality": Number(recipe.quality === undefined ? 92 : recipe.quality),
                "radius": Number(recipe.radius || 0),
                "background": String(recipe.background || "#00000000")
            }
        });
    }

    /*
     * Built-in, then the monitors, then whatever an extension contributed,
     * then yours — last wins on an id, so your targets.json can correct any of
     * them. `Host.targets` was registered and read by nothing until now: an
     * extension could add a target and it appeared in no menu.
     */
    readonly property var all: {
        const merged = {};
        for (const target of root.builtin.concat(root.monitorTargets))
            merged[target.id] = target;
        for (const list of [Host.targets, root.user])
            for (const target of list) {
                const fixed = root.normalise(target);
                if (fixed)
                    merged[fixed.id] = fixed;
            }
        return Object.values(merged);
    }

    function byId(id) {
        return root.all.find(t => t.id === id) || null;
    }

    readonly property var groups: {
        const seen = [];
        for (const target of root.all)
            if (seen.indexOf(target.group) < 0)
                seen.push(target.group);
        return seen;
    }

    // Recent targets float to the top of the menu: an export is a habit, and a
    // menu that reorders itself around the habit stays short.
    property var recent: []

    function remember(id) {
        const next = [id].concat(root.recent.filter(r => r !== id));
        root.recent = next.slice(0, 3);
    }

    FileView {
        path: root.configPath
        watchChanges: true
        // User targets are optional, so a missing file is the normal case, not
        // a problem to report.
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                const parsed = JSON.parse(text());
                root.user = Array.isArray(parsed.targets) ? parsed.targets : [];
                root.configError = Array.isArray(parsed.targets) ? "" : "targets.json has no \"targets\" array";
            } catch (e) {
                console.warn("[targets] ~/.config/quarry/targets.json is not valid JSON:", e);
                root.configError = "targets.json is not valid JSON: " + e;
                root.user = [];
            }
        }
    }
}
