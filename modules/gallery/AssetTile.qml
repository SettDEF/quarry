import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick
import QtQuick.Effects
import QtMultimedia

/*
 * One catalog item. Recycled: every property can change under it at any time,
 * so nothing here may cache state across an item swap.
 *
 * Two things this tile is careful about.
 *
 * **It never goes blank.** A pooled tile is re-pointed at a different item as
 * you scroll, and the obvious implementation — one Image whose `source` is
 * reassigned — clears to nothing the instant the source changes and stays empty
 * until the next decode finishes. That is the flicker: a wall of tiles blinking
 * white as it scrolls. So there are two layers. The incoming picture loads into
 * the hidden one, and they cross-fade only once it is actually ready; until
 * then you keep looking at a picture rather than at a hole.
 *
 * **It does not decode more than it must.** ThumbGate bounds how many loads are
 * in flight, and the source is a local ladder step sized to the tile, so Qt
 * never decodes 4000px to paint 330.
 */
Rectangle {
    id: root

    property var item: null
    property real priority: 0        // distance from viewport centre; lower loads first
    // Signed: the tile's top relative to the view's middle, and the view's height.
    property real viewOffset: 0
    property real viewHeight: 0
    /// How much of the tile is on screen, 0..1. Drives "play every video in view".
    readonly property real visibleRatio: {
        if (root.viewHeight <= 0 || root.height <= 0)
            return 0;
        const half = root.viewHeight / 2;
        const shown = Math.min(root.viewOffset + root.height, half) - Math.max(root.viewOffset, -half);
        return Math.max(0, shown) / root.height;
    }
    property bool showMeta: true

    /*
     * WHAT THIS LAYOUT WANTS SHOWN.
     *
     * Filled in by whoever owns the tiles — `Prefs.layoutSettings(<layout>)` —
     * so a wall and a list can disagree about badges, captions and which quick
     * actions are worth a button. Defaults to the layout in use, so a tile
     * dropped anywhere still gets a sensible answer rather than nothing.
     */
    property var options: Prefs.layoutSettings(Prefs.layoutMode)
    function shows(key) {
        return root.showMeta && root.options && root.options[key] !== false;
    }

    /// One of the quick actions was pressed: "export", "open", "keep",
    /// "board", "wallpaper", "copy", "similar", "hide". Which of them exist is
    /// the layout's business; what they DO belongs to the shell, which already
    /// does all of them for the context menu.
    signal quickAction(string id)

    signal activated
    signal contextRequested(real sceneX, real sceneY)
    signal quickExport

    /*
     * A ROW A USER SCRIPT HID.
     *
     * Not removed — see `_applyScripts` in Catalog for why a page must keep
     * its length — so the tile draws the stub instead of the picture, the way
     * a filtered post on 4chan X leaves something you can click through.
     */
    readonly property bool scriptHidden: root.item && root.item.scriptHidden === true

    /*
     * DIMMED RATHER THAN GONE.
     *
     * A filter has two honest answers for "this is not what you asked for":
     * take it away, or leave it there quieter. Hiding is right when you never
     * want to see it; dimming is right when the rule is a guess — a
     * recommender's idea of what you like — because a guess you can still see
     * past is one you can correct, and a wall full of stubs is not.
     *
     * Set by a rows hook as `row.dim` (0…1, how much to fade). Rows are passed
     * to hooks by reference, so a script marks one rather than returning a
     * second list.
     */
    readonly property real scriptDim: {
        if (!root.item || root.item.dim === undefined)
            return 0;

        const value = Number(root.item.dim);
        return value > 0 && value <= 1 ? value : 0;
    }

    readonly property bool isVector: root.item && root.item.family === "vector"
    readonly property bool isModel: root.item && root.item.family === "model"
    readonly property bool isVideo: root.item && root.item.family === "video"

    /// A duration as a person writes it, or empty when nobody has measured one
    /// — the daemon fills it in the first time a video is thumbnailed, and a
    /// row that has not been looked at yet must show nothing rather than 0:00.
    readonly property string length: {
        const seconds = root.item ? (root.item.duration || 0) : 0;
        if (!(seconds > 0))
            return "";
        const minutes = Math.floor(seconds / 60);
        const rest = Math.floor(seconds % 60);
        return `${minutes}:${rest < 10 ? "0" : ""}${rest}`;
    }

    /*
     * Nearest ladder step at or above the draw size, in **real** pixels.
     *
     * `width` is logical: on a 1.67× display a 330-wide tile is 550 actual
     * pixels, so asking for a 320 step meant every tile on this machine was
     * being upscaled by two thirds. That is most of what "bad quality" was.
     */
    readonly property int ladderStep: {
        const want = Math.ceil(root.width * (Screen.devicePixelRatio || 1));
        // See GalleryWall.ladder: 1280 was the ceiling, so a tile drawn larger
        // than that in real pixels had nothing better to ask for and was scaled
        // up from 1280. The daemon imposes no limit of its own.
        for (const step of [160, 320, 640, 1280, 1920, 2560])
            if (step >= want)
                return step;
        return 2560;
    }


    /*
     * ONE QUIET GROUND, NOT THE PICTURE'S OWN COLOUR.
     *
     * The ground used to be each row's dominant colour, on the theory that a
     * tile settling into its own picture reads better than one fading out of a
     * hole. In practice it does the opposite: every tile flashes a different
     * saturated block on the way in, so a wall filling up flickers through a
     * grid of colours that have nothing to do with each other, and the picture
     * arriving is the least noticeable thing about it. Worse in the viewer,
     * where one big rectangle changes colour and then changes again.
     *
     * A single neutral ground says "something is coming" without announcing
     * itself, and the only thing that changes on screen is the picture.
     */
    readonly property color ground: Appearance.colors.colLayer2

    color: root.ground
    radius: Prefs.tileRadius
    /*
     * Clipping is a visual effect, not an optimisation — Qt's own guidance is
     * "never enable clipping on delegates", because a clipped item cannot be
     * batched with its siblings. Whether that matters here is a measurement,
     * not a doctrine, so it is a setting and PERF.md carries the numbers.
     */
    clip: Prefs.tileClip
    antialiasing: Prefs.tileRadius > 0

    /*
     * Animated rows play on hover, and only on hover.
     *
     * A wall of GIFs all playing at once is a decode per tile per frame, which
     * is why the grid shows the still first frame the daemon baked. But an
     * animated avatar that never moves is a lie about what you are picking, so
     * hovering one loads the real file and plays it.
     */
    /*
     * VIDEO PLAYS IN THE WALL, NOT ONLY IN THE VIEWER.
     *
     * A video tile showed a poster frame and nothing else, so the only way to
     * see whether a clip was worth anything was to open it — which is the same
     * mistake as a still GIF tile, and that one was already fixed by playing it
     * on hover. This is that, for the family where it matters most.
     *
     * Shape borrowed from Rodded's WallTile, which had the harder version of
     * this problem first: the player is CREATED by a Loader rather than merely
     * paused, because a paused MediaPlayer still holds a decoder and a wall can
     * hold forty of them; nothing plays while the detail view is open, since a
     * clip left running behind a modal is a second decode you cannot see; and
     * and it is muted unless you have asked otherwise: sound belongs to the one
     * thing you have chosen to look at, not to whatever the pointer crossed.
     * `Prefs.hoverSound` is the way to ask, and even then only the tile the
     * pointer is actually on can be heard — the Loader is `active` on hover, so
     * there is never more than one player alive to make noise.
     */
    /*
     * A SLOT, when playing is not something you hover for.
     *
     * Hover needs no budget: the pointer is in one place. "Play what I can
     * see" would start a decoder per visible tile — forty of them on a wall —
     * so a tile asks PlayGate instead and the few nearest the middle of the
     * view win. See PlayGate for why three.
     */
    readonly property string playToken: root.item ? String(root.item.id) : ""
    /*
     * NOT GATED ON `visible`.
     *
     * Measured: every tile in the wall reported `visible false` at the moment
     * the election ran, so gating on it meant nothing ever claimed a slot.
     * The wall's delegates are recycled and their visibility flickers as the
     * window slides; `priority` — distance from the viewport centre — is the
     * value that actually says whether you are looking at this tile, and
     * PlayGate ranks on it. Admitting only the nearest three is the budget,
     * so an off-screen tile holding a claim costs nothing but a map entry.
     */
    readonly property bool autoplayWanted: Prefs.autoplayInView && root.isVideo
        && !root.blurred && !Shell.detailOpen
        // A layout kept loaded behind the current one must not play.
        && root.visible
        // "All in view" (slots 0): only once enough of it shows, like a browser's IntersectionObserver.
        && (Prefs.autoplaySlots !== 0 || root.visibleRatio * 100 >= Prefs.autoplayThreshold)
    readonly property bool autoplaySlot: root.autoplayWanted && PlayGate.holds(root.playToken)
    property real _seconds: 0
    // Playing, autoscroll running, and its centre near the view's: ask to be snapped to.
    readonly property bool nearMiddle: root.autoplaySlot && Scripts.scrollSpeed !== 0 && root.viewHeight > 0
        && Math.abs(root.viewOffset + root.height / 2) < Prefs.snapTolerance
    onNearMiddleChanged: {
        if (root.nearMiddle)
            Scripts.snapTo(root.playToken, root.viewOffset + root.height / 2, root._seconds);
    }

    /*
     * A RECYCLED TILE MUST GIVE UP ITS OLD CLAIM.
     *
     * The wall does not destroy delegates as they leave, it rebinds them to
     * another row — so `Component.onDestruction` almost never runs during a
     * scroll. Without this, every row a tile has ever shown keeps a claim and
     * the queue grows without bound: measured 17 → 27 → 48 waiting over two
     * scrolls, all of it tiles that no longer exist on screen.
     */
    property string _heldToken: ""
    onPlayTokenChanged: {
        if (root._heldToken && root._heldToken !== root.playToken)
            PlayGate.release(root._heldToken);

        root._heldToken = root.autoplayWanted ? root.playToken : "";
        if (root.autoplayWanted)
            PlayGate.claim(root.playToken, root.priority);

    }

    onAutoplayWantedChanged: {
        if (root.autoplayWanted) {
            root._heldToken = root.playToken;
            PlayGate.claim(root.playToken, root.priority);
        } else {
            root._heldToken = "";
            PlayGate.release(root.playToken);
        }
    }
    // Distance from the middle of the view changes as you scroll, and the
    // election is by distance — so the claim is re-made, not made once.
    onPriorityChanged: {
        if (root.autoplayWanted)
            PlayGate.claim(root.playToken, root.priority);

    }
    /*
     * CLAIMED ON CREATION TOO, not only on change.
     *
     * A delegate that is built already wanting to play never emits
     * `onAutoplayWantedChanged` — the property was true from the start, so
     * there is no change to report. Every tile on the first screenful is in
     * exactly that position, so nothing claimed a slot and nothing ever
     * played: measured `playing=0, waiting=0` over a wall of video.
     */
    Component.onCompleted: {
        Scripts.registerTile(root);
        if (root.autoplayWanted)
            PlayGate.claim(root.playToken, root.priority);

    }

    /*
     * ASKED FOR ONLY ONCE THIS TILE IS ACTUALLY GOING TO PLAY.
     *
     * Resolving a page costs two round trips, so it is done for the few tiles
     * that hold a slot rather than for everything on screen — and `wantsPlayback`
     * is true for the hovered tile as well, which is the other moment you have
     * said you want to watch this one.
     */
    onWantsPlaybackChanged: {
        if (root.wantsPlayback)
            Playback.resolve(root.item);

    }
    /*
     * Published so autoscroll can hold while you are looking at one — see
     * Shell.hoveredTiles. Balanced on destruction because a tile can be
     * recycled out from under the pointer, which emits no exit.
     */
    readonly property bool pointerOn: hover.hovered
    property bool _counted: false
    onPointerOnChanged: {
        if (root.pointerOn === root._counted)
            return ;

        root._counted = root.pointerOn;
        Shell.hoveredTiles = Math.max(0, Shell.hoveredTiles + (root.pointerOn ? 1 : -1));
    }

    Component.onDestruction: {
        Scripts.unregisterTile(root);
        if (root._counted)
            Shell.hoveredTiles = Math.max(0, Shell.hoveredTiles - 1);

        PlayGate.release(root._heldToken || root.playToken);
    }

    readonly property bool wantsPlayback: root.isVideo && !root.blurred
        && !Shell.detailOpen
        && ((hover.hovered && Prefs.animateOnHover) || root.autoplaySlot)

    Loader {
        anchors.fill: parent
        z: 1
        active: root.wantsPlayback
        asynchronous: true

        sourceComponent: Item {
            MediaPlayer {
                id: tilePlayer

                /*
                 * The length, told to the gate as soon as the file says it —
                 * which is how autoscroll can wait for a whole clip rather
                 * than for a number someone guessed. Metadata arrives after
                 * the source is set, so this is a signal, not a read.
                 */
                onDurationChanged: {
                    if (duration > 0) {
                        PlayGate.report(root.playToken, duration / 1000);
                        root._seconds = duration / 1000;
                        Scripts.noteDuration(root.playToken, root._seconds);
                    }

                }
                /*
                 * What there is to play, which for a tube row is nothing until
                 * someone goes and finds it — see Playback. A booru row has a
                 * file in `sample` or `url` and resolves to it immediately.
                 */
                source: Playback.urlFor(root.item)
                videoOutput: tileOutput
                loops: MediaPlayer.Infinite
                audioOutput: AudioOutput {
                    // One voice: the hovered tile, or with none hovered the one nearest the middle.
                    muted: !Prefs.hoverSound || (Shell.hoveredTiles > 0 ? !hover.hovered : PlayGate.soundToken !== root.playToken)
                    // The viewer's volume, so turning it down there turns it
                    // down everywhere rather than leaving one surface loud.
                    volume: Prefs.videoVolume
                }
                Component.onCompleted: play()
            }

            VideoOutput {
                id: tileOutput
                anchors.fill: parent
                fillMode: VideoOutput.PreserveAspectCrop
                // Until the first frame decodes the poster underneath shows
                // through, so there is no black flash on hover.
                opacity: tilePlayer.position > 0 ? 1 : 0
                Behavior on opacity {
                    NumberAnimation {
                        duration: 120
                    }
                }
            }
        }
    }

    Loader {
        anchors.fill: parent
        anchors.margins: root.isVector ? Math.round(root.width * 0.18) : 0
        z: 1
        // Video is excluded: `animated` is true for it, but AnimatedImage
        // cannot decode an mp4 — it would sit there loading a whole video file
        // to draw nothing.
        active: Prefs.animateOnHover && hover.hovered && !root.isVideo
            && root.item && root.item.animated && picture.ready
        asynchronous: true

        sourceComponent: AnimatedImage {
            source: root.item ? (root.item.thumb || root.item.url) : ""
            fillMode: Image.PreserveAspectCrop
            cache: false
            playing: true
            speed: 1.0
            // Until the first frame is decoded the still underneath shows
            // through, so there is no flash between them.
            opacity: status === AnimatedImage.Ready ? 1 : 0
            Behavior on opacity {
                NumberAnimation {
                    duration: 90
                }
            }
        }
    }

    /*
     * A PICTURE THAT WILL NEVER ARRIVE SHOULD NOT LOOK LIKE ONE THAT IS COMING.
     *
     * `ThumbImage` has known it failed since it was written, and every layout
     * ignored it: a hotlink-blocked CDN, a dead URL or a full disk drew the
     * same empty cell as a thumbnail still on its way, for ever. Only the
     * detail view ever said anything, and you had to open the picture to hear
     * it.
     */
    /*
     * A SOUND HAS NO PICTURE, AND THAT IS NOT A FAILURE.
     *
     * Audio rows mostly arrive with no cover at all — freesound publishes none —
     * so the tile that would draw a broken-picture mark says what the row IS
     * instead: a note, the title underneath, and the length in the corner like
     * a video's.
     */
    readonly property bool soundOnly: root.item && root.item.family === "audio" && (picture.failed || !root.item.thumb || String(root.item.thumb).length === 0)

    Column {
        anchors.centerIn: parent
        spacing: 6
        visible: root.soundOnly

        MaterialSymbol {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "graphic_eq"
            iconSize: Math.max(22, Math.min(46, Math.round(root.width * 0.24)))
            color: Appearance.colors.colSubtext
        }
        StyledText {
            width: Math.max(0, root.width - 24)
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            maximumLineCount: 2
            wrapMode: Text.WordWrap
            visible: root.width > 120
            text: root.item ? (root.item.title || root.item.slug || "") : ""
            font.pixelSize: Appearance.font.pixelSize.smallest
            color: Appearance.colors.colSubtext
        }
    }

    MaterialSymbol {
        anchors.centerIn: parent
        visible: picture.failed && !root.soundOnly
        text: "broken_image"
        iconSize: Math.max(18, Math.min(34, Math.round(root.width * 0.18)))
        color: Appearance.colors.colSubtext
        opacity: 0.7

        StyledToolTip {
            visible: brokenHover.hovered
            text: "That source would not serve this picture"
        }
        HoverHandler {
            id: brokenHover
        }
    }

    ThumbImage {
        id: picture
        anchors.fill: parent
        // A hidden row still occupies its cell; it just does not draw its
        // picture. Nothing is fetched for it either — the point of hiding
        // something is not to pay for it.
        visible: !root.scriptHidden
        // Faded, when a rule wants it quieter rather than gone. Hover brings it
        // back to full: whatever a filter thinks, the thing you are pointing at
        // is the thing you are looking at.
        opacity: root.scriptDim > 0 && !hover.hovered ? 1 - root.scriptDim : 1

        Behavior on opacity {
            NumberAnimation {
                duration: Appearance.animDur(140)
            }
        }
        item: root.scriptHidden ? null : root.item
        size: root.ladderStep
        priority: root.priority
        fillMode: (root.isVector || root.isModel) ? Image.PreserveAspectFit : Image.PreserveAspectCrop
        // Vectors are line art on transparency; inset them so they read as an
        // icon rather than a photo bleeding to the edge.
        contentMargins: root.isVector ? Math.round(root.width * 0.18) : 0

        /*
         * BLUR IS A SETTING THAT HAD NOTHING BEHIND IT.
         *
         * `Prefs.blurNsfw` has defaulted to true since the setting existed and
         * did precisely nothing — which was survivable while every source was
         * safe, and stopped being survivable the moment adult boards shipped.
         * A promise in a settings panel that the pictures do not keep is worse
         * than no setting at all.
         *
         * The effect is on the picture only, not the tile: the badges, the
         * title strip and the hover ring stay sharp, so the tile still reads as
         * a tile rather than a smudge.
         */
        layer.enabled: root.blurred
        layer.effect: MultiEffect {
            blurEnabled: true
            blur: 1.0
            // 48 is where a 330px tile stops being recognisable. Below about
            // 24 you can still read it, which defeats the point.
            blurMax: 48
            autoPaddingEnabled: false
        }
    }

    /*
     * THE STUB A HIDDEN ROW LEAVES.
     *
     * Deliberately visible rather than invisible: a filter you cannot see the
     * effect of is a filter you cannot debug, and the first question anybody
     * has about a hidden picture is "hidden by what". Clicking it opens the
     * row anyway, because a script's opinion should not be the last word.
     */
    Item {
        anchors.fill: parent
        visible: root.scriptHidden

        MaterialSymbol {
            anchors.centerIn: parent
            anchors.verticalCenterOffset: -8
            text: "filter_alt_off"
            iconSize: 20
            color: Appearance.colors.colSubtext
        }

        StyledText {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: 12
            width: parent.width - 16
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            visible: root.height > 70
            text: "hidden by a script"
            font.pixelSize: Appearance.font.pixelSize.smallest
            color: Appearance.colors.colSubtext
        }
    }

    /*
     * Blurred right now: an adult row, the setting on, and not being looked at.
     *
     * HOVERING UNCOVERS IT. The settings panel has always described this as
     * "blur them until hovered" and the first implementation made you tap every
     * tile, which put a "Tap to reveal" button on every picture and made a wall
     * of them read as broken low-resolution thumbnails rather than as covered
     * ones. Pointing at a picture is a small enough act to mean "show me".
     *
     * The tap still works, for touch and for keeping one uncovered while you
     * move the mouse away — and it is per tile and not persisted, because a
     * wall that stays uncovered after you scroll past is not what uncovering
     * one picture meant.
     */
    property bool revealed: false
    readonly property bool blurred: Prefs.blurNsfw && !root.revealed && !hover.hovered
        && !!root.item && root.item.nsfw === true

    // The tile is recycled, so a revealed one must not hand its state to
    // whatever picture lands in it next.
    onItemChanged: root.revealed = false

    /*
     * Covered, said quietly.
     *
     * A badge in the corner where the other badges live, not a button across
     * the middle of the picture: the blur itself is already the message, and a
     * label on every tile is a wall of labels.
     */
    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: 6
        width: 22
        height: 22
        radius: 11
        color: Appearance.colors.colLayer0Base
        opacity: 0.82
        visible: root.blurred && picture.ready

        MaterialSymbol {
            anchors.centerIn: parent
            text: "visibility_off"
            iconSize: 14
            color: Appearance.colors.colOnLayer0
        }

        TapHandler {
            // Ahead of the tile's own tap, so uncovering does not also open a
            // picture you have not looked at yet.
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: root.revealed = true
        }
    }

    // Only shown when there is genuinely nothing yet — not between two pictures.
    Rectangle {
        anchors.fill: parent
        visible: !picture.ready
        color: root.ground
        radius: root.radius

        MaterialSymbol {
            anchors.centerIn: parent
            text: root.isModel ? "view_in_ar" : root.isVector ? "shapes" : "image"
            iconSize: Math.min(28, root.width * 0.25)
            color: Appearance.colors.colOnLayer1Inactive
        }
    }

    /*
     * Quick actions, on hover.
     *
     * Exporting is the point of the app and it was two clicks and a menu away.
     * The top target is whatever you used last, so the common case — the same
     * target over and over — becomes one click on the picture itself.
     */
    Row {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.margins: 6
        spacing: 4
        visible: hover.hovered && root.item && quickRow.count > 0

        Repeater {
            id: quickRow
            /*
             * Each button is its own choice, not one "show the hover UI" flag.
             *
             * The pair that used to be hard-coded here — crop and open — are
             * simply the two that default to on. Everything the right-click
             * menu can do to a picture can be a button on it instead, for
             * whoever wants the click rather than the menu.
             */
            model: [
                { "icon": "crop", "action": "export", "tip": "Export…" },
                { "icon": "open_in_full", "action": "open", "tip": "Open" },
                { "icon": "bookmark_add", "action": "keep", "tip": "Keep" },
                { "icon": "dashboard_customize", "action": "board", "tip": "Put on a board" },
                { "icon": "wallpaper", "action": "wallpaper", "tip": "Set as wallpaper" },
                { "icon": "content_copy", "action": "copy", "tip": "Copy the picture" },
                { "icon": "image_search", "action": "similar", "tip": "Find similar" },
                { "icon": "visibility_off", "action": "hide", "tip": "Hide forever" }
            ].filter(a => root.shows(a.action))

            delegate: Rectangle {
                required property var modelData
                width: 26
                height: 26
                radius: 13
                color: quickHover.hovered ? Appearance.colors.colPrimary : Appearance.colors.colLayer0Base
                opacity: 0.92

                MaterialSymbol {
                    anchors.centerIn: parent
                    text: parent.modelData.icon
                    iconSize: 15
                    color: quickHover.hovered ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer0
                }

                HoverHandler {
                    id: quickHover
                    cursorShape: Qt.PointingHandCursor
                }

                StyledToolTip {
                    visible: quickHover.hovered
                    text: parent.modelData.tip
                }

                TapHandler {
                    // Grab on press. This button sits on top of the tile's own
                    // full-area TapHandler below — without a grab, a tap here
                    // also reached root's handler underneath, so exporting also
                    // opened the asset.
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: {
                        const what = parent.modelData.action;
                        if (what === "open")
                            root.activated();
                        else if (what === "export")
                            root.quickExport();
                        else
                            root.quickAction(what);
                    }
                }
            }
        }
    }

    // Family / state badges.
    Row {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: 6
        spacing: 4
        visible: root.shows("badges")
            && (root.isVector || root.isModel || root.isVideo || (root.item && root.item.animated))

        Repeater {
            model: {
                const out = [];
                if (root.isModel)
                    out.push("view_in_ar");
                if (root.isVector)
                    out.push("shapes");
                // One badge, not two: a video is `animated` as well, and
                // "play + gif" on the same tile says the same thing twice.
                if (root.isVideo)
                    out.push("play_circle");
                else if (root.item && root.item.animated)
                    out.push("gif_box");
                return out;
            }

            delegate: Rectangle {
                required property string modelData
                width: 22
                height: 22
                radius: 11
                /*
                 * A SMALL CIRCLE IS WHERE ANTIALIASING MATTERS MOST.
                 *
                 * This said `antialiasing: false` with a note that a 22px
                 * badge "does not need the extra geometry", which has it
                 * exactly backwards: the smaller the curve, the larger each
                 * stair-step is as a fraction of it. At 22px an aliased circle
                 * does not read as a circle at all — and Qt turns this on by
                 * itself for any rounded rectangle, so switching it off was
                 * spending nothing to make it worse.
                 */
                color: Appearance.colors.colLayer0Base
                opacity: 0.82

                MaterialSymbol {
                    anchors.centerIn: parent
                    text: parent.modelData
                    iconSize: 14
                    color: Appearance.colors.colOnLayer0
                }
            }
        }
    }

    /*
     * How long it is.
     *
     * Bottom-left, because that is where every video player and every video
     * site has put it for twenty years — a tile is not the place to be
     * original about this.
     */
    Rectangle {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: 6
        width: lengthLabel.implicitWidth + 10
        height: 18
        radius: 4
        color: Appearance.colors.colLayer0Base
        opacity: 0.82
        visible: root.shows("length") && (root.isVideo || root.soundOnly) && root.length.length > 0

        StyledText {
            id: lengthLabel
            anchors.centerIn: parent
            text: root.length
            font.pixelSize: Appearance.font.pixelSize.smallest
            color: Appearance.colors.colOnLayer0
        }
    }

    /*
     * Title and source, on hover only — a wall of permanent captions is noise.
     *
     * A gradient scrim rather than a solid strip: a band of flat colour across
     * the bottom of every hovered picture cut it in two, where a scrim darkens
     * only as much as the text needs and the picture still reads to the edge.
     * The text is white on the scrim whatever the theme, because the scrim is
     * always dark and the picture under it can be any colour at all.
     */
    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Math.min(parent.height, 76)
        // Faded in, and only in the scene while it is showing.
        opacity: root.shows("strip") && hover.hovered && !!root.item ? 1 : 0
        visible: opacity > 0
        Behavior on opacity {
            NumberAnimation {
                duration: Appearance.animDur(140)
                easing.type: Easing.OutCubic
            }
        }
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#00000000" }
            GradientStop { position: 1.0; color: "#c8000000" }
        }

        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: 10
            spacing: 1

            StyledText {
                width: parent.width
                elide: Text.ElideRight
                font.pixelSize: Appearance.font.pixelSize.smallie
                font.weight: Font.DemiBold
                color: "#ffffff"
                visible: root.shows("title")
                text: root.item ? (root.item.title && root.item.title.length > 0 ? root.item.title : root.item.slug) : ""
            }
            StyledText {
                width: parent.width
                elide: Text.ElideRight
                font.pixelSize: Appearance.font.pixelSize.smallest
                color: "#d0ffffff"
                visible: root.shows("meta")
                text: {
                    if (!root.item)
                        return "";
                    const bits = [root.item.source];
                    if (root.item.w > 0 && root.item.h > 0)
                        bits.push(`${root.item.w} × ${root.item.h}`);
                    return bits.join("  ·  ");
                }
            }
        }
    }

    /*
     * ROUNDED CORNERS THAT ARE ACTUALLY ROUND.
     *
     * `radius` + `clip` never rounded a picture: Qt clips to the bounding
     * RECTANGLE, so the tile's ground was rounded and the picture on top of it
     * was square — every tile in the wall had four sharp corners. A real
     * rounded clip is an offscreen texture per tile, which a wall of fifty
     * visible tiles cannot afford.
     *
     * So the corners are painted off instead: a frame in the gallery's own
     * colour, sitting in the gap between tiles, whose inner edge is a rounded
     * rectangle exactly on the tile's edge. One more rectangle per tile, no
     * texture. It must not be wider than half the gap or it paints over the
     * neighbour, and must reach past the corner's diagonal (radius × √2) or a
     * sliver of square corner survives — which the 10px gap allows.
     */
    property color maskColor: Appearance.colors.colLayer1
    readonly property real maskWidth: 5
    Rectangle {
        visible: root.radius > 0
        anchors.fill: parent
        anchors.margins: -root.maskWidth
        radius: root.radius + root.maskWidth
        color: "transparent"
        border.width: root.maskWidth
        border.color: root.maskColor
        antialiasing: true
    }

    // Only in the scene while hovered: an always-present transparent rectangle
    // is one more item to batch and blend for every tile on screen.
    Rectangle {
        anchors.fill: parent
        visible: hover.hovered && root.shows("ring")
        radius: root.radius
        color: "transparent"
        border.width: 2
        border.color: Appearance.colors.colPrimary
    }

    HoverHandler {
        id: hover
    }

    /*
     * A PLACEHOLDER IS NOT CLICKABLE.
     *
     * A tile whose page has not landed has no record, and clicking one raised
     * `activated` with nothing in it — which the viewer answered by opening
     * whatever it had shown last. Nothing to open means nothing happens.
     */
    TapHandler {
        acceptedButtons: Qt.LeftButton
        enabled: root.item !== null && root.item !== undefined
        onTapped: root.activated()
    }

    TapHandler {
        acceptedButtons: Qt.RightButton
        enabled: root.item !== null && root.item !== undefined
        onTapped: eventPoint => {
            const scene = root.mapToItem(null, eventPoint.position.x, eventPoint.position.y);
            root.contextRequested(scene.x, scene.y);
        }
    }
}
