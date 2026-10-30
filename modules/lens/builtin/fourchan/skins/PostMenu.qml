import qs.modules.widgets
import qs.services
import QtQuick

/*
 * THE RIGHT-CLICK MENU ON A POST.
 *
 * One instance per skin, pointed at by every post — a menu per post would
 * build hundreds in a catalogue, and a recycled delegate would tear an open
 * one down mid-click. Positions arrive in scene coordinates for the same
 * reason: the post that was clicked may be gone by the time the menu closes.
 *
 * The rows are quarry's rows, in quarry's order — open, find more like it,
 * export, keep, copy, open the source, hide — so this menu and the one on a
 * gallery tile read as the same menu wearing the lens's data. Everything that
 * needs a catalogue row takes the picture first; see Main.qml `withItem`.
 */
MenuPopup {
    id: root

    required property var lens
    property var post: null

    minWidth: 250

    readonly property bool hasFile: root.post !== null && root.lens.hasImage(root.post)
    readonly property bool isVideo: root.hasFile && root.lens.isVideo(root.post)
    readonly property bool added: root.hasFile && root.lens.isAdded(root.post)
    readonly property var monitors: Targets.all.filter(t => t.group === "Desktop")
    readonly property var engines: root.hasFile ? root.lens.webSearches(root.post) : []

    /*
     * The anchor is remembered and the clamp is a BINDING. Assigning `post`
     * changes which rows are visible, and the column's implicitHeight only
     * catches up on the next polish — so a clamp computed here used the
     * PREVIOUS post's height and ran the menu off the bottom of the screen.
     */
    property real anchorX: 0
    property real anchorY: 0

    x: Math.max(8, Math.min(root.anchorX, (root.parent ? root.parent.width : 0) - root.implicitWidth - 8))
    y: Math.max(8, Math.min(root.anchorY, (root.parent ? root.parent.height : 0) - root.implicitHeight - 8))

    // Escape belongs to the menu while it is open, not to the viewer underneath.
    focus: true

    function openFor(post, sceneX, sceneY) {
        root.post = post;
        const local = root.parent.mapFromItem(null, sceneX, sceneY);
        root.anchorX = local.x;
        root.anchorY = local.y;
        root.open();
    }

    MenuRow {
        text: root.isVideo ? "Play it full size" : "Open it full size"
        icon: root.isVideo ? "play_circle" : "open_in_full"
        hint: root.post && root.post.w > 0 ? `${root.post.w}×${root.post.h}` : ""
        visible: root.hasFile
        onTriggered: {
            root.close();
            root.lens.openViewer(root.post);
        }
    }

    MenuRow {
        text: "Read this thread"
        icon: "forum"
        hint: root.post && root.post.replies !== undefined ? `${root.post.replies} replies` : ""
        visible: root.lens.screen === "catalog"
        onTriggered: {
            root.close();
            root.lens.showThread(root.post.no, root.post.sub || "");
        }
    }

    MenuRow {
        text: root.added ? "In your catalogue" : "Take it into quarry"
        icon: root.added ? "check" : "add_photo_alternate"
        checked: root.added
        enabled: !root.added
        visible: root.hasFile
        onTriggered: {
            root.close();
            root.lens.addImage(root.post, null);
        }
    }

    MenuRow {
        text: "Find more like it"
        icon: "image_search"
        hint: "in quarry"
        visible: root.hasFile && !root.isVideo
        onTriggered: {
            root.close();
            root.lens.findSimilar(root.post);
        }
    }

    // Somebody else's engine, for the picture as it is on the CDN. The list is
    // the app's, so this menu and a tile's can never disagree about it.
    MenuSubmenu {
        text: "Search with this picture"
        icon: "travel_explore"
        minWidth: 260
        parentMenu: root
        visible: root.engines.length > 0

        Repeater {
            model: root.visible ? root.engines : []

            delegate: MenuRow {
                required property var modelData
                text: modelData.label
                icon: modelData.icon
                hint: modelData.hint || ""
                onTriggered: {
                    root.close();
                    Sys.open(modelData.url);
                }
            }
        }
    }

    MenuSubmenu {
        text: "Export"
        icon: "output"
        minWidth: 264
        parentMenu: root
        visible: root.hasFile && !root.isVideo

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
                    root.lens.exportImage(root.post, modelData.id);
                }
            }
        }
    }

    MenuSubmenu {
        text: "Set as wallpaper"
        icon: "wallpaper"
        minWidth: 240
        parentMenu: root
        visible: root.hasFile && !root.isVideo && root.monitors.length > 0

        Repeater {
            model: root.monitors

            delegate: MenuRow {
                required property var modelData
                text: modelData.label.replace("Wallpaper · ", "").replace(/\s*\(.*\)$/, "")
                icon: "desktop_windows"
                hint: modelData.recipe ? `${modelData.recipe.width}×${modelData.recipe.height}` : ""
                onTriggered: {
                    root.close();
                    root.lens.setWallpaper(root.post, modelData.id);
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
        minWidth: 230
        parentMenu: root

        MenuRow {
            text: "The picture"
            icon: "image"
            // Only while the menu is really up: `fullFor` ASKS for the file, so
            // an eager binding downloaded a 6 MB webm every time this menu was
            // opened to copy a link.
            hint: root.visible && root.hasFile && root.lens.fullFor(root.post).length === 0 ? "fetching…" : ""
            visible: root.hasFile && !root.isVideo
            onTriggered: {
                root.close();
                root.lens.copyImageFile(root.post);
            }
        }
        MenuRow {
            text: "Image link"
            icon: "link"
            visible: root.hasFile
            onTriggered: {
                root.close();
                root.lens.copyImageLink(root.post);
            }
        }
        MenuRow {
            text: "Post link"
            icon: "public"
            visible: root.post !== null
            onTriggered: {
                root.close();
                root.lens.copyPostLink(root.post);
            }
        }
        MenuRow {
            text: "The post's text"
            icon: "notes"
            visible: !!(root.post && root.post.com)
            onTriggered: {
                root.close();
                Sys.copyText(root.lens.plainText(root.post), ok => ok ? Toast.show("Text copied") : Toast.error("Could not copy — " + Sys.lastError));
            }
        }
    }

    MenuRow {
        text: "Open the post on 4chan"
        icon: "open_in_new"
        visible: root.post !== null
        onTriggered: {
            root.close();
            root.lens.openOnSite(root.post);
        }
    }

    MenuRow {
        text: "Open the file on i.4cdn.org"
        icon: "launch"
        visible: root.hasFile
        onTriggered: {
            root.close();
            root.lens.openImageInBrowser(root.post);
        }
    }

    MenuRow {
        separator: true
    }

    MenuRow {
        text: root.post ? `${root.lens.fileName(root.post)}` : ""
        icon: "info"
        hint: root.post ? `${root.post.w}×${root.post.h}` : ""
        enabled: false
        visible: root.hasFile
    }

    /*
     * A thread's number IS its first post's number, so "hide this post" on the
     * OP inside a thread would quietly drop the whole thread from the
     * catalogue. From the catalogue that is exactly what the row means; from
     * inside the thread it is not offered.
     */
    MenuRow {
        text: root.lens.screen === "catalog" ? "Hide this thread" : "Hide this post"
        icon: "visibility_off"
        destructive: true
        visible: root.post !== null && (root.lens.screen === "catalog" || !root.lens.isOp(root.post))
        onTriggered: {
            root.close();
            root.lens.hidePost(root.post);
        }
    }
}
