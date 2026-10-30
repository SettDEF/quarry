import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick

/*
 * Everything you can do to one item, in one menu.
 *
 * The tile's right-click menu is deliberately short — the two or three things
 * you do while scanning a wall. This is the other end: opened from the detail
 * page's ⋮, it is the complete set, grouped, so nothing has to be remembered as
 * a shortcut or hidden behind a mode.
 *
 * Rows are the action record from PLAN.md, and every one carries an icon: a
 * fifteen-row menu without them is a wall of text.
 */
MenuPopup {
    id: root

    property var item: null

    signal exportRequested(var item, string targetId)
    signal targetsRequested(var item)
    signal wallpaperRequested(var item, string monitor)
    signal copyRequested(var item, string what)
    signal openRequested(var item, string where)
    signal similarRequested(var item, string method)
    signal hideRequested(var item)

    minWidth: 288

    readonly property var monitors: Targets.all.filter(t => t.group === "Desktop")
    readonly property bool isWallpaperish: root.item && root.item.family !== "model" && root.item.family !== "vector"
    readonly property var engines: root.item && Catalog.pictureSearchEngines ? Catalog.pictureSearchEngines(root.item) : []

    function openAt(x, y) {
        root.x = Math.max(8, Math.min(x, root.parent.width - root.implicitWidth - 8));
        root.y = Math.max(8, Math.min(y, root.parent.height - root.implicitHeight - 8));
        root.open();
    }

    // ── the thing you came for ───────────────────────────────────────────────

    MenuSubmenu {
        text: "Export"
        icon: "output"
        hint: "E"
        minWidth: 288
        parentMenu: root

        Repeater {
            model: {
                const recent = Targets.recent.map(id => Targets.byId(id)).filter(t => t);
                const seen = recent.map(t => t.id);
                return recent.concat(Targets.all.filter(t => seen.indexOf(t.id) < 0));
            }

            delegate: MenuRow {
                required property var modelData
                text: modelData.label
                icon: modelData.icon
                hint: modelData.recipe && modelData.recipe.fit === "none"
                    ? "original"
                    : (modelData.recipe ? `${modelData.recipe.width}×${modelData.recipe.height}` : "")
                onTriggered: {
                    root.close();
                    root.exportRequested(root.item, modelData.id);
                }
            }
        }

        MenuRow {
            separator: true
        }

        MenuRow {
            text: "Crop it yourself…"
            icon: "crop"
            onTriggered: {
                root.close();
                root.targetsRequested(root.item);
            }
        }
    }

    // ── somebody else ────────────────────────────────────────────────────────

    MenuRow {
        separator: true
        visible: Dispatch.everSeen
    }

    // Same rows as the tile menu's, for the same reason they are the same
    // wording everywhere: one action, one place it is defined. See
    // ItemContextMenu.qml for why this calls the service directly.
    MenuSubmenu {
        text: "Send to a chat"
        icon: "send"
        minWidth: 260
        parentMenu: root
        visible: Dispatch.everSeen
        onTriggered: {
            root.close();
            Dispatch.openPicker(root.item);
        }

        MenuRow {
            text: Dispatch.reason
            icon: "cloud_off"
            enabled: false
            visible: !Dispatch.available
        }

        Repeater {
            model: Dispatch.available ? Dispatch.chats.slice(0, 5) : []

            delegate: MenuRow {
                required property var modelData
                text: modelData.title
                icon: modelData.kind === "private" ? "person" : (modelData.kind === "channel" ? "campaign" : "group")
                onTriggered: {
                    root.close();
                    Dispatch.quickSend(root.item, modelData);
                }
            }
        }

        MenuRow {
            separator: true
            visible: Dispatch.available
        }

        MenuRow {
            text: "Another chat…"
            icon: "search"
            visible: Dispatch.available
            onTriggered: {
                root.close();
                Dispatch.openPicker(root.item);
            }
        }
    }

    // ── the desktop ──────────────────────────────────────────────────────────

    MenuRow {
        separator: true
        visible: root.isWallpaperish
    }

    Repeater {
        model: root.isWallpaperish ? root.monitors : []

        delegate: MenuRow {
            required property var modelData
            // "Set as wallpaper · HDMI-A-1" rather than a submenu: two monitors
            // is two rows, and a submenu for two rows is a click for nothing.
            text: "Wallpaper · " + modelData.id.replace("wallpaper-", "")
            icon: "wallpaper"
            hint: `${modelData.recipe.width}×${modelData.recipe.height}`
            onTriggered: {
                root.close();
                root.wallpaperRequested(root.item, modelData.id);
            }
        }
    }

    // ── copies ───────────────────────────────────────────────────────────────

    MenuRow {
        separator: true
    }

    MenuRow {
        text: "Copy image"
        icon: "content_copy"
        onTriggered: {
            root.close();
            root.copyRequested(root.item, "image");
        }
    }

    MenuRow {
        text: "Copy source URL"
        icon: "link"
        onTriggered: {
            root.close();
            root.copyRequested(root.item, "url");
        }
    }

    MenuRow {
        text: "Copy as a query"
        icon: "terminal"
        // The query that would find this row again — the closest thing to a
        // permalink a catalogue of many sources has.
        onTriggered: {
            root.close();
            root.copyRequested(root.item, "query");
        }
    }

    // ── elsewhere ────────────────────────────────────────────────────────────

    MenuRow {
        separator: true
    }

    MenuRow {
        text: "Open source page"
        icon: "open_in_new"
        visible: root.item && root.item.page_url && root.item.page_url.length > 0
        onTriggered: {
            root.close();
            root.openRequested(root.item, "page");
        }
    }

    MenuRow {
        text: Prefs.browserEnabled && Prefs.browserSourceInApp ? "Open in my browser" : "Read it here"
        icon: Prefs.browserEnabled && Prefs.browserSourceInApp ? "launch" : "captive_portal"
        visible: Prefs.browserEnabled && !!root.item && !!root.item.page_url && root.item.page_url.length > 0
        onTriggered: {
            root.close();
            root.openRequested(root.item, Prefs.browserSourceInApp ? "page-external" : "page-in-app");
        }
    }

    MenuRow {
        text: "Show in files"
        icon: "folder_open"
        onTriggered: {
            root.close();
            root.openRequested(root.item, "folder");
        }
    }

    // Every picture: the daemon measures an unmeasured one on the spot. Gating
    // this on a stored colour hid it on most rows, which read as "similar does
    // not work". Clicking the row asks every way at once; the flyout picks one.
    // Same list as the tile menu's, from Catalog — see ItemContextMenu.qml.
    MenuSubmenu {
        text: "Find similar"
        icon: "image_search"
        hint: "S"
        minWidth: 300
        parentMenu: root
        visible: !!root.item
        onTriggered: {
            root.close();
            root.similarRequested(root.item, "all");
        }

        Repeater {
            model: root.visible ? Catalog.similarMethods(root.item) : []
            delegate: MenuRow {
                required property var modelData
                separator: modelData.separator === true
                text: modelData.label || ""
                icon: modelData.icon || ""
                hint: modelData.hint || ""
                onTriggered: {
                    if (modelData.separator === true)
                        return;
                    root.close();
                    root.similarRequested(root.item, modelData.id);
                }
            }
        }
    }

    // Somebody else's engine, for a second opinion. Hidden for a picture that
    // is only on this disk — all of these take a URL.
    MenuSubmenu {
        text: "Search with this picture"
        icon: "travel_explore"
        minWidth: 260
        parentMenu: root
        visible: root.engines.length > 0

        Repeater {
            model: root.engines
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

    MenuRow {
        separator: true
    }

    MenuRow {
        text: "Hide forever"
        icon: "visibility_off"
        destructive: true
        onTriggered: {
            root.close();
            root.hideRequested(root.item);
        }
    }
}
