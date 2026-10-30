pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

/*
 * The one place the app touches the machine.
 *
 * Everything a view needs from outside Qt — run a command, put something on the
 * clipboard, open a URL, set the wallpaper — goes through here, so views never
 * import Quickshell directly and the app stays one file away from running under
 * plain qml6 (see PLAN.md). It is also the only place that knows this desktop's
 * conventions, like where the wallpaper script lives.
 */
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string wallpaperScript: `${root.home}/.config/quickshell/ii/scripts/colors/switchwall.sh`

    property int running: 0
    property string lastCommand: ""
    property string lastError: ""

    /// How long to wait before deciding a process never started. A real one
    /// reports `running` within a frame or two; this is slack for a loaded
    /// machine, not a poll interval.
    property int startGraceMs: 600

    /*
     * Run a command and forget it.
     *
     * Deliberately fire-and-forget with a completion callback rather than a
     * general process API: nothing in this app needs a command's output, and a
     * facade that hands back stdout invites views to start parsing it.
     */
    function run(argv, onDone) {
        if (!argv || argv.length === 0)
            return;
        root.lastCommand = argv.join(" ");
        root.running++;

        const process = procComponent.createObject(root, {
            "command": argv
        });
        if (!process) {
            root.running--;
            root.lastError = "could not start: " + root.lastCommand;
            // A caller waiting on onDone would otherwise wait forever, which
            // reads to the user as the action having silently worked.
            if (onDone)
                onDone(false, -1);
            return;
        }

        // Every exit path runs exactly once: the watchdog below and `exited`
        // can both be in flight, and paying out twice would double-decrement
        // `running` and toast twice.
        let settled = false;
        const finish = function (ok, code) {
            if (settled)
                return;
            settled = true;
            root.running--;
            if (onDone)
                onDone(ok, code);
            process.destroy();
        };

        process.exited.connect(function (code, status) {
            if (code !== 0)
                root.lastError = `${argv[0]} exited ${code}`;
            finish(code === 0, code);
        });
        process.running = true;

        /*
         * A command that does not exist NEVER emits `exited` — measured, not
         * assumed. Without this the failure is perfectly silent: the callback
         * never fires, so a caller that waits for success before saying
         * "copied" simply never says anything.
         *
         * A process that really started reads `running === true` here; one
         * that never started reads false. That is the whole discriminator.
         */
        const watchdog = timerComponent.createObject(root, {
            "interval": root.startGraceMs,
            "running": true
        });
        if (watchdog) {
            watchdog.triggered.connect(function () {
                watchdog.destroy();
                if (settled || process.running)
                    return;
                root.lastError = `${argv[0]}: command not found`;
                finish(false, -1);
            });
        }
    }

    function copyText(text, onDone) {
        if (!text || text.length === 0)
            return;
        // wl-copy takes the text on stdin normally; passing it as an argument
        // avoids wiring a writable stdin for one string.
        root.run(["wl-copy", "--", String(text)], onDone);
    }

    /*
     * Put an actual image on the clipboard, not its path.
     *
     * This is the step that matters for every platform with no upload API: you
     * export, you copy, you paste into their uploader.
     */
    function copyImage(path, mime, onDone) {
        if (!path || path.length === 0)
            return;
        const type = mime && mime.length > 0 ? mime : "image/png";
        root.run(["bash", "-c", `wl-copy --type ${type} < ${JSON.stringify(path)}`], onDone);
    }

    /*
     * Hand a link to whatever the system opens links with.
     *
     * Measured 2026-10-08, because it looked like a likely leak: the three
     * variables shell.qml sets on itself with `pragma Env`
     * (`QT_QUICK_CONTROLS_STYLE`, `QML_XHR_ALLOW_FILE_READ`,
     * `QS_NO_RELOAD_POPUP`) do NOT reach a child process — a stand-in for
     * xdg-open recorded all three as unset. So a browser started from here
     * already gets the session's environment and nothing of quarry's, and no
     * scrubbing is needed.
     */
    function open(target, onDone) {
        if (!target || target.length === 0)
            return;
        const url = String(target);
        // A web address goes to a pack's opener when one wants it (see
        // `openers` on Lens); files and folders always go to xdg-open.
        if (/^https?:\/\//i.test(url)) {
            const pick = (Lenses.openers || []).find(row => {
                try {
                    return !!row.opener && typeof row.opener.matches === "function" && row.opener.matches(url) === true;
                } catch (e) {
                    return false;
                }
            });
            if (pick && Array.isArray(pick.opener.command) && pick.opener.command.length > 0) {
                root.run(pick.opener.command.map(part => String(part) === "%u" ? url : String(part)), function (ok, code) {
                    // An opener that is not there is not the end of the link.
                    if (!ok) {
                        root.run(["xdg-open", url], onDone);
                        return;
                    }
                    if (onDone)
                        onDone(ok, code);
                });
                return;
            }
        }
        root.run(["xdg-open", url], onDone);
    }

    /// Installed browsers for "Open with": desktop entries in the WebBrowser category.
    readonly property var browsers: (DesktopEntries.applications?.values ?? [])
        .filter(e => !e.noDisplay && (e.categories || []).indexOf("WebBrowser") >= 0)
        .map(e => ({ "id": String(e.id), "name": String(e.name) }))
        .sort((a, b) => a.name.localeCompare(b.name))

    /// `target` in one particular app; gtk-launch fills its Exec field codes.
    function openWith(appId, target, onDone) {
        if (!appId || !target || target.length === 0)
            return;
        root.run(["gtk-launch", String(appId), String(target)], onDone);
    }

    function showInFiles(path) {
        if (!path || path.length === 0)
            return;
        const folder = String(path).replace(/\/[^/]*$/, "");
        root.open(folder);
    }

    /*
     * Set the wallpaper, and let the desktop retheme itself.
     *
     * The `ii` config's switchwall.sh is what regenerates the palette, so going
     * through it is the difference between a new picture and a new colour
     * scheme. If it is not there, fall back to hyprpaper/swaybg so the action
     * still does something on another setup.
     */
    /*
     * Open the board application, on a named board.
     *
     * quarry has no canvas of its own — the board is a separate window you keep
     * beside what you are drawing — so "add to a board" needs a way to actually
     * get there. `quarry-board` is a shipped entry point; in a checkout that is
     * not installed it simply will not be found, and saying so beats a button
     * that does nothing.
     */
    function openBoard(name, onDone) {
        const argv = name && name.length > 0 ? ["quarry-board", String(name)] : ["quarry-board"];
        root.run(argv, function (ok, code) {
            if (!ok && code === 127)
                Toast.error("quarry-board is not installed — run tools/install.sh");
            if (onDone)
                onDone(ok);
        });
    }

    function setWallpaper(path, onDone) {
        if (!path || path.length === 0)
            return;
        root.run(["test", "-x", root.wallpaperScript], function (exists) {
            if (exists)
                root.run([root.wallpaperScript, String(path)], onDone);
            else
                // No switcher script: try the two common setters, and let the
                // caller say which one was missing rather than "it failed".
                root.run(["bash", "-c", `swww img ${JSON.stringify(path)} || hyprctl hyprpaper wallpaper ",${path}" || hyprctl hyprpaper reload ",${path}"`], onDone);
        });
    }

    property Component _procComponent: Component {
        id: procComponent
        Process {}
    }

    property Component _timerComponent: Component {
        id: timerComponent
        Timer {}
    }
}
