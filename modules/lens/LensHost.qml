import qs.modules.common
import qs.modules.gallery
import qs.services
import QtQuick

/*
 * THE VISUAL HOME FOR LENSES.
 *
 * Placed over the content area, it does four things:
 *   - parents lens instances (they need a visual parent to create components)
 *   - draws the open lens's chosen SKIN, full-bleed over the gallery
 *   - renders each enabled lens's legacy `overlay` component
 *   - installs each enabled lens's shortcuts
 *
 * With nothing open it accepts no input and draws nothing, so an app with no
 * lenses behaves exactly as if this were not here.
 *
 * FAILURE IS CONTAINED HERE. A skin that will not load falls back to the lens's
 * default skin; if that fails too the lens is closed and said so out loud —
 * never a blank screen over the gallery with no way back.
 */
Item {
    id: root

    readonly property bool lensOpen: Lenses.activeId.length > 0
    readonly property var lens: Lenses.activeLens

    // Lens instances live here — off-screen, no size.
    Item {
        id: instanceHolder
        width: 0
        height: 0
        visible: false
    }

    Component.onCompleted: Lenses.containerReady(instanceHolder)

    // ── the lens surface ─────────────────────────────────────────────────────
    /*
     * Tell the open lens when quarryd comes back — see `reconnected` on Lens.
     * Only on the rising edge: a lens must not refetch everything each time
     * the property is merely re-evaluated.
     */
    Connections {
        target: Client

        /*
         * `backend`, NOT `connected` — and the difference is the whole bug.
         *
         * `connected` goes true the instant the socket opens, which is one
         * turn before the Socket object exists and several before the daemon
         * has answered `hello`. A call made then comes straight back with
         * "not connected", measured: `PHF reply · err not connected`. So the
         * lens was told to try again at the one moment it was guaranteed to
         * fail, and then never told anything else.
         *
         * `backend` is set from the hello reply, so it is the first moment the
         * daemon is genuinely usable.
         */
        function onBackendChanged() {
            if (Client.backend.length === 0 || !root.lensOpen)
                return ;

            const instance = Lenses.instanceOf(Lenses.activeId);
            if (instance && instance.reconnected)
                instance.reconnected();

        }
    }

    Rectangle {
        id: surface
        anchors.fill: parent
        z: 20
        visible: opacity > 0
        opacity: root.lensOpen ? 1 : 0
        /*
         * Opaque, whatever the skin says.
         *
         * A lens draws inside the gallery card now, and a skin ground with any
         * transparency let the pictures show straight through its own layout —
         * boards floating over a wall of thumbnails. A view covers what it
         * covers.
         */
        color: {
            const ground = skinLoader.item && skinLoader.item.ground !== undefined
                ? skinLoader.item.ground : Appearance.colors.colLayer1;
            return Qt.rgba(ground.r, ground.g, ground.b, 1);
        }

        Behavior on opacity {
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(surface)
        }

        // Nothing underneath reacts while a lens is up.
        MouseArea {
            anchors.fill: parent
            enabled: root.lensOpen
            acceptedButtons: Qt.AllButtons
            onWheel: wheel => wheel.accepted = true
        }

        focus: root.lensOpen
        Keys.onEscapePressed: event => {
            if (root.lens && root.lens.canGoBack)
                root.lens.goBack();
            else
                Lenses.close();
            event.accepted = true;
        }

        // What the skin says about chrome, where the shell can read it.
        Binding {
            target: Lenses
            property: "skinDrawsChrome"
            value: root.lensOpen && skinLoader.item ? skinLoader.item.wantsChrome === false : false
        }

        Loader {
            id: skinLoader
            anchors.fill: parent
            /*
             * THE DOCK DOES NOT SIT ON THE LAST ROW.
             *
             * The strip floats over the skin, so the bottom message in a
             * conversation and the bottom row of a chat list were underneath it
             * — you had to scroll past the end to read them. The skin is inset
             * instead of each list being taught the number, and `surface`
             * behind it carries the same ground colour, so the strip below is
             * not a hole.
             */
            // The dock floats over the skin — see `_pad` below. A strip of
            // empty ground under every lens was the alternative, and it read as
            // a broken bottom bar.
            anchors.bottomMargin: 0
            // A skin is a whole screen; building it asynchronously shows the
            // gallery through a half-open surface for a frame.
            asynchronous: false
            onStatusChanged: if (status === Loader.Error)
                root._skinFailed()
        }

        /*
         * WHERE A SCRIPT OR EXTENSION PUTS ITS CONTROLS INSIDE A LENS.
         *
         * A lens covers the gallery completely, so the strip that floats over
         * the wall is both hidden by it and about the wrong thing. But a lens
         * is exactly where a control is wanted — autoscroll reading a thread,
         * an extension's switch for the board you are on — so the same docks
         * are drawn here, in the lens's own surface, the way the video
         * controls draw them in theirs.
         *
         * One list, three homes: over the wall, in the player, and here.
         * `Host.registerDock` therefore reaches all three and this file never
         * learns what any particular extension does.
         *
         * `openDocks()` has already filtered by `@match` against where you
         * are, so a dock written for one lens does not appear in another.
         */
        Row {
            id: lensDocks

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 14
            spacing: 8
            z: 60
            // Nothing claimed to scroll (a viewer is open over the list): no
            // dock, rather than controls for a list you cannot see.
            visible: root.lensOpen && children.length > 0 && Host.activeFlickable !== null

            Repeater {
                model: Scripts.revision >= 0 && Prefs.scriptsEnabled ? Scripts.openDocks() : []

                delegate: ScriptDock {
                    required property var modelData

                    dock: modelData
                }
            }
        }

        // Said plainly rather than left blank: a lens with no skin at all is a
        // packaging mistake, not something to stare at. Plain Text, not
        // StyledText — qs.modules.widgets imports this module back.
        Text {
            anchors.centerIn: parent
            visible: root.lensOpen && skinLoader.status !== Loader.Ready
            text: skinLoader.status === Loader.Error ? "This lens could not draw." : "Loading…"
            font.family: Appearance.font.family.main
            font.pixelSize: Appearance.font.pixelSize.normal
            renderType: Text.NativeRendering
            color: Appearance.colors.colSubtext
        }
    }

    // Height, not `visible`: the Repeater is a child of the row, so the row
    // reads as visible with no dock in it and padded every list by 20px.
    readonly property real _inset: lensDocks.visible && lensDocks.height > 0 ? lensDocks.height + 20 : 0

    Binding {
        target: Host
        property: "bottomInset"
        value: root._inset
        when: root.lensOpen && root._inset > 0
    }

    /*
     * THE LIST UNDER THE DOCK GETS ROOM FOR IT.
     *
     * The dock is driven by `Host.activeFlickable` — the one list the skin
     * named — so that list, and only that one, is given the dock's height at
     * its end, and its own margin back when the dock goes or the list changes.
     * No skin had to learn the number; one that pads itself (`padsItself`)
     * is left alone.
     */
    property var _padded: null
    property real _padBase: 0

    function _pad() {
        if (root._padded) {
            try {
                root._padded.bottomMargin = root._padBase;
            } catch (e) {}
            root._padded = null;
        }
        const view = Host.activeFlickable;
        const skin = skinLoader.item;
        if (!root.lensOpen || root._inset <= 0 || !view || view.bottomMargin === undefined)
            return;
        if (skin && skin.padsItself === true)
            return;
        root._padBase = view.bottomMargin;
        root._padded = view;
        view.bottomMargin = root._padBase + root._inset;
    }

    on_InsetChanged: Qt.callLater(root._pad)
    onLensOpenChanged: Qt.callLater(root._pad)

    Connections {
        target: Host

        function onViewChanged() {
            Qt.callLater(root._pad);
        }
    }

    // Which skin url the loader is showing, so a fallback is attempted once.
    property string _loaded: ""
    property bool _fellBack: false

    function _reloadSkin() {
        const url = root.lensOpen ? Lenses.activeSkinUrl : "";
        if (url === root._loaded)
            return;
        root._loaded = url;
        if (url.length === 0) {
            skinLoader.setSource("");
            return;
        }
        skinLoader.setSource(url, {
            "lens": Lenses.activeLens
        });
    }

    function _skinFailed() {
        const id = Lenses.activeId;
        const entry = Lenses.find(id);
        const message = skinLoader.sourceComponent ? String(skinLoader.sourceComponent.errorString()).split("\n")[0] : "skin failed to load";
        console.warn("[lens]", id, "skin failed:", message);
        if (!root._fellBack && entry && entry.defaultSkin.length > 0 && Lenses.skinOf(id) !== entry.defaultSkin) {
            root._fellBack = true;
            Toast.error(`That skin would not load — back to ${entry.defaultSkin}.`);
            Lenses.setSkin(id, entry.defaultSkin);
            root._loaded = "";
            root._reloadSkin();
            return;
        }
        Toast.error(`${entry ? entry.name : id} could not draw — ${message}`);
        Lenses.close();
    }

    Connections {
        target: Lenses
        function onActiveIdChanged() {
            root._fellBack = false;
            root._reloadSkin();
        }
        function onCatalogUpdated() {
            root._reloadSkin();
        }
        // A lens that fails to load must not take the app with it.
        function onLensError(id, message) {
            Toast.error(`Lens “${id}” failed: ${message.split("\n")[0]}`);
        }
    }

    // ── legacy overlays ──────────────────────────────────────────────────────
    Repeater {
        model: Lenses.live

        delegate: Loader {
            required property var modelData
            anchors.fill: parent
            // A lens without an overlay contributes nothing.
            active: modelData.instance !== null && modelData.instance.overlay !== null
            sourceComponent: active ? modelData.instance.overlay : null
            z: 10

            // So an overlay can reach its own lens without going global.
            property var lens: modelData.instance
            property var extension: modelData.instance
        }
    }

    // ── shortcuts ────────────────────────────────────────────────────────────
    /*
     * Flattened to [{ sequence, action }] so one Repeater installs them all.
     * `sequences` (plural) is accepted too, and expanded here.
     */
    readonly property var allShortcuts: {
        const out = [];
        const list = Lenses.live;
        for (let i = 0; i < list.length; i++) {
            const shortcuts = list[i].instance.shortcuts || [];
            for (let j = 0; j < shortcuts.length; j++) {
                const entry = shortcuts[j];
                const keys = entry.sequences ? entry.sequences : (entry.sequence ? [entry.sequence] : []);
                for (let k = 0; k < keys.length; k++)
                    out.push({
                        "sequence": keys[k],
                        "action": entry.action
                    });
            }
        }
        return out;
    }

    Repeater {
        model: root.allShortcuts

        delegate: Item {
            required property var modelData

            Shortcut {
                sequence: modelData.sequence
                onActivated: if (modelData.action)
                    modelData.action()
            }
        }
    }
}
