import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick
import "../fmt.js" as Fmt

/*
 * THE RIGHT-CLICK MENU ON A MESSAGE.
 *
 * quarry's rows, in quarry's order — open, keep, find more like it, export,
 * wallpaper, copy — so a picture from a chat offers the same things as a
 * picture from a booru. The rows that need a catalogue row keep the picture
 * first, because that is what you were going to do anyway.
 *
 * NOTHING HERE WRITES TO TELEGRAM. There is no reply, no forward, no reaction
 * and no delete, and that is not an oversight: Wire.qml would refuse them.
 */
MenuPopup {
    id: root

    required property var lens
    property var message: null
    /// The link right-clicked in the message, "" when it was not one.
    property string link: ""

    minWidth: 250

    readonly property var media: root.message ? root.message.media : null
    readonly property bool drawable: Fmt.isDrawable(root.media)
    readonly property bool still: root.drawable && !Fmt.isMoving(root.media)
    readonly property bool added: root.message ? root.lens.isAdded(root.message) : false
    readonly property bool here: root.message ? root.lens.heldFile(root.message).length > 0 : false
    readonly property var monitors: Targets.all.filter(t => t.group === "Desktop")
    /// Nothing leaves a secret chat — see Main.qml. The rows that would are not
    /// greyed, they are absent: an offer that is always refused is not an offer.
    readonly property bool sealed: root.lens.chatIsSecret

    /*
     * The anchor is remembered and the clamp is a BINDING: setting `message`
     * changes which rows are visible, and the column's implicitHeight catches
     * up only on the next polish — a clamp computed here uses the previous
     * message's height and runs the menu off the bottom of the screen.
     */
    property real anchorX: 0
    property real anchorY: 0

    x: Math.max(8, Math.min(root.anchorX, (root.parent ? root.parent.width : 0) - root.implicitWidth - 8))
    y: Math.max(8, Math.min(root.anchorY, (root.parent ? root.parent.height : 0) - root.implicitHeight - 8))

    // Escape belongs to the menu while it is open, not the viewer underneath.
    focus: true

    function openFor(message, sceneX, sceneY, link) {
        root.message = message;
        root.link = String(link || "");
        const local = root.parent.mapFromItem(null, sceneX, sceneY);
        root.anchorX = local.x;
        root.anchorY = local.y;
        root.open();
    }

    // ── a link in the message ────────────────────────────────────────────────
    MenuRow {
        text: "Open link"
        icon: "open_in_new"
        hint: (root.link.match(/^[a-z]+:\/\/([^\/?#]+)/i) || ["", ""])[1].replace(/^www\./, "")
        visible: root.link.length > 0
        onTriggered: {
            root.close();
            root.lens.openLink(root.link);
        }
    }

    MenuSubmenu {
        text: "Open with"
        icon: "apps"
        minWidth: 230
        parentMenu: root
        visible: root.link.length > 0

        MenuRow {
            text: "Default browser"
            icon: "public"
            onTriggered: {
                root.close();
                Sys.open(root.link);
            }
        }

        MenuRow {
            text: "quarry's window"
            icon: "web"
            onTriggered: {
                root.close();
                root.lens.showSite(root.link);
            }
        }

        MenuRow {
            separator: true
            visible: Sys.browsers.length > 0
        }

        Repeater {
            model: Sys.browsers

            delegate: MenuRow {
                required property var modelData
                text: modelData.name
                icon: "language"
                onTriggered: {
                    root.close();
                    Sys.openWith(modelData.id, root.link);
                }
            }
        }
    }

    MenuRow {
        text: "Copy link"
        icon: "link"
        visible: root.link.length > 0
        onTriggered: {
            root.close();
            Sys.copyText(root.link);
        }
    }

    MenuRow {
        separator: true
        visible: root.link.length > 0
    }

    MenuRow {
        text: Fmt.isMoving(root.media) ? "Play it full size" : "Open it full size"
        icon: Fmt.isMoving(root.media) ? "play_circle" : "open_in_full"
        hint: root.media && root.media.width > 0 ? `${root.media.width}×${root.media.height}` : ""
        visible: root.drawable
        onTriggered: {
            root.close();
            root.lens.openViewer(root.message);
        }
    }

    MenuRow {
        text: root.added ? "In your catalogue" : "Keep it in quarry"
        icon: root.added ? "check" : "add_photo_alternate"
        hint: root.added ? "" : (root.here ? "" : "fetches it first")
        checked: root.added
        enabled: !root.added
        visible: root.media !== null && !root.sealed
        onTriggered: {
            root.close();
            root.lens.take(root.message, null);
        }
    }

    MenuRow {
        text: "Find more like it"
        icon: "image_search"
        hint: "in quarry"
        visible: root.still && !root.sealed
        onTriggered: {
            root.close();
            root.lens.findSimilar(root.message);
        }
    }

    MenuSubmenu {
        text: "Export"
        icon: "output"
        minWidth: 264
        parentMenu: root
        visible: root.still && !root.sealed

        Repeater {
            model: {
                const recent = Targets.recent.map(id => Targets.byId(id)).filter(t => t !== null);
                const seen = recent.map(t => t.id);
                return recent.concat(Targets.all.filter(t => seen.indexOf(t.id) < 0));
            }

            delegate: MenuRow {
                required property var modelData
                text: modelData.label
                icon: modelData.icon
                hint: modelData.recipe && modelData.recipe.fit === "none" ? "original" : (modelData.recipe ? `${modelData.recipe.width}×${modelData.recipe.height}` : "")
                onTriggered: {
                    root.close();
                    root.lens.exportMedia(root.message, modelData.id);
                }
            }
        }
    }

    MenuSubmenu {
        text: "Set as wallpaper"
        icon: "wallpaper"
        minWidth: 240
        parentMenu: root
        visible: root.still && !root.sealed && root.monitors.length > 0

        Repeater {
            model: root.monitors

            delegate: MenuRow {
                required property var modelData
                text: modelData.label.replace("Wallpaper · ", "").replace(/\s*\(.*\)$/, "")
                icon: "desktop_windows"
                hint: modelData.recipe ? `${modelData.recipe.width}×${modelData.recipe.height}` : ""
                onTriggered: {
                    root.close();
                    root.lens.setWallpaper(root.message, modelData.id);
                }
            }
        }
    }

    MenuRow {
        separator: true
    }

    MenuSubmenu {
        text: "Copy"
        icon: "content_copy"
        minWidth: 220
        parentMenu: root

        MenuRow {
            text: "The picture"
            icon: "image"
            hint: root.here ? "" : "fetch it first"
            enabled: root.here && !root.sealed
            visible: root.still && !root.sealed
            onTriggered: {
                root.close();
                root.lens.copyPicture(root.message);
            }
        }
        MenuRow {
            text: "The message"
            icon: "notes"
            visible: !!(root.message && root.message.text) && !root.sealed
            onTriggered: {
                root.close();
                root.lens.copyText(root.message);
            }
        }
    }

    MenuRow {
        text: "Save to Downloads"
        icon: "download"
        hint: root.here ? "" : "downloads first"
        visible: root.media !== null && !root.sealed
        onTriggered: {
            root.close();
            root.lens.saveFile(root.message);
        }
    }

    MenuRow {
        text: "Open in another app"
        icon: "open_in_new"
        hint: root.here ? "" : "downloads first"
        visible: root.media !== null && !root.sealed
        onTriggered: {
            root.close();
            root.lens.openFile(root.message);
        }
    }

    MenuRow {
        text: "Show in folder"
        icon: "folder_open"
        hint: root.here ? "" : "downloads first"
        visible: root.media !== null && !root.sealed
        onTriggered: {
            root.close();
            root.lens.showFile(root.message);
        }
    }

    MenuRow {
        separator: true
    }

    MenuRow {
        text: root.sealed ? "Secret chat — nothing leaves it" : (root.media ? Fmt.mediaLabel(root.media) : "Message")
        icon: root.media ? Fmt.mediaIcon(root.media) : "chat"
        hint: root.media && root.media.size > 0 ? Fmt.size(root.media.size) : ""
        enabled: false
    }
}
