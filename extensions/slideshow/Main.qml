import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick

/*
 * Step through the current result on a timer.
 *
 * The first real extension, and it exists to prove the seam carries weight: it
 * contributes an action, an overlay and a target-driven side effect without a
 * single line of the app knowing it is there.
 *
 * The genuinely useful part is *rotate*: a wallpaper you chose from a grid in
 * ten seconds often turns out wrong an hour later, and the only honest test is
 * living with it. This sets each picture in the result as the wallpaper on an
 * interval, so a shortlist becomes a day.
 */
Extension {
    id: root

    property bool running: false
    property bool rotateWallpaper: false
    property int intervalSeconds: 20
    property int index: 0

    shortcuts: [
        {
            "sequence": "S",
            "action": () => root.toggle()
        }
    ]

    function toggle() {
        root.running = !root.running;
        Toast.show(root.running ? `Slideshow · every ${root.intervalSeconds}s` : "Slideshow stopped");
    }

    function step() {
        if (Catalog.count === 0)
            return;
        root.index = (root.index + 1) % Catalog.count;

        const item = Catalog.itemAt(root.index);
        if (!item)
            return;                      // its page has not arrived yet; next tick

        if (Shell.detail && Shell.detail.open)
            Shell.detail.openAt(root.index);

        if (root.rotateWallpaper) {
            // The monitor's own target, so the export is at its real pixel size
            // rather than something that merely fits.
            const target = Targets.all.find(t => t.group === "Desktop");
            if (target)
                Catalog.exportItem(item, target.id, function (err, payload) {
                    if (!err && payload)
                        Sys.setWallpaper(payload.path);
                });
        }
    }

    /*
     * ONE WAY IN, not two.
     *
     * This used to declare a `menuItems` row AND register an action — the same
     * verb twice, which showed up twice the moment the overflow started drawing
     * registered actions. `menuItems` is for a lens's own verbs on its own
     * screen; an app-wide verb is an action.
     *
     * Re-registered when the label changes, because the row names what it will
     * do next, not what it is.
     */
    function _register() {
        Host.registerAction({
            "id": "slideshow.toggle",
            "label": root.running ? "Stop the slideshow" : "Start a slideshow",
            "icon": root.running ? "pause" : "slideshow",
            "hint": root.running ? `every ${root.intervalSeconds}s` : "S",
            "run": () => root.toggle()
        });
    }

    onActivated: root._register()
    onRunningChanged: if (root.active)
        root._register()

    onDeactivated: {
        root.running = false;
        Host.unregisterAction("slideshow.toggle");
    }

    property Timer _tick: Timer {
        interval: root.intervalSeconds * 1000
        repeat: true
        running: root.running && root.active
        onTriggered: root.step()
    }

    // A small dock while it runs: what it is doing, and how to stop it.
    overlay: Component {
        Rectangle {
            visible: root.running
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 96
            width: row.implicitWidth + 24
            height: 44
            radius: Appearance.rounding.full
            color: Appearance.colors.colLayer1
            border.width: 1
            border.color: Appearance.colors.colLayer0Border

            Row {
                id: row
                anchors.centerIn: parent
                spacing: 8

                IconButton {
                    icon: "pause"
                    size: 32
                    onClicked: root.toggle()
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: `${root.index + 1} / ${Catalog.count}`
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colOnLayer1
                }

                IconButton {
                    icon: "wallpaper"
                    size: 32
                    toggled: root.rotateWallpaper
                    tooltip: "Also set each one as the wallpaper"
                    onClicked: root.rotateWallpaper = !root.rotateWallpaper
                }
            }
        }
    }

    settingsPage: Component {
        Row {
            spacing: 8

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Every"
                color: Appearance.colors.colSubtext
                font.pixelSize: Appearance.font.pixelSize.smaller
            }

            Repeater {
                model: [10, 20, 60, 300]

                delegate: PillTab {
                    required property int modelData
                    label: modelData >= 60 ? `${modelData / 60}m` : `${modelData}s`
                    active: root.intervalSeconds === modelData
                    labelSize: Appearance.font.pixelSize.smaller
                    onTriggered: root.intervalSeconds = modelData
                }
            }
        }
    }
}
