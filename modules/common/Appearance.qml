pragma Singleton
import QtQuick

/*
 * Design tokens, laid out the same way the quickshell config's Appearance
 * singleton lays them out — so `Appearance.colors.colLayer1`,
 * `Appearance.rounding.normal`, `Appearance.font.pixelSize.small` and
 * `Appearance.animation.elementMove` all mean here what they mean there.
 *
 * The raw M3 roles come from Scheme (tinct's output). Everything below is
 * derived: the layered surfaces, the hover/active states, the type scale.
 */
QtObject {
    id: root

    readonly property var m3colors: Scheme.colors
    readonly property bool darkmode: m3colors.darkmode !== false

    // Content transparency stays opaque by default — a window is not a
    // desktop shell panel, and translucent post text is unreadable.
    property real backgroundTransparency: Prefs.transparency
    property real contentTransparency: 0.0

    readonly property QtObject colors: QtObject {
        readonly property color colSubtext: root.m3colors.outline

        // Layer 0 — the window itself
        readonly property color colLayer0Base: root.m3colors.background
        readonly property color colLayer0: ColorUtils.transparentize(colLayer0Base, root.backgroundTransparency)
        readonly property color colOnLayer0: root.m3colors.onBackground
        readonly property color colLayer0Hover: ColorUtils.mix(colLayer0Base, colOnLayer0, 0.92)
        readonly property color colLayer0Active: ColorUtils.mix(colLayer0Base, colOnLayer0, 0.85)
        readonly property color colLayer0Border: ColorUtils.mix(root.m3colors.outlineVariant, colLayer0Base, 0.4)

        // Layer 1 — panes and rails
        readonly property color colLayer1Base: root.m3colors.surfaceContainerLow
        readonly property color colLayer1: colLayer1Base
        readonly property color colOnLayer1: root.m3colors.onSurfaceVariant
        readonly property color colOnLayer1Inactive: ColorUtils.mix(colOnLayer1, colLayer1, 0.45)
        readonly property color colLayer1Hover: ColorUtils.mix(colLayer1Base, colOnLayer1, 0.92)
        readonly property color colLayer1Active: ColorUtils.mix(colLayer1Base, colOnLayer1, 0.85)

        // Layer 2 — cards
        readonly property color colLayer2Base: root.m3colors.surfaceContainer
        readonly property color colLayer2: colLayer2Base
        readonly property color colOnLayer2: root.m3colors.onSurface
        readonly property color colLayer2Hover: ColorUtils.mix(colLayer2Base, colOnLayer2, 0.93)
        readonly property color colLayer2Active: ColorUtils.mix(colLayer2Base, colOnLayer2, 0.85)
        readonly property color colLayer2Disabled: ColorUtils.mix(colLayer2Base, root.m3colors.background, 0.8)
        readonly property color colOnLayer2Disabled: ColorUtils.mix(colOnLayer2, root.m3colors.background, 0.4)

        // Layer 3 — controls sitting on cards
        readonly property color colLayer3Base: root.m3colors.surfaceContainerHigh
        readonly property color colLayer3: colLayer3Base
        readonly property color colOnLayer3: root.m3colors.onSurface
        readonly property color colLayer3Hover: ColorUtils.mix(colLayer3Base, colOnLayer3, 0.9)
        readonly property color colLayer3Active: ColorUtils.mix(colLayer3Base, colOnLayer3, 0.8)

        // Layer 4 — menus, dialogs
        readonly property color colLayer4Base: root.m3colors.surfaceContainerHighest
        readonly property color colLayer4: colLayer4Base
        readonly property color colOnLayer4: root.m3colors.onSurface
        readonly property color colLayer4Hover: ColorUtils.mix(colLayer4Base, colOnLayer4, 0.9)
        readonly property color colLayer4Active: ColorUtils.mix(colLayer4Base, colOnLayer4, 0.8)

        // Primary
        readonly property color colPrimary: root.m3colors.primary
        readonly property color colOnPrimary: root.m3colors.onPrimary
        readonly property color colPrimaryHover: ColorUtils.mix(colPrimary, colLayer1Hover, 0.87)
        readonly property color colPrimaryActive: ColorUtils.mix(colPrimary, colLayer1Active, 0.7)
        readonly property color colPrimaryContainer: root.m3colors.primaryContainer
        readonly property color colOnPrimaryContainer: root.m3colors.onPrimaryContainer
        readonly property color colPrimaryContainerHover: ColorUtils.mix(colPrimaryContainer, colOnPrimaryContainer, 0.9)
        readonly property color colPrimaryContainerActive: ColorUtils.mix(colPrimaryContainer, colOnPrimaryContainer, 0.8)

        // Secondary
        readonly property color colSecondary: root.m3colors.secondary
        readonly property color colOnSecondary: root.m3colors.onSecondary
        readonly property color colSecondaryHover: ColorUtils.mix(colSecondary, colLayer1Hover, 0.85)
        readonly property color colSecondaryActive: ColorUtils.mix(colSecondary, colLayer1Active, 0.4)
        readonly property color colSecondaryContainer: root.m3colors.secondaryContainer
        readonly property color colOnSecondaryContainer: root.m3colors.onSecondaryContainer
        readonly property color colSecondaryContainerHover: ColorUtils.mix(colSecondaryContainer, colOnSecondaryContainer, 0.9)
        readonly property color colSecondaryContainerActive: ColorUtils.mix(colSecondaryContainer, colOnSecondaryContainer, 0.54)

        // Tertiary
        readonly property color colTertiary: root.m3colors.tertiary
        readonly property color colOnTertiary: root.m3colors.onTertiary
        readonly property color colTertiaryContainer: root.m3colors.tertiaryContainer
        readonly property color colOnTertiaryContainer: root.m3colors.onTertiaryContainer
        readonly property color colTertiaryContainerHover: ColorUtils.mix(colTertiaryContainer, colOnTertiaryContainer, 0.9)
        readonly property color colTertiaryContainerActive: ColorUtils.mix(colTertiaryContainer, colOnTertiaryContainer, 0.7)

        // Surfaces
        readonly property color colSurfaceContainerLow: root.m3colors.surfaceContainerLow
        readonly property color colSurfaceContainer: root.m3colors.surfaceContainer
        readonly property color colSurfaceContainerHigh: root.m3colors.surfaceContainerHigh
        readonly property color colSurfaceContainerHighest: root.m3colors.surfaceContainerHighest
        readonly property color colOnSurface: root.m3colors.onSurface
        readonly property color colOnSurfaceVariant: root.m3colors.onSurfaceVariant

        // Status / misc
        readonly property color colError: root.m3colors.error
        readonly property color colOnError: root.m3colors.onError
        readonly property color colErrorContainer: root.m3colors.errorContainer
        readonly property color colOnErrorContainer: root.m3colors.onErrorContainer
        readonly property color colSuccess: root.m3colors.success
        readonly property color colOnSuccess: root.m3colors.onSuccess
        readonly property color colSuccessContainer: root.m3colors.successContainer
        readonly property color colOnSuccessContainer: root.m3colors.onSuccessContainer
        readonly property color colOutline: root.m3colors.outline
        readonly property color colOutlineVariant: root.m3colors.outlineVariant
        readonly property color colTooltip: root.m3colors.surfaceContainerHigh
        readonly property color colOnTooltip: root.m3colors.onSurface
        readonly property color colScrim: ColorUtils.transparentize(root.m3colors.scrim, 0.4)
        readonly property color colShadow: ColorUtils.transparentize(root.m3colors.shadow, 0.7)

        // Reddit's own semantics: upvote warm, downvote cool. Tinted toward the
        // active palette so they never clash with the wallpaper.
        readonly property color colUpvote: ColorUtils.mix("#ff7043", root.m3colors.primary, 0.72)
        readonly property color colDownvote: ColorUtils.mix("#7c9cff", root.m3colors.primary, 0.72)
    }

    readonly property QtObject rounding: QtObject {
        readonly property int unsharpen: 2
        readonly property int unsharpenmore: 6
        readonly property int verysmall: 8
        readonly property int small: 12
        readonly property int normal: 17
        readonly property int large: 23
        readonly property int verylarge: 30
        readonly property int full: 9999
        readonly property int windowRounding: 18
    }

    readonly property QtObject font: QtObject {
        readonly property QtObject family: QtObject {
            readonly property string main: "Google Sans Flex"
            readonly property string numbers: "Google Sans Flex"
            readonly property string title: "Google Sans Flex"
            readonly property string iconMaterial: "Material Symbols Rounded"
            readonly property string monospace: "JetBrains Mono NF"
            readonly property string reading: "Readex Pro"
            readonly property string expressive: "Space Grotesk"
        }
        readonly property QtObject variableAxes: QtObject {
            readonly property var main: ({
                    "wght": 450,
                    "wdth": 100
                })
            readonly property var numbers: ({
                    "wght": 450
                })
            readonly property var title: ({
                    "wght": 550
                })
        }
        readonly property QtObject pixelSize: QtObject {
            readonly property int smallest: 10
            readonly property int smaller: 12
            readonly property int smallie: 13
            readonly property int small: 15
            readonly property int normal: 16
            readonly property int large: 17
            readonly property int larger: 19
            readonly property int huge: 22
            readonly property int hugeass: 23
            readonly property int title: 22
        }
    }

    readonly property QtObject animationCurves: QtObject {
        readonly property list<real> expressiveFastSpatial: [0.42, 1.67, 0.21, 0.90, 1, 1]
        readonly property list<real> expressiveDefaultSpatial: [0.38, 1.21, 0.22, 1.00, 1, 1]
        readonly property list<real> expressiveSlowSpatial: [0.39, 1.29, 0.35, 0.98, 1, 1]
        readonly property list<real> expressiveEffects: [0.34, 0.80, 0.34, 1.00, 1, 1]
        readonly property list<real> emphasized: [0.05, 0, 2 / 15, 0.06, 1 / 6, 0.4, 5 / 24, 0.82, 0.25, 1, 1, 1]
        readonly property list<real> emphasizedAccel: [0.3, 0, 0.8, 0.15, 1, 1]
        readonly property list<real> emphasizedDecel: [0.05, 0.7, 0.1, 1, 1, 1]
        readonly property list<real> standard: [0.2, 0, 0, 1, 1, 1]
        readonly property list<real> standardAccel: [0.3, 0, 1, 1, 1, 1]
        readonly property list<real> standardDecel: [0, 0, 0, 1, 1, 1]
        readonly property real expressiveFastSpatialDuration: 350
        readonly property real expressiveDefaultSpatialDuration: 500
        readonly property real expressiveSlowSpatialDuration: 650
        readonly property real expressiveEffectsDuration: 200
    }

    // Global speed multiplier — 0 disables tweens, 0.5 is snappy.
    readonly property real animationSpeedFactor: Prefs.animationSpeed
    function animDur(ms) {
        return Math.round(ms * root.animationSpeedFactor);
    }

    readonly property QtObject animation: QtObject {
        readonly property QtObject elementMove: QtObject {
            readonly property int duration: root.animDur(root.animationCurves.expressiveDefaultSpatialDuration)
            readonly property int velocity: 650
            readonly property int type: Easing.BezierSpline
            readonly property list<real> bezierCurve: root.animationCurves.expressiveDefaultSpatial
            readonly property Component numberAnimation: Component {
                NumberAnimation {
                    duration: root.animation.elementMove.duration
                    easing.type: root.animation.elementMove.type
                    easing.bezierCurve: root.animation.elementMove.bezierCurve
                }
            }
            readonly property Component colorAnimation: Component {
                ColorAnimation {
                    duration: root.animation.elementMove.duration
                    easing.type: root.animation.elementMove.type
                    easing.bezierCurve: root.animation.elementMove.bezierCurve
                }
            }
        }

        /*
         * STATE CHANGE — hover, press, selected. Not motion.
         *
         * These were animated with `elementMoveFast`: 200ms on an expressive
         * MOTION curve, which is right for something travelling across the
         * screen and wrong for a colour that just has to arrive. Running a
         * pointer down a menu left a trail of rows still fading in behind it.
         * A state layer should land almost immediately — short, and on the
         * standard curve rather than an expressive one.
         */
        readonly property QtObject stateChange: QtObject {
            readonly property int duration: root.animDur(110)
            readonly property int type: Easing.BezierSpline
            readonly property list<real> bezierCurve: root.animationCurves.standard
            readonly property Component colorAnimation: Component {
                ColorAnimation {
                    duration: root.animation.stateChange.duration
                    easing.type: root.animation.stateChange.type
                    easing.bezierCurve: root.animation.stateChange.bezierCurve
                }
            }
            readonly property Component numberAnimation: Component {
                NumberAnimation {
                    duration: root.animation.stateChange.duration
                    easing.type: root.animation.stateChange.type
                    easing.bezierCurve: root.animation.stateChange.bezierCurve
                }
            }
        }

        readonly property QtObject elementMoveFast: QtObject {
            readonly property int duration: root.animDur(root.animationCurves.expressiveEffectsDuration)
            readonly property int velocity: 850
            readonly property int type: Easing.BezierSpline
            readonly property list<real> bezierCurve: root.animationCurves.expressiveEffects
            readonly property Component numberAnimation: Component {
                NumberAnimation {
                    duration: root.animation.elementMoveFast.duration
                    easing.type: root.animation.elementMoveFast.type
                    easing.bezierCurve: root.animation.elementMoveFast.bezierCurve
                }
            }
            readonly property Component colorAnimation: Component {
                ColorAnimation {
                    duration: root.animation.elementMoveFast.duration
                    easing.type: root.animation.elementMoveFast.type
                    easing.bezierCurve: root.animation.elementMoveFast.bezierCurve
                }
            }
        }

        readonly property QtObject elementMoveEnter: QtObject {
            readonly property int duration: root.animDur(400)
            readonly property int type: Easing.BezierSpline
            readonly property list<real> bezierCurve: root.animationCurves.emphasizedDecel
        }

        readonly property QtObject elementMoveExit: QtObject {
            readonly property int duration: root.animDur(200)
            readonly property int type: Easing.BezierSpline
            readonly property list<real> bezierCurve: root.animationCurves.emphasizedAccel
        }

        readonly property QtObject elementResize: QtObject {
            readonly property int duration: root.animDur(300)
            readonly property int type: Easing.BezierSpline
            readonly property list<real> bezierCurve: root.animationCurves.emphasized
        }

        readonly property QtObject clickBounce: QtObject {
            readonly property int duration: root.animDur(400)
            readonly property int type: Easing.BezierSpline
            readonly property list<real> bezierCurve: root.animationCurves.expressiveDefaultSpatial
        }

        readonly property QtObject scroll: QtObject {
            readonly property int duration: root.animDur(200)
            readonly property int type: Easing.BezierSpline
            readonly property list<real> bezierCurve: root.animationCurves.standardDecel
        }
    }

    /*
     * Scrolling feel, shared by every scrollable surface.
     *
     * The deceleration used to be 6000, which killed momentum almost the instant
     * you lifted your fingers and made a touchpad feel like it was dragging
     * through treacle. Lower deceleration plus a much higher velocity ceiling
     * gives a long, natural glide; on Wayland the touchpad's pixel-precise
     * deltas are applied 1:1 by Flickable, so the gesture itself tracks exactly.
     */
    readonly property QtObject scroll: QtObject {
        readonly property real deceleration: 1600
        readonly property real maxVelocity: 9000
        // Pixels per mouse-wheel notch, for SmoothWheel.
        readonly property real wheelStep: 115
    }

    readonly property QtObject sizes: QtObject {
        readonly property real titleBarHeight: 42
        readonly property real navRailWidth: 88
        readonly property real navRailWidthExpanded: 232
        readonly property real topBarHeight: 60
        readonly property real feedMaxWidth: 720
        readonly property real detailMinWidth: 460
        readonly property real twoPaneThreshold: 1100
        readonly property real elevationMargin: 10
        readonly property real mediaMaxHeight: 520
        readonly property real avatarSize: 32
    }
}
