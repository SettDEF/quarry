import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

/*
 * Choose the target, then choose what part of the picture goes into it.
 *
 * Everything before this exported with an automatic crop — centre, or the
 * busiest region — which is right often enough to be the default and wrong
 * often enough to be infuriating: a face two thirds up the frame is exactly
 * what "smart" gets wrong, and there was no way to say so.
 *
 * The box you drag is in source pixels, and it is sent to the daemon as part of
 * the recipe, so the preview and the export are the same pipeline applied to
 * the same rectangle. That is deliberate — a crop tool whose preview is drawn
 * by the UI is a crop tool that eventually lies.
 */
Sheet {
    id: root

    property var item: null
    property string targetId: "steam-avatar"

    /*
     * The recipe being edited, which starts as the chosen target's and diverges
     * the moment a knob moves.
     *
     * Targets were fixed presets: you could pick one, and that was the whole of
     * "customisable". The knobs edit a copy, and saving turns that copy into a
     * target of your own — which is the difference between a preset list and
     * something you can actually fit to a slot nobody anticipated.
     */
    property var edited: null
    readonly property var base: Targets.byId(root.targetId)
    readonly property var target: root.edited ? {
        "id": root.targetId,
        "label": root.base ? root.base.label : root.targetId,
        "icon": root.base ? root.base.icon : "crop",
        "group": root.base ? root.base.group : "Custom",
        "recipe": root.edited
    } : root.base

    readonly property bool modified: {
        if (!root.edited || !root.base)
            return false;
        const a = root.edited;
        const b = root.base.recipe;
        return a.width !== b.width || a.height !== b.height || a.fit !== b.fit || a.format !== b.format || a.quality !== b.quality || a.radius !== b.radius;
    }

    function editRecipe(key, value) {
        const next = Object.assign({}, root.edited || (root.base ? root.base.recipe : {}));
        next[key] = value;
        root.edited = next;
        previewDebounce.restart();
    }

    signal exported(string path)

    surfaceWidth: Math.min(920, root.width - 80)
    surfaceHeight: Math.min(620, root.height - 80)

    function openFor(picked, target) {
        root.item = picked;
        if (target)
            root.targetId = target;
        root.frameCrop();
        root.open = true;
        root.refreshPreview();
    }

    // ── the crop, in source pixels ───────────────────────────────────────────

    property real cropX: 0
    property real cropY: 0
    property real cropW: 0
    property real cropH: 0

    readonly property real sourceW: root.item && root.item.w > 0 ? root.item.w : 1000
    readonly property real sourceH: root.item && root.item.h > 0 ? root.item.h : 1000
    readonly property real targetAspect: {
        const recipe = root.target ? root.target.recipe : null;
        if (!recipe || recipe.height <= 0)
            return 1;
        return recipe.width / recipe.height;
    }

    /*
     * Start where the automatic crop would have: the largest rectangle of the
     * source with the target's aspect, centred. Dragging from there is an
     * adjustment rather than a fresh decision.
     */
    function frameCrop() {
        const aspect = root.targetAspect;
        let w = root.sourceW;
        let h = w / aspect;
        if (h > root.sourceH) {
            h = root.sourceH;
            w = h * aspect;
        }
        root.cropW = w;
        root.cropH = h;
        root.cropX = (root.sourceW - w) / 2;
        root.cropY = (root.sourceH - h) / 2;
    }

    function zoomCrop(factor) {
        const aspect = root.targetAspect;
        let w = Math.max(32, Math.min(root.sourceW, root.cropW * factor));
        let h = w / aspect;
        if (h > root.sourceH) {
            h = root.sourceH;
            w = h * aspect;
        }
        // Zoom about the centre, then clamp — so a crop can never leave the
        // picture, however far you scroll.
        root.cropX = root.clampX(root.cropX + (root.cropW - w) / 2, w);
        root.cropY = root.clampY(root.cropY + (root.cropH - h) / 2, h);
        root.cropW = w;
        root.cropH = h;
        previewDebounce.restart();
    }

    function clampX(x, w) {
        return Math.max(0, Math.min(x, root.sourceW - w));
    }

    function clampY(y, h) {
        return Math.max(0, Math.min(y, root.sourceH - h));
    }

    onTargetIdChanged: {
        // Picking a different target starts from its recipe, not from the last
        // one's edits.
        root.edited = null;
        root.frameCrop();
        previewDebounce.restart();
    }

    // ── the preview, from the daemon ─────────────────────────────────────────

    property string previewPath: ""
    property bool rendering: false

    function refreshPreview() {
        if (!root.item || !Client.connected || !root.target)
            return;
        root.rendering = true;

        const recipe = Object.assign({}, root.target.recipe, {
            "crop": {
                "x": Math.round(root.cropX),
                "y": Math.round(root.cropY),
                "w": Math.round(root.cropW),
                "h": Math.round(root.cropH)
            }
        });

        Client.call("preview", {
            "id": root.item.id,
            "recipe": recipe,
            "max": 320
        }, function (err, payload) {
            root.rendering = false;
            if (err || !payload) {
                /*
                 * The stale one had to go.
                 *
                 * This returned in silence, leaving the PREVIOUS render on
                 * screen next to a crop box that had since been dragged — so
                 * the sheet showed a picture that was no longer what would be
                 * exported, and said nothing about it.
                 */
                root.previewPath = "";
                Toast.error("Could not draw the preview — " + (err || "no answer"));
                return;
            }
            // Cache-busting: the daemon overwrites one path per item, and Qt
            // would happily show the previous render for ever.
            root.previewPath = "file://" + payload.path + "?v=" + Date.now();
        });
    }

    property Timer _previewDebounce: Timer {
        id: previewDebounce
        interval: 220
        onTriggered: root.refreshPreview()
    }

    RowLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 16

        // ── the picture, with the box on it ──────────────────────────────────
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ThumbImage {
                id: full
                anchors.fill: parent
                item: root.item
                size: 1280
                gated: false
                fillMode: Image.PreserveAspectFit
            }

            /*
             * Where the picture actually lands inside this pane.
             *
             * `PreserveAspectFit` letterboxes, so the crop overlay has to be
             * placed against the drawn rectangle rather than the pane — getting
             * this wrong is what makes a crop tool select something other than
             * what it highlighted.
             */
            readonly property real drawScale: Math.min(width / root.sourceW, height / root.sourceH)
            readonly property real drawW: root.sourceW * drawScale
            readonly property real drawH: root.sourceH * drawScale
            readonly property real drawX: (width - drawW) / 2
            readonly property real drawY: (height - drawH) / 2

            // Everything outside the box, dimmed — the standard way of saying
            // "this part is being thrown away".
            Repeater {
                model: 4

                delegate: Rectangle {
                    required property int index
                    color: Appearance.colors.colLayer0Base
                    opacity: 0.6
                    x: index === 0 ? parent.drawX : (index === 1 ? box.x + box.width : (index >= 2 ? box.x : 0))
                    y: index <= 1 ? parent.drawY : (index === 2 ? parent.drawY : box.y + box.height)
                    width: index === 0 ? box.x - parent.drawX : (index === 1 ? parent.drawX + parent.drawW - box.x - box.width : box.width)
                    height: index <= 1 ? parent.drawH : (index === 2 ? box.y - parent.drawY : parent.drawY + parent.drawH - box.y - box.height)
                }
            }

            Rectangle {
                id: box
                color: "transparent"
                border.width: 2
                border.color: Appearance.colors.colPrimary
                radius: 2

                x: parent.drawX + root.cropX * parent.drawScale
                y: parent.drawY + root.cropY * parent.drawScale
                width: root.cropW * parent.drawScale
                height: root.cropH * parent.drawScale

                // Thirds, because that is what people compose against.
                Repeater {
                    model: 4

                    delegate: Rectangle {
                        required property int index
                        color: Appearance.colors.colPrimary
                        opacity: 0.25
                        width: index < 2 ? 1 : parent.width
                        height: index < 2 ? parent.height : 1
                        x: index < 2 ? parent.width * (index + 1) / 3 : 0
                        y: index < 2 ? 0 : parent.height * (index - 1) / 3
                    }
                }

                DragHandler {
                    target: null
                    onCentroidChanged: {
                        if (!active)
                            return;
                        const dx = (centroid.position.x - centroid.pressPosition.x) / full.drawScale;
                        const dy = (centroid.position.y - centroid.pressPosition.y) / full.drawScale;
                        root.cropX = root.clampX(root.cropX + dx, root.cropW);
                        root.cropY = root.clampY(root.cropY + dy, root.cropH);
                        previewDebounce.restart();
                    }
                }

                HoverHandler {
                    cursorShape: Qt.SizeAllCursor
                }
            }

            WheelHandler {
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: event => {
                    event.accepted = true;
                    root.zoomCrop(event.angleDelta.y > 0 ? 0.9 : 1.1);
                }
            }
        }

        // ── what it will become ─────────────────────────────────────────────
        ColumnLayout {
            Layout.preferredWidth: 260
            Layout.fillHeight: true
            spacing: 10

            RowLayout {
                Layout.fillWidth: true

                StyledText {
                    Layout.fillWidth: true
                    text: "Export"
                    font.pixelSize: Appearance.font.pixelSize.larger
                    font.weight: Font.DemiBold
                    color: Appearance.colors.colOnLayer1
                }

                IconButton {
                    icon: "close"
                    size: 30
                    onClicked: root.close()
                }
            }

            // The result, at the size it will be — or scaled down with the
            // factor stated, so the preview never flatters it silently.
            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                width: Math.min(220, root.target ? root.target.recipe.width : 184)
                height: root.target && root.target.recipe.width > 0 ? width * (root.target.recipe.height / root.target.recipe.width) : width
                radius: Appearance.rounding.small
                color: Appearance.colors.colLayer2
                clip: true

                Image {
                    anchors.fill: parent
                    asynchronous: true
                    cache: false
                    fillMode: Image.PreserveAspectFit
                    source: root.previewPath
                }

                LoadingIndicator {
                    anchors.centerIn: parent
                    visible: root.rendering
                }
            }

            StyledText {
                Layout.alignment: Qt.AlignHCenter
                text: root.target ? `${root.target.recipe.width}×${root.target.recipe.height}` : ""
                font.family: Appearance.font.family.monospace
                font.pixelSize: Appearance.font.pixelSize.smallest
                color: Appearance.colors.colSubtext
            }

            Divider {
                Layout.fillWidth: true
            }

            StyledListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 2
                model: Targets.all

                delegate: Rectangle {
                    required property var modelData
                    width: ListView.view.width
                    height: 34
                    radius: Appearance.rounding.verysmall
                    color: modelData.id === root.targetId ? Appearance.colors.colSecondaryContainer : (targetHover.hovered ? Appearance.colors.colLayer2Hover : "transparent")

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        text: modelData.label
                        elide: Text.ElideRight
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: modelData.id === root.targetId ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer1
                    }

                    HoverHandler {
                        id: targetHover
                        cursorShape: Qt.PointingHandCursor
                    }

                    TapHandler {
                        onTapped: root.targetId = modelData.id
                    }
                }
            }

            // The knobs. Deliberately few and all visible: size, shape, format
            // — the three things that change what the file *is*.
            GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: 6
                rowSpacing: 4
                visible: root.target !== null

                StyledText {
                    text: "fit"
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: Appearance.colors.colSubtext
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4

                    Repeater {
                        model: ["cover", "contain"]

                        delegate: PillTab {
                            required property string modelData
                            label: modelData
                            labelSize: Appearance.font.pixelSize.smallest
                            horizontalPadding: 10
                            verticalPadding: 4
                            active: root.target && root.target.recipe.fit === modelData
                            onTriggered: root.editRecipe("fit", modelData)
                        }
                    }
                }

                StyledText {
                    text: "format"
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: Appearance.colors.colSubtext
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4

                    Repeater {
                        model: ["png", "jpeg"]

                        delegate: PillTab {
                            required property string modelData
                            label: modelData
                            labelSize: Appearance.font.pixelSize.smallest
                            horizontalPadding: 10
                            verticalPadding: 4
                            active: root.target && root.target.recipe.format === modelData
                            onTriggered: root.editRecipe("format", modelData)
                        }
                    }
                }

                StyledText {
                    text: "round"
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: Appearance.colors.colSubtext
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4

                    Repeater {
                        // A circle is `width / 2`, which is the one people
                        // actually want and the one hardest to type.
                        model: [
                            {
                                "label": "square",
                                "value": 0
                            },
                            {
                                "label": "soft",
                                "value": 24
                            },
                            {
                                "label": "circle",
                                "value": -1
                            }
                        ]

                        delegate: PillTab {
                            required property var modelData
                            label: modelData.label
                            labelSize: Appearance.font.pixelSize.smallest
                            horizontalPadding: 10
                            verticalPadding: 4
                            active: {
                                if (!root.target)
                                    return false;
                                const radius = root.target.recipe.radius;
                                const circle = Math.floor(root.target.recipe.width / 2);
                                return modelData.value === -1 ? radius >= circle : radius === modelData.value;
                            }
                            onTriggered: root.editRecipe("radius", modelData.value === -1 ? Math.floor(root.target.recipe.width / 2) : modelData.value)
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                TextButton {
                    text: root.modified ? "Save as target" : "Reset crop"
                    icon: root.modified ? "bookmark_add" : "restart_alt"
                    visible: root.modified
                    onClicked: {
                        // Saved under its own id so the shipped target it grew
                        // from stays as it was.
                        const id = `${root.targetId}-custom`;
                        Client.call("saveTarget", {
                            "target": {
                                "id": id,
                                "label": `${root.base ? root.base.label : root.targetId} (mine)`,
                                "group": "Mine",
                                "icon": root.base ? root.base.icon : "crop",
                                "recipe": root.edited
                            }
                        }, function (err, payload) {
                            if (err) {
                                Toast.error("Could not save: " + err);
                                return;
                            }
                            Toast.show(`Saved · ${payload.targets} of your own targets`);
                            root.edited = null;
                            root.targetId = id;
                        });
                    }
                }

                TextButton {
                    text: "Reset crop"
                    icon: "restart_alt"
                    onClicked: {
                        root.frameCrop();
                        previewDebounce.restart();
                    }
                }

                Item {
                    Layout.fillWidth: true
                }

                /*
                 * Send what you just cropped, not the picture it came from.
                 *
                 * The file is written first and the chat picker is handed its
                 * path — re-exporting from the item on the other side would
                 * throw away the crop, the size and the format chosen here and
                 * send something else while looking like it had obeyed.
                 *
                 * Hidden on a machine that has never had Morse running.
                 */
                TextButton {
                    text: "Send…"
                    icon: "send"
                    visible: Dispatch.everSeen
                    enabled: Dispatch.available
                    onClicked: {
                        const recipe = Object.assign({}, root.target.recipe, {
                            "crop": {
                                "x": Math.round(root.cropX),
                                "y": Math.round(root.cropY),
                                "w": Math.round(root.cropW),
                                "h": Math.round(root.cropH)
                            }
                        });
                        Toast.show("Preparing the file…");
                        Client.call("export", {
                            "id": root.item.id,
                            "recipe": recipe,
                            "target": "telegram-send",
                            "group": "telegram",
                            "path": "~/.cache/quarry/outbox/{slug}-{w}x{h}.{ext}"
                        }, function (err, payload) {
                            if (err || !payload) {
                                Toast.error("Could not prepare it: " + (err || "no answer"));
                                return;
                            }
                            root.close();
                            Dispatch.openPicker(root.item, payload.path);
                        }, 120000);
                    }
                }

                TextButton {
                    text: "Export"
                    icon: "check"
                    variant: "filled"
                    onClicked: {
                        const recipe = Object.assign({}, root.target.recipe, {
                            "crop": {
                                "x": Math.round(root.cropX),
                                "y": Math.round(root.cropY),
                                "w": Math.round(root.cropW),
                                "h": Math.round(root.cropH)
                            }
                        });
                        Targets.remember(root.targetId);
                        Client.call("export", {
                            "id": root.item.id,
                            "recipe": recipe,
                            "path": "~/Pictures/quarry/{kind}/{slug}-{w}x{h}.{ext}"
                        }, function (err, payload) {
                            if (err) {
                                Toast.error("Export failed: " + err);
                                return;
                            }
                            root.exported(payload.path);
                            Toast.show(`${payload.path.split("/").pop()} · ${payload.human}`);
                        });
                        root.close();
                    }
                }
            }
        }
    }
}
