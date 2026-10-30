import QtQuick

/*
 * QUARRY'S PALETTE, IN THE SHAPE TELA'S CHROME EXPECTS.
 *
 * The browser window borrows tela's tab strip and find bar wholesale — see
 * `tela-chrome`, a symlink into the tela checkout rather than a copy, so a
 * change there IS a change here. Those components are written against a
 * `theme` object: twenty-six names, all colours, sizes and durations, none of
 * them tela types. That is the entire contract between the two projects, and
 * this file is quarry's half of it.
 *
 * WHY THE TOKENS ARE A JS OBJECT AND NOT QML PROPERTIES
 *
 * One of the names is `onAccentContainer`, and QML's parser reads any
 * declaration beginning with `on` as a SIGNAL HANDLER — `readonly property
 * color onAccentContainer: "#d7e3ff"` fails with "cannot assign a value to a
 * signal", and a file that will not compile makes its type unavailable, which
 * surfaces three files away as "Type Theme unavailable". Tela does not hit
 * this because its theme comes from a Rust QObject, where the name is just a
 * property.
 *
 * A plain JS object has no such rule, and `theme.onAccentContainer` reads the
 * same either way — which is what the chrome actually does.
 *
 * Written down here rather than taken from quarry's Appearance singleton
 * because this window is NOT quickshell: it is a plain Qt program (main.cpp
 * says why it has to be), so quarry's QML modules are not available to it.
 */
QtObject {
    readonly property var tokens: ({
            // surfaces
            "sidebar": "#191b20",
            "sidebarHover": "#20232a",
            "surfaceHigh": "#22252b",
            "surfaceHover": "#272a32",
            "surfaceActive": "#2e323b",
            "border": "#2a2d34",
            "borderWidth": 1,
            // ink
            "text": "#e6e8ec",
            "textDim": "#9aa0a6",
            "textFaint": "#6b7178",
            "accent": "#a8c7fa",
            "accentContainer": "#1f3050",
            "onAccentContainer": "#d7e3ff",
            "error": "#ff8a80",
            // metrics
            "rounding": 14,
            "roundingSmall": 8,
            "rowHeight": 34,
            "iconSize": 18,
            "iconSizeSmall": 14,
            // type
            "fontMain": "Readex Pro",
            "fontMono": "JetBrains Mono",
            "fontIcon": "Material Symbols Rounded",
            "fontSmall": 12,
            "fontSmallest": 10,
            // motion
            "durFast": 120,
            "curveEffects": ({
                    "standard": Easing.OutCubic
                })
        })
}
