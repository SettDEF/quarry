import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick

/*
 * The tile context menu. One instance at window level that every layout points
 * at — a menu per tile would instantiate hundreds in a wall, and recycled tiles
 * would tear an open menu down mid-click. Positions arrive in scene coordinates
 * for the same reason: the tile that was clicked may be gone by the time the
 * menu closes.
 *
 * Rows are the action record from PLAN.md — { label, icon, hint, destructive } —
 * and every row carries an icon, because that is what makes a long menu
 * scannable.
 */
MenuPopup {
    id: root

    property var item: null

    signal openRequested(var item)
    signal exportRequested(var item, string targetId)
    signal targetsRequested(var item)
    signal copyRequested(var item, string what)
    signal pageRequested(var item, string where)
    signal hideRequested(var item)
    signal boardRequested(var item, string board)
    signal wallpaperRequested(var item, string monitorTarget)
    signal keepRequested(var item)
    signal similarRequested(var item, string method)
    signal searchRequested(string token)

    minWidth: 256

    readonly property var monitors: Targets.all.filter(t => t.group === "Desktop")
    readonly property bool stillPicture: root.item && root.item.family !== "model" && root.item.family !== "video" && root.item.family !== "audio"
    readonly property var tags: root.item && root.item.tags ? root.item.tags.filter(t => t && t.indexOf(":") < 0).slice(0, 8) : []

    /// Empty for a picture with no public URL, which hides the submenu.
    readonly property var engines: root.item && Catalog.pictureSearchEngines ? Catalog.pictureSearchEngines(root.item) : []

    readonly property string _sizeLabel: {
        if (!root.item)
            return "";
        if (root.item.family === "vector")
            return "vector · any size";
        if (root.item.family === "model")
            return "3D model";
        return root.item.w + "×" + root.item.h;
    }

    function openFor(item, sceneX, sceneY) {
        root.item = item;
        const local = root.parent.mapFromItem(null, sceneX, sceneY);
        root.x = Math.max(8, Math.min(local.x, root.parent.width - root.implicitWidth - 8));
        root.y = Math.max(8, Math.min(local.y, root.parent.height - root.implicitHeight - 8));
        root.open();
    }

    MenuRow {
        text: "Open"
        icon: "open_in_full"
        hint: "Enter"
        onTriggered: {
            root.close();
            root.openRequested(root.item);
        }
    }

    /*
     * "LIKE THIS" HAS SEVERAL MEANINGS.
     *
     * The row itself asks everything at once; the flyout is each way on its
     * own, in three groups — what your own catalogue holds, what the web
     * holds, and the plain searches (its tags, its artist, its colour, its
     * shape) that you think of at exactly this moment. The list comes from
     * Catalog, so the viewer's menu and this one never disagree, and Catalog
     * leaves out every row that cannot work for this picture rather than
     * offering one that answers nothing.
     */
    MenuSubmenu {
        text: "Find similar"
        icon: "image_search"
        minWidth: 300
        tapOpens: false
        parentMenu: root
        onTriggered: {
            root.close();
            root.similarRequested(root.item, "all");
        }

        Repeater {
            model: root.visible ? Catalog.similarMethods(root.item) : []
            // A group break arrives as a row of its own — the list is built in
            // one place, so its shape travels with it.
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

    /*
     * THE SAME PICTURE, SOMEBODY ELSE'S ENGINE.
     *
     * "Find it on the web" above answers inside quarry, which is what you
     * want nine times in ten. This is the tenth: a second opinion, or the
     * engine that happens to be good at this kind of picture — Lens for a
     * place, SauceNAO for drawn art, TinEye for the oldest copy.
     *
     * Absent when the picture is only on this disk: every one of these takes
     * a URL, and a row that cannot work should not be there to click.
     */
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

    /*
     * EVERY TARGET, BEHIND ONE ROW.
     *
     * These were top-level rows -- "Export · Steam avatar", "Export · Wallpaper
     * · eDP-1 (3072×1920)" -- so the two things you do most were also the two
     * longest strings in the menu, and they set its width. One row now, and the
     * targets cascade out of it.
     *
     * Recent first, because an export is a habit: the same two or three targets
     * over and over.
     */
    MenuSubmenu {
        text: "Export"
        icon: "output"
        hint: "E"
        minWidth: 264
        parentMenu: root

        Repeater {
            model: {
                const recent = Targets.recent.map(id => Targets.byId(id)).filter(t => t !== null);
                const seen = recent.map(t => t.id);
                // The rest underneath, so the submenu IS the full list and
                // "More targets…" is about cropping, not about finding one.
                const rest = Targets.all.filter(t => seen.indexOf(t.id) < 0);
                return recent.concat(rest);
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

        /*
         * WHAT USER SCRIPTS ADDED.
         *
         * GM_registerMenuCommand, in the one menu where a command has an item
         * to act on. Nothing is drawn when no script registered anything, so
         * a person with no scripts never sees that the feature exists —
         * which is the right trade for a menu people open twenty times an hour.
         */
        MenuRow {
            separator: true
            visible: Scripts.menuItems().length > 0
        }

        Repeater {
            model: Scripts.revision >= 0 ? Scripts.menuItems() : []

            delegate: MenuRow {
                required property var modelData
                text: modelData.label
                icon: modelData.icon
                onTriggered: {
                    root.close();
                    Scripts.runMenu(modelData, root.item);
                }
            }
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

    /*
     * ONTO A BOARD.
     *
     * Beside Export rather than buried, because they are the two things you do
     * with a picture you have found: send it somewhere, or put it next to
     * other pictures. The submenu lists boards that exist and offers a first
     * one when none do.
     */
    MenuSubmenu {
        text: "Add to a board"
        icon: "dashboard"
        minWidth: 240
        parentMenu: root

        Repeater {
            model: Catalog.boards

            delegate: MenuRow {
                required property var modelData
                text: modelData.name
                icon: "dashboard"
                hint: `${modelData.items}`
                checked: Catalog.board === modelData.name
                onTriggered: {
                    root.close();
                    root.boardRequested(root.item, modelData.name);
                }
            }
        }

        MenuRow {
            separator: true
            visible: Catalog.boards.length > 0
        }

        MenuRow {
            text: Catalog.boards.length > 0 ? "A new board" : "Start a board"
            icon: "add"
            onTriggered: {
                root.close();
                // Named for today, because naming it in a menu would mean a
                // text field in a menu. It can be renamed from the board.
                root.boardRequested(root.item, "Board " + (Catalog.boards.length + 1));
            }
        }

        MenuRow {
            separator: true
            visible: Catalog.boards.length > 0
        }

        // The way back out. Adding to a board you cannot see is filing, not
        // arranging, and the arranging is the point.
        MenuRow {
            text: "Open the board window"
            icon: "open_in_new"
            visible: Catalog.boards.length > 0
            onTriggered: {
                root.close();
                Sys.openBoard(Catalog.board.length > 0 ? Catalog.board : Catalog.boards[0].name);
            }
        }
    }

    /*
     * INTO A CONVERSATION.
     *
     * The third thing you do with a picture you have found, after exporting it
     * and filing it: give it to somebody. The flyout is the chats you talked to
     * most recently, because that is what a send almost always is, and the way
     * to every other chat is one row below.
     *
     * The rows go straight to the Morse service, the way "Open the board
     * window" goes straight to Sys — a menu that only emits a signal needs the
     * window to have been taught about it, and this is a service call, not a
     * view decision.
     *
     * Absent entirely on a machine that has never had Morse running: an
     * always-greyed row is a permanent question about software you do not have.
     */
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

        // The honest degrade: one row, the reason, and nothing to click.
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

    MenuSubmenu {
        text: "Set as wallpaper"
        icon: "wallpaper"
        minWidth: 240
        parentMenu: root
        visible: root.stillPicture && root.item.family !== "vector" && root.monitors.length > 0

        Repeater {
            model: root.monitors
            delegate: MenuRow {
                required property var modelData
                text: modelData.label.replace("Wallpaper · ", "").replace(/\s*\(.*\)$/, "")
                icon: "desktop_windows"
                hint: modelData.recipe ? `${modelData.recipe.width}×${modelData.recipe.height}` : ""
                onTriggered: {
                    root.close();
                    root.wallpaperRequested(root.item, modelData.id);
                }
            }
        }
    }

    MenuRow {
        text: "Keep in a collection…"
        icon: "bookmark_add"
        onTriggered: {
            root.close();
            root.keepRequested(root.item);
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
            text: "Image"
            icon: "image"
            visible: root.stillPicture
            onTriggered: {
                root.close();
                root.copyRequested(root.item, "image");
            }
        }
        MenuRow {
            text: "Image URL"
            icon: "link"
            onTriggered: {
                root.close();
                root.copyRequested(root.item, "url");
            }
        }
        MenuRow {
            text: "Page link"
            icon: "public"
            onTriggered: {
                root.close();
                root.copyRequested(root.item, "page");
            }
        }
    }

    MenuRow {
        text: root.item && root.item.source ? `Open on ${root.item.source}` : "Open source page"
        icon: "open_in_new"
        onTriggered: {
            root.close();
            root.pageRequested(root.item, "page");
        }
    }

    // The other route, always one row away: wherever "Source" is set to go,
    // the one it does not go to is still here.
    MenuRow {
        text: Prefs.browserEnabled && Prefs.browserSourceInApp ? "Open in my browser" : "Read it here"
        icon: Prefs.browserEnabled && Prefs.browserSourceInApp ? "launch" : "captive_portal"
        visible: Prefs.browserEnabled
        onTriggered: {
            root.close();
            root.pageRequested(root.item, Prefs.browserSourceInApp ? "page-external" : "page-in-app");
        }
    }

    /*
     * MORE OF WHAT THIS IS.
     *
     * Each row is a query you could have typed — the site, the artist, one
     * of its tags — so following one is a step in the history like any other
     * search, and Back returns here.
     */
    MenuSubmenu {
        text: "More from"
        icon: "manage_search"
        minWidth: 240
        parentMenu: root

        MenuRow {
            text: root.item ? root.item.source : ""
            icon: "language"
            hint: "source"
            onTriggered: {
                root.close();
                root.searchRequested(`source:${root.item.source}`);
            }
        }
        MenuRow {
            visible: !!(root.item && root.item.author && root.item.author.length > 0 && root.item.author.indexOf(" ") < 0)
            text: root.item && root.item.author ? root.item.author : ""
            icon: "person"
            hint: "artist"
            onTriggered: {
                root.close();
                root.searchRequested(`author:${root.item.author}`);
            }
        }
        MenuRow {
            visible: !!(root.item && root.item.kind)
            text: root.item && root.item.kind ? root.item.kind : ""
            icon: "category"
            hint: "kind"
            onTriggered: {
                root.close();
                root.searchRequested(`kind:${root.item.kind}`);
            }
        }
        MenuRow {
            separator: true
            visible: root.tags.length > 0
        }
        Repeater {
            model: root.tags
            delegate: MenuRow {
                required property string modelData
                text: modelData.replace(/_/g, " ")
                icon: "sell"
                onTriggered: {
                    root.close();
                    root.searchRequested(`tag:${modelData.replace(/\s+/g, "_")}`);
                }
            }
        }
    }

    MenuRow {
        separator: true
    }

    MenuRow {
        text: root._sizeLabel
        icon: "info"
        enabled: false
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
