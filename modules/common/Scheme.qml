pragma Singleton
import QtQuick
import QtCore

/*
 * The raw Material 3 role map.
 *
 * Rodded does not generate colours — tinct already does that for the whole
 * desktop and writes the result where quickshell's MaterialThemeLoader reads
 * it. This singleton just consumes the same file and re-reads it when it
 * changes, so the app recolours in step with the wallpaper:
 *
 *   ~/.local/state/quickshell/user/generated/material_colors.scss
 *
 * The built-in map below is only a cold-start fallback for a machine that has
 * never run the theming pipeline — it is never used to "theme" anything.
 */
QtObject {
    id: root

    readonly property string home: {
        const u = StandardPaths.writableLocation(StandardPaths.HomeLocation).toString();
        return u.replace(/^file:\/\//, "");
    }

    // Overridable so a non-quickshell setup can point at its own tinct output.
    property string scssPath: `${home}/.local/state/quickshell/user/generated/material_colors.scss`

    // "tinct" once the desktop palette has been read, "fallback" before that.
    property string source: "fallback"
    property bool watching: true
    property string _lastRaw: ""

    signal reloaded

    readonly property var fallback: ({
            "darkmode": true,
            "background": "#141313",
            "onBackground": "#e6e1e1",
            "surface": "#141313",
            "surfaceDim": "#141313",
            "surfaceBright": "#3a3939",
            "surfaceContainerLowest": "#0f0e0e",
            "surfaceContainerLow": "#1c1b1c",
            "surfaceContainer": "#201f20",
            "surfaceContainerHigh": "#2b2a2a",
            "surfaceContainerHighest": "#363435",
            "onSurface": "#e6e1e1",
            "surfaceVariant": "#49464a",
            "onSurfaceVariant": "#cbc5ca",
            "inverseSurface": "#e6e1e1",
            "inverseOnSurface": "#313030",
            "outline": "#948f94",
            "outlineVariant": "#49464a",
            "shadow": "#000000",
            "scrim": "#000000",
            "surfaceTint": "#cbc4cb",
            "primary": "#cbc4cb",
            "onPrimary": "#322f34",
            "primaryContainer": "#2d2a2f",
            "onPrimaryContainer": "#bcb6bc",
            "inversePrimary": "#615d63",
            "secondary": "#cac5c8",
            "onSecondary": "#323032",
            "secondaryContainer": "#4d4b4d",
            "onSecondaryContainer": "#ece6e9",
            "tertiary": "#d1c3c6",
            "onTertiary": "#372e30",
            "tertiaryContainer": "#31292b",
            "onTertiaryContainer": "#c1b4b7",
            "error": "#ffb4ab",
            "onError": "#690005",
            "errorContainer": "#93000a",
            "onErrorContainer": "#ffdad6",
            "success": "#b5ccba",
            "onSuccess": "#213528",
            "successContainer": "#374b3e",
            "onSuccessContainer": "#d1e9d6",
            "primaryFixed": "#e7e0e7",
            "primaryFixedDim": "#cbc4cb",
            "onPrimaryFixed": "#1d1b1f",
            "onPrimaryFixedVariant": "#49454b",
            "secondaryFixed": "#e6e1e4",
            "secondaryFixedDim": "#cac5c8",
            "onSecondaryFixed": "#1d1b1d",
            "onSecondaryFixedVariant": "#484648",
            "tertiaryFixed": "#eddfe1",
            "tertiaryFixedDim": "#d1c3c6",
            "onTertiaryFixed": "#211a1c",
            "onTertiaryFixedVariant": "#4e4447"
        })

    property var colors: fallback

    // ── scss parsing ──────────────────────────────────────────────────
    // tinct (and matugen before it) writes plain `$role: #rrggbb;` lines.
    function parseScss(text) {
        const out = {};
        const lines = text.split("\n");
        for (let i = 0; i < lines.length; i++) {
            const m = /^\$([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([^;]+);?\s*$/.exec(lines[i].trim());
            if (!m)
                continue;
            const key = m[1];
            const value = m[2].trim();
            if (key === "darkmode" || key === "transparent")
                out[key] = /^(true|1|yes)$/i.test(value);
            else if (value.charAt(0) === "#")
                out[key] = value.toLowerCase();
        }
        return out;
    }

    function reload() {
        if (!root.watching)
            return;
        const xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return;
            const text = xhr.responseText || "";
            if (!text.length || text === root._lastRaw)
                return;             // missing or unchanged — don't churn bindings
            root._lastRaw = text;

            const parsed = root.parseScss(text);
            if (!parsed.primary)
                return;

            // Some template sets omit the success roles; borrow the fallback's
            // so nothing ends up bound to undefined.
            const keys = ["success", "onSuccess", "successContainer", "onSuccessContainer"];
            for (let i = 0; i < keys.length; i++)
                if (!parsed[keys[i]])
                    parsed[keys[i]] = root.fallback[keys[i]];

            root.colors = parsed;
            root.source = "tinct";
            root.reloaded();
        };
        xhr.open("GET", "file://" + root.scssPath);
        xhr.send();
    }

    // XHR can't report an mtime, so poll and compare content. The file is
    // ~2 KB, which makes this far cheaper than it sounds, and it keeps the app
    // in step with a wallpaper switch within a couple of seconds.
    property Timer _poll: Timer {
        interval: 2000
        running: root.watching
        repeat: true
        onTriggered: root.reload()
    }

    Component.onCompleted: reload()
}
