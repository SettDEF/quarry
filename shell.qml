//@ pragma UseQApplication
//@ pragma AppId quarry
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic
//@ pragma Env QML_XHR_ALLOW_FILE_READ=1
//@ pragma Env QS_NO_RELOAD_POPUP=1
// The installed Morse app's QML, so the Morse lens can show Morse's real chat.
//@ pragma Env QML_IMPORT_PATH=/home/caesar/.local/share/morse

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.modules.common
import qs.modules.gallery
import qs.modules.widgets
import qs.services

/*
 * quarry — Phase 0.
 *
 * Rodded's chrome over quarry's catalog: a sparse app bar (a heading, not a
 * toolbar — sort, filters and layout live behind their buttons), the content as
 * one rounded panel, with every action in the toolbar above it
 * whose active destination expands to show its label.
 *
 * No daemon yet: Catalog reads fixtures/sample.json — 137 real items from six
 * live sources across three families — and will answer from the socket in
 * Phase 2 without any view noticing.
 */
ShellRoot {
    id: shell

    FloatingWindow {

        // browser-like scrolling for every list in the window (Momentum.qml)

        MomentumInjector { root: parent }
        id: win

        title: "quarry"
        implicitWidth: Prefs.windowWidth
        implicitHeight: Prefs.windowHeight
        color: Appearance.colors.colLayer0Base
        // So IPC and the launcher can raise it (see services/Shell.qml).
        Component.onCompleted: Shell.window = win
        //
        //         * CLOSING THE WINDOW ENDS THE PROCESS.
        //         *
        //         * It did not, and the instance outlived its window: `Shell.present()`
        //         * sets `visible = true`, but a FloatingWindow that the compositor has
        //         * closed does not map again — `app toggle` answers "shown" twice in a
        //         * row, with the window count still zero. So a closed quarry left a
        //         * live, windowless process behind, and `/usr/bin/quarry` hands off to
        //         * any running instance over IPC before it considers spawning one:
        //         * `qs ipc call` exits 0 even for an unknown METHOD, so the launcher
        //         * could never tell that nothing had happened. Launching printed
        //         * nothing and returned in 33ms.
        //         *
        //         * Quitting on close also settles where the window appears. The
        //         * launcher only spawns when nothing answers, so a resident instance
        //         * meant every launch raised the window on whatever workspace it was
        //         * first opened on. A fresh process opens where you are.
        //         *
        //         * The catalog is not lost with it — that lives in quarryd, which stays
        //         * resident. This window is a client of it, and cheap to build again.
        //
        //
        //         * `onClosed` never fires for a compositor close in Quickshell 0.3.1, and
        //         * `Quickshell.quit()` is not a function there (TypeError) —
        //         * measured: window gone, process still alive. `visible` is the signal
        //         * that actually moves, so quit on that.
        //         *
        //         * This makes hiding equivalent to quitting, which costs `app toggle`
        //         * its hide — a fair trade against the failure it replaces. A closed
        //         * window could not be re-mapped (`present()` sets `visible = true` and
        //         * nothing appears), so the instance became a live process with no
        //         * window and no way to get one. `/usr/bin/quarry` hands off to any
        //         * running instance over IPC before it will spawn, and `qs ipc call`
        //         * exits 0 even for an unknown method, so the launcher could not tell:
        //         * quarry simply stopped opening, and printed nothing saying why.
        //         *
        //         * The catalog survives in quarryd, which stays resident. This window is
        //         * a client of it and cheap to rebuild — and a fresh process opens on
        //         * the workspace you are actually on, rather than the one it was first
        //         * opened on.
        //
        onVisibleChanged: {
            if (!visible) {
                Qt.quit();
            }
        }

        /*
         * ONE SCROLLBAR, ON THE WINDOW'S EDGE.
         *
         * Each gallery attached its own inside its Flickable, which put it
         * inside the rounded panel and on top of the pictures — the one place
         * a picture is guaranteed to be. There is only ever one view visible,
         * so there only needs to be one bar, and it belongs on the window edge
         * where it covers nothing.
         *
         * Detached, so size and position are bound rather than managed by the
         * Flickable, and dragging writes back to it.
         */
        StyledScrollBar {
            id: edgeScroll

            readonly property var flick: Shell.gallery ? Shell.gallery.flickable : null
            /*
             * In the gutter OUTSIDE the panel, never over it.
             *
             * Anchors cannot reach `panel` — it is nested in the layout, not a
             * sibling of this — so the geometry is mapped instead. The bar's
             * LEFT edge starts where the panel's right edge ends, which is what
             * keeps it off the pictures.
             */
            readonly property point _tl: panel.mapToItem(parent, panel.width, 0)
            /*
             * A MINIMUM LENGTH, OR THERE IS NOTHING TO GRAB.
             *
             * `ScrollBar` draws its handle at `size × height`, and `size` is
             * the fraction of the content on screen. At 37,472 items that
             * fraction is about 0.002 — a handle two pixels tall, which is
             * invisible whatever colour it is and impossible to hit. Every
             * attempt to fix this by styling it was fixing the wrong thing.
             *
             * So the fraction is clamped to whatever makes 40px. The cost is
             * that the handle's travel no longer maps exactly to the content
             * (it cannot: a 2px handle in a 900px rail has 898px of travel for
             * 37k items either way), and 40px is the smallest thing worth
             * aiming a mouse at.
             */
            readonly property real minHandle: height > 0 ? 40 / height : 0

            Component.onCompleted: Shell.scrollBar = edgeScroll
            orientation: Qt.Vertical
            x: _tl.x + 3
            width: 6
            y: _tl.y + 6
            height: panel.height - 12
            /*
             * GONE WHILE A PICTURE IS OPEN.
             *
             * The bar lives in the window's gutter rather than inside the
             * panel, which is what keeps it off the wall — but the viewer, the
             * source page and the settings panel all COVER the window, and a
             * scrollbar for the gallery underneath was still drawn down the
             * edge of them. It scrolls something you cannot see, which reads as
             * a stray line rather than as a control.
             *
             * `detail` is the picture viewer, `browser` the source page. Sheets
             * are not listed: they are dialogs about one picture, they leave the
             * wall visible behind them, and its bar should stay with it.
             */
            readonly property bool covered: (detail && detail.open) || (browser && browser.open) || (settingsPanel && settingsPanel.open) || (filterPanel && filterPanel.open)

            visible: !!flick && size < 1 && !covered
            view: flick
            size: flick ? Math.max(flick.visibleArea.heightRatio, minHandle) : 0
            position: flick ? flick.visibleArea.yPosition : 0
            onPositionChanged: {
                if (pressed && flick)
                    flick.contentY = position * flick.contentHeight;

            }
            z: 50
        }

        Item {
            /*
                 * The floating Mix / Images / Video dock is gone. It was the
                 * only way to switch media before the rail existed; the rail's
                 * Media section does the same with counts, and the dock sat on
                 * top of the pictures to do it.
                 */
            /*
                 * The bottom NavDock is gone. Every one of its four
                 * destinations already had a button in the toolbar — sources
                 * was `filterPanel.toggle()` (the tune icon), targets was
                 * `targetSheet.openFor(Catalog.itemAt(0))` (the crop icon,
                 * character for character), settings opened this same menu,
                 * and browse only closed whatever was open, which Escape does.
                 * So it was four permanent buttons drawn ON TOP of the
                 * pictures, none of which did anything new.
                 */

            id: content

            // A lens covers the panel; the wall underneath is not just hidden
            // but stopped, so it is not decoding thumbnails nobody can see.
            readonly property bool lensUp: Lenses.activeId.length > 0
            // No dock to clear any more — just breathing room at the end of a
            // scroll so the last row is not flush against the window edge.
            readonly property real dockInset: 16
            // ── frame timing, so "60 fps" stays a measurement ─────────────────
            // The counter lives in Perf so the same numbers are readable over
            // IPC without raising the window.
            readonly property real fps: Perf.fps
            // Keep the IPC handlers alive for the lifetime of the window.
            property var _ipc: Ipc

            //
            //             * Run an export and say where it went.
            //             *
            //             * The daemon does the work — fetch, rasterise or decode, fit, crop,
            //             * encode, write — so this only has to report. The path is the whole
            //             * result: it is what you paste, drag, or hand to the platform.
            //
            //
            //             * WHAT YOU CAN DO TO ONE PICTURE, IN ONE PLACE.
            //             *
            //             * The viewer and the tile menu offer the same verbs, and each had
            //             * its own wiring — the tile menu's copy, "open source page" and
            //             * hide were console.log calls, so those rows did nothing at all.
            //             * Both call these now.
            //
            function setWallpaper(it, monitorTarget) {
                if (!it)
                    return ;

                Toast.show("Exporting for " + monitorTarget.replace("wallpaper-", "") + "…");
                Catalog.exportItem(it, monitorTarget, function(err, payload) {
                    if (err) {
                        Toast.error("Export failed: " + err);
                        return ;
                    }
                    Sys.setWallpaper(payload.path, function(ok) {
                        // Which switcher, and where the file is: "it
                        // failed" leaves nothing to do next.

                        if (ok)
                            Toast.show("Wallpaper set · the palette follows");
                        else
                            Toast.error(`Saved to ${payload.path} — no wallpaper switcher answered (tried your ii switchwall.sh, swww, hyprpaper)`);
                    });
                });
            }

            function copyItem(it, what) {
                if (!it)
                    return ;

                // The toast waits for wl-copy: saying "copied" before the
                // clipboard has it means someone pastes nothing and has no
                // idea why. On a machine with no wl-copy, that was every time.
                if (what === "url") {
                    Sys.copyText(it.url, (ok) => {
                        return ok ? Toast.show("Image URL copied") : Toast.error("Could not copy — " + Sys.lastError);
                    });
                } else if (what === "page") {
                    const link = it.page_url && it.page_url.length > 0 ? it.page_url : it.url;
                    Sys.copyText(link, (ok) => {
                        return ok ? Toast.show("Page link copied") : Toast.error("Could not copy — " + Sys.lastError);
                    });
                } else if (what === "query") {
                    Sys.copyText(`id:${it.id}`, (ok) => {
                        return ok ? Toast.show("Query copied") : Toast.error("Could not copy — " + Sys.lastError);
                    });
                } else {
                    // The image itself, which is what every platform without
                    // an upload API actually needs.
                    Toast.show("Exporting to copy…");
                    Catalog.exportItem(it, content.topTarget(), function(err, payload) {
                        if (err) {
                            Toast.error("Could not copy: " + err);
                            return ;
                        }
                        Sys.copyImage(payload.path, "image/png", (ok) => {
                            return ok ? Toast.show("Image copied · paste it anywhere") : Toast.error("Exported, but could not copy — " + Sys.lastError);
                        });
                    });
                }
            }

            function openItem(it, where) {
                if (!it)
                    return ;

                if (where === "page" || where === "page-external" || where === "page-in-app") {
                    const page = it.page_url && it.page_url.length > 0 ? it.page_url : it.url;
                    // One place decides where a source page goes, so the tile
                    // menu and the viewer can never disagree about it. The two
                    // explicit forms are the menu rows that name a destination.
                    const inApp = where === "page-in-app" || (where === "page" && Prefs.browserEnabled && Prefs.browserSourceInApp);
                    if (!inApp) {
                        Sys.open(page);
                        return ;
                    }
                    // quarry's own window, with the in-app view as the
                    // fallback it always was — see Lens.showSite for why the
                    // window has to be a separate program.
                    Sys.run(["quarry-browser", page, ""], function(ok) {
                        if (!ok)
                            browser.openUrl(page);

                    });
                } else if (where === "image")
                    Sys.open(it.url);
                else if (Catalog.lastExport.length > 0)
                    Sys.showInFiles(Catalog.lastExport);
                else
                    Toast.show("Nothing exported yet");
            }

            // Whatever you exported to last, or the Steam avatar to begin with.
            function topTarget() {
                return Targets.recent.length > 0 ? Targets.recent[0] : "steam-avatar";
            }

            //
            //             * FINISH THE JOB, DO NOT JUST WRITE A FILE.
            //             *
            //             * This said "exported" and offered to copy the PATH — which is the
            //             * one thing you cannot paste into an upload box. A destination now
            //             * carries what completing it means (Targets `after`): the picture
            //             * on the clipboard, and the page it belongs on opened. A wallpaper
            //             * already worked this way; the accounts did not, and "export" was
            //             * the word covering the gap.
            //
            //
            //             * A QUICK ACTION FROM A TILE.
            //             *
            //             * The right-click menu could already do every one of these; what
            //             * was missing was the choice to have one as a BUTTON on the
            //             * picture, per layout. So the ids route to the same calls the menu
            //             * makes — one place doing the work, two ways of asking for it.
            //
            function tileAction(item, id) {
                if (!item)
                    return ;

                switch (id) {
                case "keep":
                    collectionSheet.openFor(item);
                    break;
                case "board":
                    /*
                     * The board you are on, or the only one you have.
                     *
                     * With several boards and none of them open there is no
                     * right answer for a single button, so it hands over to the
                     * menu that can ask — rather than guessing and putting the
                     * picture somewhere you have to go and find.
                     */
                    if (Catalog.board.length > 0)
                        Catalog.placeOnBoardNamed(Catalog.board, item);
                    else if (Catalog.boards.length === 1)
                        Catalog.placeOnBoardNamed(Catalog.boards[0].name || Catalog.boards[0], item);
                    else
                        menu.openFor(item, content.width / 2, content.height / 2);
                    break;
                case "wallpaper":
                    content.setWallpaper(item, "");
                    break;
                case "copy":
                    content.copyItem(item, "image");
                    break;
                case "similar":
                    Catalog.findSimilar(item, false, "all");
                    break;
                case "hide":
                    Catalog.hideItem(item);
                    break;
                default:
                    // An id nobody wired is a bug in the tile, not a thing to
                    // swallow: the tile only offers what this switch answers.
                    Toast.error(`No such action: ${id}`);
                }
            }

            /*
             * WHAT A RIGHT-CLICK ON ONE OF THE APP'S OWN RAIL ROWS OFFERS.
             *
             * A lens answers `navMenu` for its own rows; these are the rows the
             * app owns, and nothing else knows what they mean. Each entry is a
             * verb you would otherwise have to find in Settings or in the
             * overflow — which is the whole point of a menu on the thing
             * itself.
             */
            function railMenu(what) {
                if (what === "everything")
                    return [{
                        "label": "Reload the catalogue",
                        "icon": "refresh",
                        "action": () => {
                            Catalog.load();
                            Catalog.filterNow();
                            Toast.show("Catalogue reloaded");
                        }
                    }, {
                        "label": "Fetch more everywhere",
                        "icon": "travel_explore",
                        "action": () => {
                            return Catalog.searchSources();
                        }
                    }, {
                        "label": "Empty the catalogue…",
                        "icon": "delete_forever",
                        "hint": "asks again",
                        "destructive": true,
                        "action": () => {
                            settingsPanel.page = "storage";
                            settingsPanel.open = true;
                            Toast.show("Storage — press the catalogue row twice to empty it");
                        }
                    }];

                if (what === "history")
                    return [{
                        "label": "Open history",
                        "icon": "history",
                        "action": () => {
                            return historyPanel.toggle();
                        }
                    }, {
                        "label": "Forget everything here",
                        "icon": "delete_sweep",
                        "destructive": true,
                        "action": () => {
                            Client.call("history_clear", {
                                "kind": ""
                            }, (err, payload) => {
                                if (err) {
                                    Toast.error(`Could not clear history — ${err}`);
                                    return ;
                                }
                                Toast.show(payload && payload.removed > 0 ? `Forgot ${payload.removed} entries` : "Nothing to forget");
                            });
                        }
                    }];

                // A filter row: the one thing worth offering is the way out of
                // it, plus fetching more of exactly this.
                const parts = String(what).split(":");
                if (parts.length < 2)
                    return [];

                const key = parts[0] === "collection" ? "collection" : parts[0];
                const value = parts.slice(1).join(":");
                return [{
                    "label": "Show everything instead",
                    "icon": "auto_awesome_mosaic",
                    "action": () => {
                        return Catalog.setFilter(key, "");
                    }
                }, {
                    "label": `Fetch more ${value}`,
                    "icon": "travel_explore",
                    "action": () => {
                        Catalog.setFilter(key, value);
                        Catalog.searchSources();
                    }
                }];
            }

            function runExport(item, targetId) {
                if (!item)
                    return ;

                const target = Targets.byId(targetId);
                const after = target && target.after ? target.after : null;
                const verb = target && target.apply ? "Applying" : (after ? "Preparing" : "Exporting");
                Toast.show(`${verb} ${target ? target.label : targetId}…`);
                Catalog.remember("export", targetId, item.id);
                Catalog.exportItem(item, targetId, function(err, payload) {
                    if (err) {
                        Toast.error(`That did not work: ${err}`);
                        return ;
                    }
                    if (!after) {
                        const name = payload.path.split("/").pop();
                        Toast.show(`${name} · ${payload.human}`, "Show", function() {
                            Sys.showInFiles(payload.path);
                        });
                        return ;
                    }
                    // The picture itself, not its path.
                    // The page is offered rather than forced: opening a browser
                    // under someone who only wanted the file is rude.
                    const announce = () => {
                        return Toast.show(after.say || "Ready", after.open ? "Open" : "Show", function() {
                            if (after.open)
                                Sys.open(after.open);
                            else
                                Sys.showInFiles(payload.path);
                        });
                    };
                    if (after.copyImage)
                        Sys.copyImage(payload.path, "image/png", (ok) => {
                        return ok ? announce() : Toast.error("Exported, but could not copy — " + Sys.lastError);
                    });
                    else
                        announce();
                });
            }

            /*
             * ONE DOOR TO THE VIEWER.
             *
             * Every gallery opens a picture the same way, and where it opens is
             * a setting — over the wall, or in a window of its own — so the
             * choice lives here rather than in five click handlers.
             */
            function showMedia(index, item) {
                if (Prefs.mediaOwnWindow) {
                    mediaWindow.showAt(index, item);
                    return ;
                }
                detail.openAt(index, item);
            }

            anchors.fill: parent
            focus: true
            Component.onCompleted: {
                Shell.content = content;
                // Popups live here, outside the content item.
                Shell.overlay = Overlay.overlay;
                /*
                 * The three verbs a contributed layout acts through — see
                 * Host.openItem. Installed here because this is what owns the
                 * viewer, the menu and the export sheet.
                 */
                Host.openItem = (index, record) => content.showMedia(index, record);
                Host.itemMenu = (record, sceneX, sceneY) => menu.openFor(record, sceneX, sceneY);
                Host.exportItem = (record) => content.runExport(record, content.topTarget());
            }
            Keys.onPressed: (event) => {
                /*
                 * USER SCRIPTS GET FIRST REFUSAL — on a bare letter only.
                 *
                 * `@grant keys` exists because custom keybinds are the
                 * feature people install a userscript manager FOR. But a
                 * script must not be able to take Ctrl+F, Escape or the
                 * arrows: those are the app's, and a script that captured
                 * them would look like a broken app rather than a script.
                 * So: no modifiers, and only when nothing is being typed.
                 */
                if (Prefs.scriptsEnabled && event.modifiers === Qt.NoModifier && event.text.length === 1 && /[a-z0-9]/i.test(event.text)) {
                    if (Scripts.key(event.text.toLowerCase(), {
                        "item": Catalog.itemAt(0),
                        "query": Catalog.query,
                        "lens": Lenses.activeId
                    })) {
                        event.accepted = true;
                        return;
                    }
                }
                // `/` is the vim-ish one; Ctrl+F is the one everybody else
                // presses. Both mean "let me type a search".
                if (event.key === Qt.Key_Slash || (event.key === Qt.Key_F && (event.modifiers & Qt.ControlModifier))) {
                    search.focusField();
                    event.accepted = true;
                } else if ((event.modifiers & Qt.AltModifier) && event.key === Qt.Key_Left || event.key === Qt.Key_Back) {
                    Catalog.back();
                    event.accepted = true;
                } else if ((event.modifiers & Qt.AltModifier) && event.key === Qt.Key_Right || event.key === Qt.Key_Forward) {
                    Catalog.forward();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Escape && Catalog.similarTo) {
                    // Out of "like this" first: one step back, to where you were.
                    if (Catalog.canGoBack)
                        Catalog.back();
                    else
                        Catalog.clearSimilar();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Escape) {
                    // One key, one meaning at a time: the detail view handles
                    // its own Escape, so this only ever clears the query.
                    Catalog.query = "";
                    search.text = "";
                    content.forceActiveFocus();
                    event.accepted = true;
                }
            }

            // The mouse's own back and forward buttons, anywhere in the window.
            // Only those two buttons: every other press falls through untouched.
            MouseArea {
                anchors.fill: parent
                z: 1000
                acceptedButtons: Qt.BackButton | Qt.ForwardButton
                onPressed: (mouse) => {
                    if (Shell.detail && Shell.detail.open)
                        Shell.detail.close();
                    else if (mouse.button === Qt.BackButton)
                        Catalog.back();
                    else
                        Catalog.forward();
                }
            }

            FrameAnimation {
                id: frameClock

                running: true
                onTriggered: Perf.tick(frameClock.frameTime)
            }

            RowLayout {
                anchors.fill: parent
                spacing: 0

                NavRail {
                    id: rail

                    // Hidden for an immersive read — see headerRow below.
                    visible: !Host.chromeSuppressed
                    Layout.fillHeight: true
                    // Names and counts when there is room; a narrow window keeps
                    // the icons, so the pictures never lose their width to it.
                    expanded: Prefs.railExpanded && content.width >= 900
                    /*
                     * TOGGLE THE PREFERENCE, NOT THE VALUE THE WINDOW CLAMPED.
                     *
                     * `!rail.expanded` reads the clamped one, which is always
                     * false below 900px — so every click wrote `true` again and
                     * the rail did not move: the mark and the collapse button
                     * were dead controls that could not say why.
                     */
                    onToggleRequested: {
                        Prefs.railExpanded = !Prefs.railExpanded;
                        if (Prefs.railExpanded && content.width < 900)
                            Toast.show("Too narrow for names in the rail — the pictures keep the width");

                    }
                    onSettingsRequested: settingsPanel.show()
                    onSourcesRequested: filterPanel.toggle()
                    onHistoryPanelRequested: historyPanel.toggle()
                    onHistoryRequested: (from, x, y) => {
                        const at = from.mapToItem(content, x, y);
                        historyMenu.popupAt(at.x - 20, at.y);
                    }
                    /*
                     * A RIGHT-CLICK ON A LENS'S OWN RAIL ROW.
                     *
                     * The rows are the lens's — a subreddit, a chat, a board —
                     * so the menu is the lens's too: it answers `navMenu(id)`
                     * with what can be done to that row, and a lens that has
                     * nothing to offer simply gets no menu. Drawn out here
                     * rather than in the rail because a popup inside the rail
                     * would be clipped by it.
                     */
                    onRowMenuRequested: (from, id, x, y) => {
                        const rows = id.indexOf("app:") === 0 ? content.railMenu(id.slice(4)) : (() => {
                            const lens = Lenses.activeLens;
                            return lens && typeof lens.navMenu === "function" ? lens.navMenu(id) : [];
                        })();
                        if (!rows || rows.length === 0)
                            return ;

                        navRowMenu.rows = rows;
                        const at = from.mapToItem(content, x, y);
                        navRowMenu.popupAt(at.x, at.y);
                    }
                    // Above the content, which slides under its edge while it moves.
                    z: 2
                }

                ColumnLayout {
                    /*
                 * The query bar is the query. There is no chip row for it.
                 *
                 * Showing each typed token as a removable chip underneath the
                 * text that already contains it says the same thing twice and
                 * costs a row of the window — you delete a word by deleting the
                 * word. Only filters set *outside* the text get chips, below,
                 * because those are the ones the bar cannot show you.
                 */
                    /*
                 * There is no chip row, for anything.
                 *
                 * There was one for the filters set outside the query text —
                 * which was honest while such filters existed. They do not any
                 * more: picking a source types `source:pfps.gg` into the bar,
                 * so a chip underneath repeating it is the window saying the
                 * same thing twice, one line apart, with two ways to remove it.
                 */

                    id: mainColumn

                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 0
                    z: 1

                    /*
                 * The app bar: a heading, the search, and two buttons.
                 *
                 * It had eleven controls across it — six layouts, four verbs
                 * and an overflow — which is a toolbar you have to *read* every
                 * time you use it. The layouts collapse behind the one showing
                 * the current layout, the verbs that belong to a search moved
                 * into the search, and what is left is the thing you came to
                 * type in.
                 */
                    RowLayout {
                        id: headerRow

                        /*
                         * `Host.chromeSuppressed` — the immersive switch an
                         * extension could set and nothing obeyed.
                         *
                         * The point of a wall that reads itself is the pictures,
                         * and the search bar and the rail are neither pictures
                         * nor anything you touch while it runs.
                         */
                        visible: !Host.chromeSuppressed
                        Layout.fillWidth: true
                        Layout.margins: 14
                        Layout.bottomMargin: 8
                        spacing: 14

                        /*
                     * A WAY OUT WHERE THE APP'S OWN CHROME IS.
                     *
                     * Closing a lens meant finding "Back to quarry" in the rail
                     * — a row that is only there while the lens is, below the
                     * icons, and easy to miss entirely. The place people look
                     * for a way out of a thing is the top of it, next to what
                     * the thing is called, so that is where it now is. It only
                     * exists while a lens is open: a permanent close button for
                     * nothing is worse than none.
                     */
                        IconButton {
                            visible: Lenses.activeId.length > 0
                            icon: "close"
                            size: 34
                            tooltip: Lenses.activeEntry ? `Close ${Lenses.activeEntry.name} · Esc` : "Close the lens"
                            onClicked: Lenses.close()
                        }

                        ColumnLayout {
                            /*
                             * NOT BESIDE A LENS THAT NAMES ITSELF.
                             *
                             * This printed "Morse · SPAM Y LINKS" directly above
                             * the lens's own "SPAM Y LINKS · 53 messages". Two
                             * titles for one screen, the upper one less useful.
                             * See Lenses.skinDrawsChrome.
                             */
                            visible: !Lenses.skinDrawsChrome
                            Layout.preferredWidth: 200
                            spacing: 0

                            StyledText {
                                // Named the way the rail names it, so the heading and
                                // the highlighted row always say the same thing.
                                text: {
                                    // The lens is the place; its own screen is the line below.
                                    if (Lenses.activeId.length > 0 && Lenses.activeEntry)
                                        return Lenses.activeEntry.name;

                                    if (Catalog.similarTo) {
                                        const t = Catalog.similarTo.title && Catalog.similarTo.title.length > 0 ? Catalog.similarTo.title : Catalog.similarTo.slug;
                                        return `Like “${t}”`;
                                    }
                                    const collection = Catalog.filterValue("collection");
                                    if (collection.length > 0)
                                        return collection;

                                    const parts = [];
                                    if (Catalog.kind.length > 0)
                                        parts.push(rail.label(rail.kindMeta, Catalog.kind));

                                    if (Catalog.family.length > 0)
                                        parts.push(rail.label(rail.familyMeta, Catalog.family));

                                    /*
                                     * A SEARCH IS NOT "EVERYTHING".
                                     *
                                     * With words in the bar and no family or
                                     * kind picked, this printed "Everything"
                                     * above 3,412 results for `anime 4k` — the
                                     * heading naming the one thing the screen
                                     * was not. Only the free words: the
                                     * key:value and comparison tokens are the
                                     * filters, and those are what `parts` is.
                                     */
                                    const words = Catalog.query.split(/\s+/).filter((t) => {
                                        return t.length > 0 && !/[:<>=]/.test(t) && t.charAt(0) !== "-";
                                    }).join(" ");
                                    if (words.length > 0)
                                        parts.unshift(`“${words}”`);

                                    return parts.length > 0 ? parts.join(" · ") : "Everything";
                                }
                                font.pixelSize: Appearance.font.pixelSize.larger
                                font.weight: Font.DemiBold
                                color: Appearance.colors.colOnLayer0
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }

                            StyledText {
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                text: {
                                    if (Lenses.activeId.length > 0 && Lenses.activeEntry) {
                                        const screen = Lenses.activeLens ? Lenses.activeLens.screenTitle : "";
                                        return screen && screen !== Lenses.activeEntry.name ? screen : "a lens";
                                    }
                                    const n = Number(Catalog.count).toLocaleString(Qt.locale("en_US"), "f", 0);
                                    let line = `${n} ${Catalog.count === 1 ? "result" : "results"}`;
                                    if (Catalog.similarTo)
                                        line += " · Esc to go back";

                                    if (Catalog.findingSimilar)
                                        line += " · looking on the web…";

                                    /*
                                     * Fetch progress is NOT repeated here.
                                     *
                                     * This clause printed the same three
                                     * numbers as the Fetch pill and the line
                                     * under the bar, and in a 200px column it
                                     * elided to nothing by the second page — so
                                     * it changed the heading's width on every
                                     * page without ever being readable.
                                     */
                                    if (Catalog.loadingMore && Catalog.count === 0)
                                        line += " · searching…";
                                    else if (Catalog.exhausted)
                                        line += " · end";
                                    if (Catalog.unknownKeys.length > 0)
                                        line += ` · unknown: ${Catalog.unknownKeys.join(", ")}`;

                                    return line;
                                }
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: Catalog.unknownKeys.length > 0 ? Appearance.colors.colError : Appearance.colors.colSubtext
                            }

                        }

                        // The search is the widest thing in the window, because it
                        // is the thing the app is for.
                        //
                        //                     * The search takes the middle, and nothing competes for it.
                        //                     *
                        //                     * There was a `fillWidth` spacer after this, so two items
                        //                     * were asking for the same space and the search lost —
                        //                     * down to zero, which reads as "there is no search box"
                        //                     * rather than as a layout bug. The heading is a fixed
                        //                     * width and the two buttons are their own size, so the
                        //                     * search simply gets what is left, centred by the fixed
                        //                     * things on either side of it.
                        //
                        // A cell that takes all the spare width, with the bar
                        // centred inside it. `maximumWidth` on the bar itself capped
                        // the CELL, and the spare width piled up on the right.
                        Item {
                            // It searches 157 SOURCES. Inside a lens that has its
                            // own "Find a chat" it is two search fields, and the
                            // bigger one is the one that does not apply.
                            visible: !Lenses.skinDrawsChrome
                            Layout.fillWidth: true
                            Layout.minimumWidth: 280
                            implicitHeight: search.implicitHeight

                            QueryBar {
                                id: search

                                Component.onCompleted: Shell.queryBar = search
                                overlay: content
                                anchors.verticalCenter: parent.verticalCenter
                                x: Math.round((parent.width - width) / 2)
                                width: Math.min(parent.width, 680)
                                filterOpen: filterPanel.open
                                onFilterToggled: filterPanel.toggle()
                            }

                        }

                        /*
                     * FETCH MORE — THE CATALOGUE IS NOT THE INTERNET.
                     *
                     * "Wallpapers 56k" read as all the wallpapers there are;
                     * it is how many have been fetched so far, and wallhaven
                     * alone has millions. This is the way to go and get more of
                     * whatever is on screen: every enabled source, paged until
                     * each runs dry, with the tally live and a stop.
                     */
                        Rectangle {
                            id: fetchButton

                            // Fetches more of the CATALOGUE. A lens fetches its
                            // own pages, so in one this button is a promise the
                            // screen cannot keep.
                            visible: !Lenses.skinDrawsChrome

                            readonly property bool busy: Catalog.searching
                            readonly property bool hovered: fetchMouse.containsMouse
                            readonly property color fg: fetchButton.busy ? Appearance.colors.colOnPrimaryContainer : Appearance.colors.colOnSecondaryContainer

                            Layout.preferredHeight: 48
                            implicitHeight: 48
                            implicitWidth: fetchRow.implicitWidth + 36
                            // A tonal pill that squares off under the pointer and
                            // squeezes when pressed — the ii / M3 Expressive morph.
                            radius: fetchMouse.containsPress ? 12 : fetchButton.hovered ? 18 : 24
                            color: fetchButton.busy ? (fetchMouse.containsPress ? Appearance.colors.colPrimaryContainerActive : fetchButton.hovered ? Appearance.colors.colPrimaryContainerHover : Appearance.colors.colPrimaryContainer) : (fetchMouse.containsPress ? Appearance.colors.colSecondaryContainerActive : fetchButton.hovered ? Appearance.colors.colSecondaryContainerHover : Appearance.colors.colSecondaryContainer)

                            Row {
                                id: fetchRow

                                anchors.centerIn: parent
                                spacing: 10

                                Item {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 22
                                    height: 22

                                    MaterialSymbol {
                                        anchors.centerIn: parent
                                        text: fetchButton.busy && fetchButton.hovered ? "stop" : "travel_explore"
                                        iconSize: 22
                                        fill: fetchButton.busy ? 1 : 0
                                        color: fetchButton.fg
                                        // While it runs, the glyph gives way to the
                                        // ring — and comes back as Stop to reach for.
                                        opacity: !fetchButton.busy || fetchButton.hovered ? 1 : 0

                                        Behavior on opacity {
                                            NumberAnimation {
                                                duration: 150
                                            }

                                        }

                                    }

                                    Canvas {
                                        id: ring

                                        property color stroke: fetchButton.fg

                                        anchors.fill: parent
                                        visible: opacity > 0
                                        opacity: fetchButton.busy && !fetchButton.hovered ? 1 : 0
                                        onStrokeChanged: requestPaint()
                                        onPaint: {
                                            const g = getContext("2d");
                                            g.reset();
                                            g.lineWidth = 2.5;
                                            g.lineCap = "round";
                                            g.strokeStyle = ring.stroke;
                                            g.beginPath();
                                            g.arc(width / 2, height / 2, width / 2 - 2.5, 0, Math.PI * 1.4);
                                            g.stroke();
                                        }

                                        Behavior on opacity {
                                            NumberAnimation {
                                                duration: 150
                                            }

                                        }

                                        RotationAnimator on rotation {
                                            running: ring.visible
                                            from: 0
                                            to: 360
                                            duration: 850
                                            loops: Animation.Infinite
                                        }

                                    }

                                }

                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: -1

                                    StyledText {
                                        text: fetchButton.busy ? (fetchButton.hovered ? "Stop fetching" : `+${Number(Catalog.searchAdded).toLocaleString(Qt.locale("en_US"), "f", 0)} new`) : "Fetch more"
                                        font.pixelSize: Appearance.font.pixelSize.small
                                        font.weight: Font.DemiBold
                                        color: fetchButton.fg
                                    }

                                    StyledText {
                                        visible: fetchButton.busy
                                        text: `${Catalog.searchActive.length} source${Catalog.searchActive.length === 1 ? "" : "s"} · ${Catalog.searchPages} pages`
                                        font.pixelSize: Appearance.font.pixelSize.smallest
                                        color: fetchButton.fg
                                        opacity: 0.8
                                    }

                                }

                            }

                            MouseArea {
                                id: fetchMouse

                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (fetchButton.busy) {
                                        Catalog.stopSearch();
                                        Toast.show(`Stopped · ${Catalog.searchAdded} new pictures`);
                                    } else {
                                        Catalog.searchSources([]);
                                    }
                                }
                            }

                            StyledToolTip {
                                visible: fetchMouse.containsMouse
                                text: fetchButton.busy ? `Fetching page after page from every source · ${Catalog.searchPages} pages so far — click to stop` : "Fetch more of this from every source, until they run out"
                            }

                            Behavior on color {
                                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(fetchButton)
                            }

                            Behavior on radius {
                                NumberAnimation {
                                    duration: Appearance.animation.elementMoveFast.duration
                                    easing.type: Easing.OutCubic
                                }

                            }

                            Behavior on implicitWidth {
                                NumberAnimation {
                                    duration: Appearance.animDur(260)
                                    easing.type: Easing.OutCubic
                                }

                            }

                        }

                        // The view controls: one split control, not two loose circles.
                        Row {
                            spacing: 3

                            SegmentButton {
                                id: layoutButton

                                position: "first"
                                // Whatever the menu is actually driving — with
                                // History or a lens open this button was drawing
                                // the wall's icon over a menu that sets someone
                                // else's layout. And a tooltip reading "Layout"
                                // on a button whose only other signal is a 22px
                                // glyph leaves the current layout unnamed.
                                icon: layoutMenu.current.icon
                                tooltip: `Layout · ${layoutMenu.current.label}`
                                toggled: layoutMenu.visible
                                onClicked: {
                                    const at = mapToItem(content, width / 2, height);
                                    layoutMenu.popupAt(at.x - 180, at.y + 10);
                                }
                            }

                            SegmentButton {
                                id: settingsButton

                                position: "last"
                                icon: "more_vert"
                                tooltip: "More"
                                toggled: settingsMenu.visible
                                onClicked: {
                                    const at = mapToItem(content, width / 2, height);
                                    settingsMenu.popupAt(at.x - 240, at.y + 10);
                                }
                            }

                        }

                    }

                    /*
                 * WORK IN PROGRESS, SAID WITHOUT WORDS.
                 *
                 * Fetching and paging were a clause at the end of the subtitle
                 * — easy to miss, and it changed the heading's width as it came
                 * and went. A thin line under the bar moves while anything is
                 * on its way, the way a browser's does. It takes no layout
                 * height, so nothing below it jumps when it appears.
                 */
                    Item {
                        id: progressLine

                        // Saving counts as work: an export downloads the full
                        // original, which is the slowest thing the app does and
                        // was the one with nothing on screen to say so.
                        /*
                         * Fetching PICTURES counts as working too.
                         *
                         * The strip said nothing while a screenful of tiles was
                         * waiting on its thumbnails, so a wall of rows that had
                         * never been fetched looked exactly like a wall that had
                         * given up — see Catalog.thumbsInFlight.
                         */
                        readonly property bool working: Catalog.searching || Catalog.loadingMore || Catalog.loading || Catalog.findingSimilar || Catalog.exporting > 0 || Catalog.thumbsInFlight > 0

                        Layout.fillWidth: true
                        Layout.preferredHeight: 0

                        /*
                         * Drawn ON the card, not placed in the column above it.
                         * It was a zero-height row before CategoryStrip — true
                         * only while the strip, the offline bar and the damaged
                         * bar were all hidden. On a source page with categories
                         * the line hung a whole row clear of the card it says it
                         * is riding.
                         */
                        EdgeProgress {
                            parent: panel
                            width: panel.width
                            y: 0
                            // The card's own curve, so the strip's ends bend away
                            // exactly where its corners do.
                            radius: panel.radius
                            active: progressLine.working
                        }

                    }

                    CategoryStrip {
                        Layout.fillWidth: true
                        // The card's own edges. At 12 the strips sat ten pixels
                        // inside the panel they stack on, so the column stepped
                        // in and out between the heading and the pictures.
                        Layout.leftMargin: 2
                        Layout.rightMargin: 12
                        Layout.bottomMargin: visible ? 8 : 0
                    }

                    OfflineBar {
                        Layout.fillWidth: true
                        // The card's own edges. At 12 the strips sat ten pixels
                        // inside the panel they stack on, so the column stepped
                        // in and out between the heading and the pictures.
                        Layout.leftMargin: 2
                        Layout.rightMargin: 12
                        Layout.bottomMargin: visible ? 8 : 0
                    }

                    StaleBar {
                        Layout.fillWidth: true
                        // The card's own edges, like the strips either side.
                        Layout.leftMargin: 2
                        Layout.rightMargin: 12
                        Layout.bottomMargin: visible ? 8 : 0
                    }

                    DamagedBar {
                        Layout.fillWidth: true
                        // The card's own edges. At 12 the strips sat ten pixels
                        // inside the panel they stack on, so the column stepped
                        // in and out between the heading and the pictures.
                        Layout.leftMargin: 2
                        Layout.rightMargin: 12
                        Layout.bottomMargin: visible ? 8 : 0
                    }

                    // ── the content panel ────────────────────────────────────────
                    Rectangle {
                        id: panel

                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.leftMargin: 2
                        // Symmetric with leftMargin. The scrollbar does not live in
                        // here — it sits in the gutter beyond this edge, so the
                        // panel keeps its own margin and the pictures keep theirs.
                        Layout.rightMargin: 12
                        Layout.bottomMargin: 12
                        radius: Appearance.rounding.large
                        color: Appearance.colors.colLayer1
                        // `clip` still earns its place for the straight edges — it
                        // is the four CORNERS it cannot do, which RoundedCorners
                        // below handles. The border moved there too, so it is drawn
                        // over the mask rather than under the pictures.
                        clip: true

                        // Cuts the pictures back to the panel's curve, and draws
                        // the outline over the cut. See RoundedCorners.
                        RoundedCorners {
                            radius: panel.radius
                            background: Appearance.colors.colLayer0Base
                        }

                        /*
                     * A lens draws where the pictures do.
                     *
                     * It filled the window before, over the rail and the
                     * header — so opening one read as a popup that had taken
                     * the app over rather than a view inside it. In the panel
                     * it keeps quarry's frame: the rail, the search and the
                     * card's own curve.
                     */
                        ExtensionHost {
                            anchors.fill: parent
                            z: 70
                        }

                        GalleryWall {
                            id: wall

                            // Whichever view is on screen is the one `perf geometry`
                            // describes — see services/Ipc.qml.
                            onVisibleChanged: {
                                if (visible) {
                                    Shell.gallery = wall;
                                }
                            }
                            // …and at startup, when `visible` never changes because it
                            // was already true.
                            Component.onCompleted: {
                                Perf.geometry = wall.geometry;
                                if (visible)
                                    Shell.gallery = wall;

                            }
                            // Nothing behind a modal overlay should react to input.
                            enabled: !detail.open
                            anchors.fill: parent
                            anchors.margins: 8
                            anchors.bottomMargin: 8
                            bottomInset: content.dockInset
                            visible: !content.lensUp && Prefs.layoutMode === "wall"
                            onActivated: (it, index) => {
                                Catalog.remember("open", "", it ? it.id : "");
                                // The record, not just its offset: the offset can
                                // already mean a different row by the time the
                                // viewer resolves it.
                                content.showMedia(index, it);
                            }
                            onContextRequested: (it, sx, sy) => {
                                return menu.openFor(it, sx, sy);
                            }
                            onQuickExport: (it) => {
                                return content.runExport(it, content.topTarget());
                            }
                            onQuickAction: (it, id) => {
                                return content.tileAction(it, id);
                            }
                        }

                        GalleryGrid {
                            id: grid

                            // Whichever view is on screen is the one `perf geometry`
                            // describes — see services/Ipc.qml.
                            onVisibleChanged: {
                                if (visible) {
                                    Shell.gallery = grid;
                                }
                            }
                            // …and at startup, when `visible` never changes because it
                            // was already true.
                            Component.onCompleted: {
                                if (visible) {
                                    Shell.gallery = grid;
                                }
                            }
                            // Nothing behind a modal overlay should react to input.
                            enabled: !detail.open
                            anchors.fill: parent
                            anchors.margins: 8
                            anchors.bottomMargin: content.dockInset
                            // The contact sheet is this layout with the metadata off
                            // and the tiles small — a density, not a different view.
                            visible: !content.lensUp && Prefs.layoutMode === "grid" || Prefs.layoutMode === "sheet"
                            tileSize: Prefs.layoutMode === "sheet" ? 96 : Prefs.gridTileSize
                            onActivated: (it, index) => {
                                Catalog.remember("open", "", it ? it.id : "");
                                // The record, not just its offset: the offset can
                                // already mean a different row by the time the
                                // viewer resolves it.
                                content.showMedia(index, it);
                            }
                            onContextRequested: (it, sx, sy) => {
                                return menu.openFor(it, sx, sy);
                            }
                            onQuickExport: (it) => {
                                return content.runExport(it, content.topTarget());
                            }
                            onQuickAction: (it, id) => {
                                return content.tileAction(it, id);
                            }
                        }

                        GalleryCompact {
                            id: compact

                            // Whichever view is on screen is the one `perf geometry`
                            // describes — see services/Ipc.qml.
                            onVisibleChanged: {
                                if (visible) {
                                    Shell.gallery = compact;
                                }
                            }
                            // …and at startup, when `visible` never changes because it
                            // was already true.
                            Component.onCompleted: {
                                if (visible) {
                                    Shell.gallery = compact;
                                }
                            }
                            // Nothing behind a modal overlay should react to input.
                            enabled: !detail.open
                            anchors.fill: parent
                            anchors.margins: 8
                            anchors.bottomMargin: content.dockInset
                            visible: !content.lensUp && Prefs.layoutMode === "compact"
                            onActivated: (it, index) => {
                                Catalog.remember("open", "", it ? it.id : "");
                                // The record, not just its offset: the offset can
                                // already mean a different row by the time the
                                // viewer resolves it.
                                content.showMedia(index, it);
                            }
                            onContextRequested: (it, sx, sy) => {
                                return menu.openFor(it, sx, sy);
                            }
                            onQuickExport: (it) => {
                                return content.runExport(it, content.topTarget());
                            }
                            onQuickAction: (it, id) => {
                                return content.tileAction(it, id);
                            }
                        }

                        GalleryCompare {
                            id: compare

                            // Whichever view is on screen is the one `perf geometry`
                            // describes — see services/Ipc.qml.
                            onVisibleChanged: {
                                if (visible) {
                                    Shell.gallery = compare;
                                }
                            }
                            // …and at startup, when `visible` never changes because it
                            // was already true.
                            Component.onCompleted: {
                                if (visible) {
                                    Shell.gallery = compare;
                                }
                            }
                            // Nothing behind a modal overlay should react to input.
                            enabled: !detail.open
                            anchors.fill: parent
                            anchors.margins: 8
                            anchors.bottomMargin: content.dockInset
                            visible: !content.lensUp && Prefs.layoutMode === "compare"
                            onActivated: (it, index) => {
                                Catalog.remember("open", "", it ? it.id : "");
                                // The record, not just its offset: the offset can
                                // already mean a different row by the time the
                                // viewer resolves it.
                                content.showMedia(index, it);
                            }
                            onContextRequested: (it, sx, sy) => {
                                return menu.openFor(it, sx, sy);
                            }
                            // Keeping one is an export: the same flow the tiles use,
                            // so "keep" and "export" can never mean two things.
                            onQuickExport: (it) => {
                                return content.runExport(it, content.topTarget());
                            }
                        }

                        GalleryContext {
                            id: inContext

                            // Whichever view is on screen is the one `perf geometry`
                            // describes — see services/Ipc.qml.
                            onVisibleChanged: {
                                if (visible) {
                                    Shell.gallery = inContext;
                                }
                            }
                            // …and at startup, when `visible` never changes because it
                            // was already true.
                            Component.onCompleted: {
                                if (visible) {
                                    Shell.gallery = inContext;
                                }
                            }
                            // Nothing behind a modal overlay should react to input.
                            enabled: !detail.open
                            anchors.fill: parent
                            anchors.margins: 8
                            anchors.bottomMargin: content.dockInset
                            visible: !content.lensUp && Prefs.layoutMode === "context"
                            onActivated: (it, index) => {
                                Catalog.remember("open", "", it ? it.id : "");
                                // The record, not just its offset: the offset can
                                // already mean a different row by the time the
                                // viewer resolves it.
                                content.showMedia(index, it);
                            }
                            onContextRequested: (it, sx, sy) => {
                                return menu.openFor(it, sx, sy);
                            }
                            // Each mock exports to its own slot rather than to the
                            // last-used target: the point of the preview is that
                            // *this* is the target.
                            onExportRequested: (it, targetId) => {
                                return content.runExport(it, targetId);
                            }
                        }

                        /*
                         * A LAYOUT AN EXTENSION ADDED — the seventh slot.
                         *
                         * `Host.registerLayout` has existed since the extension
                         * API landed and drew nothing, because the six layouts
                         * above are written into this file by name. One Loader
                         * closes that: the registered component fills the
                         * picture area, is picked by `Prefs.layoutMode` like any
                         * other, and acts on items through the three verbs on
                         * Host rather than reaching in here.
                         */
                        Loader {
                            id: extLayout

                            readonly property var spec: Host.layouts.find(l => l && l.id === Prefs.layoutMode && l.component) || null

                            active: !content.lensUp && extLayout.spec !== null
                            sourceComponent: extLayout.active ? extLayout.spec.component : null
                            visible: extLayout.active
                            enabled: !detail.open
                            anchors.fill: parent
                            anchors.margins: 8
                            anchors.bottomMargin: content.dockInset

                            // A contributed layout that scrolls gets autoscroll
                            // and keyboard navigation for nothing; one that does
                            // not simply never claims. See Host.claimView.
                            function publish() {
                                const it = extLayout.item;
                                if (extLayout.visible && it && it.contentHeight !== undefined)
                                    Host.claimView(it, extLayout);
                                else
                                    Host.releaseView(extLayout);
                            }

                            onLoaded: {
                                if (extLayout.item && extLayout.item.bottomInset !== undefined)
                                    extLayout.item.bottomInset = content.dockInset;
                                if (extLayout.visible)
                                    Shell.gallery = extLayout.item;
                                extLayout.publish();
                            }
                            onVisibleChanged: extLayout.publish()
                        }

                        EmptyState {
                            anchors.fill: parent
                            z: 5
                            onSearchEverywhere: settingsMenu.searchRequested()
                            onRetry: {
                                Catalog.load();
                                Catalog.filterNow();
                            }
                        }

                        LoadingIndicator {
                            anchors.centerIn: parent
                            visible: Catalog.loading
                        }

                        // ── the budget, live, in the corner — when asked for ─────
                        Rectangle {
                            visible: Prefs.showStats
                            anchors.left: parent.left
                            anchors.bottom: parent.bottom
                            anchors.margins: 10
                            width: stats.implicitWidth + 20
                            height: stats.implicitHeight + 12
                            radius: Appearance.rounding.small
                            color: Appearance.colors.colLayer0Base
                            opacity: 0.85

                            StyledText {
                                id: stats

                                anchors.centerIn: parent
                                font.family: Appearance.font.family.monospace
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                color: content.fps >= 55 ? Appearance.colors.colSubtext : Appearance.colors.colError
                                text: `${content.fps} fps · ${Perf.rssMbText} · decode ${ThumbGate.inFlight}/${ThumbGate.maxInFlight} · served ${ThumbGate.served}` + (ThumbGate.leaked > 0 ? ` · reclaimed ${ThumbGate.leaked}` : "")
                            }

                        }

                    }

                    /*
                 * The content is already laid out at its final width; this
                 * carries it from where the rail's edge WAS to where it is,
                 * as a GPU transform. Zero whenever nothing is moving.
                 */
                    transform: Translate {
                        x: Math.round(rail.visualWidth - rail.implicitWidth)
                    }

                }

            }

            ItemContextMenu {
                id: menu

                Component.onCompleted: Shell.itemMenu = menu
                onOpenRequested: (it) => {
                    // indexOfId only knows the pages in hand; a picture from a
                    // page since evicted still opens, on the record itself.
                    const at = Catalog.indexOfId ? Catalog.indexOfId(it.id) : -1;
                    content.showMedia(at, it);
                }
                onCopyRequested: (it, what) => {
                    return content.copyItem(it, what);
                }
                onPageRequested: (it, where) => {
                    return content.openItem(it, where);
                }
                onHideRequested: (it) => {
                    return Catalog.hideItem(it);
                }
                onWallpaperRequested: (it, monitorTarget) => {
                    return content.setWallpaper(it, monitorTarget);
                }
                onKeepRequested: (it) => {
                    return collectionSheet.openFor(it);
                }
                onSimilarRequested: (it, method) => {
                    return Catalog.findSimilar(it, false, method || "all");
                }
                onSearchRequested: (token) => {
                    return Catalog.query = token;
                }
                onExportRequested: (it, targetId) => {
                    return content.runExport(it, targetId);
                }
                //
                //                 * Adding to a board OPENS it, and switches to it.
                //                 *
                //                 * Putting something somewhere you cannot see is indistinguish-
                //                 * able from nothing happening — and the board is a place, so
                //                 * going there is the honest confirmation. The layout switch is
                //                 * what makes "add to board" feel like an action rather than a
                //                 * filing operation.
                //
                //
                //                 * The board is its own application, so this WRITES and says so
                //                 * rather than navigating: quarry has nowhere to show a board,
                //                 * and switching to a view that does not exist here would be a
                //                 * worse answer than a sentence.
                //
                onBoardRequested: (it, name) => {
                    if (!it)
                        return ;

                    Catalog.placeOnBoardNamed(name, it);
                }
                onTargetsRequested: (it) => {
                    targetSheet.openFor(it);
                }
            }

            // The harness drives whatever is on screen, not whatever was built
            // first — measuring the hidden layout is measuring nothing.
            Binding {
                target: Perf
                property: "wall"
                value: {
                    switch (Prefs.layoutMode) {
                    case "wall":
                        return wall;
                    case "compact":
                        return compact;
                    case "compare":
                        return compare;
                    case "context":
                        return inContext;
                    default:
                        return grid; // grid and the contact sheet are one view
                    }
                }
            }

            HistoryPanel {
                id: historyPanel

                Component.onCompleted: Shell.historyPanel = historyPanel
                anchors.fill: parent
                z: 91
            }

            FilterPanel {
                id: filterPanel

                Component.onCompleted: Shell.filterPanel = filterPanel
                anchors.fill: parent
                z: 95
            }

            HistoryMenu {
                id: historyMenu
            }

            NavRowMenu {
                id: navRowMenu

                Component.onCompleted: {
                    Shell.navRowMenu = navRowMenu;
                    Shell.railMenuFor = content.railMenu;
                }
            }

            LayoutMenu {
                id: layoutMenu

                Component.onCompleted: Shell.layoutMenu = layoutMenu
                /*
                 * Sorting lives in the query, so a layout's own sort is written
                 * there — the same token the bar takes when you type it. That
                 * keeps one source of truth for what is being asked, and the
                 * sort a layout prefers stays visible and editable rather than
                 * being a hidden second opinion.
                 */
                onSortRequested: (token) => {
                    return Catalog.step(() => {
                        return Catalog.setFilter("sort", token);
                    });
                }
            }

            // Switching layout applies whatever sort that layout keeps. A blank
            // one means "leave the query alone", which is the default.
            Connections {
                function onLayoutModeChanged() {
                    const want = Prefs.layoutSettings(Prefs.layoutMode).sort || "";
                    if (want.length > 0)
                        Catalog.setFilter("sort", want);

                }

                target: Prefs
            }

            SettingsMenu {
                // every enabled source, as deep as they go

                id: settingsMenu

                Component.onCompleted: Shell.settingsMenu = settingsMenu
                onSettingsRequested: settingsPanel.show()
                onReloadRequested: {
                    Catalog.load();
                    Catalog.filterNow();
                    Toast.show("Catalogue reloaded");
                }
                onCacheRequested: Sys.open(Quickshell.env("HOME") + "/.cache/quarry/thumbs")
                onRestoreRequested: Catalog.restoreHidden()
                onSearchRequested: {
                    Toast.show("Searching every source…");
                    /*
                     * Which sources "search everything" means.
                     *
                     * Not every source that exists: the adult boards are opt-in
                     * by name, and a source that needs credentials is skipped
                     * by the daemon anyway. This is the SFW set, in rough order
                     * of how likely it is to have what you typed.
                     */
                    Catalog.searchSources([]);
                }
                onPaletteRequested: {
                    const accent = Appearance.m3colors.primary;
                    search.text = `color:${accent} dist<30 sort:random`;
                    Catalog.query = search.text;
                    Toast.show(`Matching ${accent}`);
                }
                onSurpriseRequested: {
                    search.text = "sort:random";
                    Catalog.query = search.text;
                }
            }

            DetailView {
                id: detail

                anchors.fill: parent
                z: 80
                Component.onCompleted: Shell.detail = detail
                // The main window can fill the screen too — the viewer does not
                // have to be in a window of its own to be looked at properly.
                fullscreen: win.fullscreen
                onFullscreenToggled: win.fullscreen = !win.fullscreen
                onWindowRequested: {
                    const at = detail.index;
                    const it = detail.shown;
                    detail.close();
                    if (win.fullscreen)
                        win.fullscreen = false;

                    mediaWindow.showAt(at, it);
                }
                onExportRequested: (it, targetId) => {
                    return content.runExport(it, targetId);
                }
                onTargetsRequested: (it) => {
                    return exportSheet.openFor(it, content.topTarget());
                }
                /*
                 * Set as wallpaper: export at that monitor's real pixel size,
                 * then hand the file to the desktop's own switcher — which is
                 * what regenerates the palette, so the app recolours along with
                 * everything else.
                 */
                onWallpaperRequested: (it, monitorTarget) => {
                    return content.setWallpaper(it, monitorTarget);
                }
                onCopyRequested: (it, what) => {
                    return content.copyItem(it, what);
                }
                onOpenRequested: (it, where) => {
                    return content.openItem(it, where);
                }
                onKeepRequested: (it) => {
                    return collectionSheet.openFor(it);
                }
                onHideRequested: (it) => {
                    if (!it)
                        return ;

                    detail.close();
                    Catalog.hideItem(it);
                }
                onSimilarRequested: (it, method) => {
                    if (!it)
                        return ;

                    /*
                     * ALWAYS THE REAL THING.
                     *
                     * This fell back to a colour query whenever the row had
                     * no perceptual hash yet — which is most rows — so "Find
                     * similar" usually meant "same dominant colour". The
                     * daemon measures a picture on demand, and asks Yandex for
                     * look-alikes from the web too, so it is always asked.
                     */
                    Catalog.findSimilar(it, false, method || "all");
                    detail.close();
                }
            }

            /*
             * The source page, over the gallery.
             *
             * Above the viewer (a page opened FROM the viewer has to cover it)
             * and below the sheets, which are dialogs about one picture and
             * belong on top of whatever is being read.
             */
            BrowserView {
                id: browser

                anchors.fill: parent
                z: 88
                Component.onCompleted: Shell.browser = browser
            }

            SettingsPanel {
                id: settingsPanel

                /*
                 * A PEER OF THE OTHER SHEETS.
                 *
                 * This had no `z` at all, so it sat at 0 while the filter panel
                 * is 95, the collection sheet 93, the export sheet 92 and the
                 * extension host 70 — which is declared AFTER it and therefore
                 * drew straight over the top of it. Settings was the only
                 * overlay in the window that anything else could cover.
                 */
                z: 94
                onSearchRequested: {
                    Toast.show("Searching every source…");
                    Catalog.searchSources([]); // every enabled source, as deep as they go
                }
                onCacheRequested: Sys.open(Quickshell.env("HOME") + "/.cache/quarry/thumbs")
                Component.onCompleted: Shell.settingsPanel = settingsPanel
            }

            CollectionSheet {
                id: collectionSheet

                anchors.fill: parent
                z: 93
            }

            ExportSheet {
                id: exportSheet

                anchors.fill: parent
                z: 92
                Component.onCompleted: Shell.exportSheet = exportSheet
            }

            TargetSheet {
                id: targetSheet

                anchors.fill: parent
                z: 90
                onChosen: (it, targetId) => {
                    return content.runExport(it, targetId);
                }
            }

            /*
             * THE SCRIPT DOCKS.
             *
             * Above the pictures rather than in the column with them: a dock
             * is switched on while you are in the middle of something, and
             * given a row of its own it would reflow the page you are reading
             * every time one appeared. Stacked upward from the bottom so the
             * snackbar keeps the last word.
             */
            Row {  // docks side by side, as LensHost draws them
                id: wallDocks
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                /*
                 * Tucked to the edge rather than floating a thumbnail's height
                 * above it. 76 put the strip across the middle of the bottom
                 * row of pictures; this leaves it clear of the panel's rounded
                 * corner and covers the gap instead of the wall.
                 */
                /*
                 * HIGHER WHILE A PICTURE IS OPEN.
                 *
                 * 20 is right over the wall — clear of the panel's rounded
                 * corner, covering the gap rather than the pictures. It is
                 * wrong over the viewer, where the bottom of the window is
                 * already the player's own row of controls: scrub bar, time,
                 * volume. A dock sitting on top of those is a dock you have to
                 * move the mouse around.
                 *
                 * It no longer has to clear the viewer's controls by being
                 * lifted above them — an earlier attempt typed 96 here and
                 * landed inside a panel 108 tall, sitting across the scrub
                 * bar. Docks that belong over a viewer are now drawn inside
                 * those controls instead, and the rest are hidden while a
                 * picture is open, so this is only ever a margin over the
                 * wall.
                 */
                anchors.bottomMargin: 20
                spacing: 8
                z: 110

                Behavior on anchors.bottomMargin {
                    NumberAnimation {
                        duration: Appearance.animDur(180)
                        easing.type: Easing.OutCubic
                    }
                }
                /*
                 * A dock belongs over the PICTURES, not over a sheet that has
                 * taken the window. Settings and the source drawer are modal —
                 * a strip of script controls floating across them is the
                 * overlay not being an overlay. The viewer is deliberately not
                 * in this list: a slideshow's controls are wanted precisely
                 * while a picture is open.
                 */
                visible: !(settingsPanel && settingsPanel.open) && !(filterPanel && filterPanel.open)

                Repeater {
                    /*
                     * Docks that drive the WALL drop out while a picture is
                     * open — see `overViewer` in Scripts.qml. Filtered here per
                     * dock rather than by hiding the whole strip, because
                     * autoplay's controls are about the open picture and are
                     * wanted exactly then.
                     */
                    /*
                     * Nothing floats over an open picture any more.
                     *
                     * Docks that apply to the viewer are drawn INSIDE the video
                     * controls now (see VideoView), so showing them here as
                     * well would be two copies of the same switch disagreeing
                     * about where they live. Docks for the wall drop out while
                     * a picture is open, as they always did.
                     */
                    /*
                     * Nothing floats over an open picture or an open lens.
                     *
                     * Both of those draw the docks inside their own chrome now
                     * — the player in its control bar, a lens in its surface —
                     * so showing them here as well would be two copies of the
                     * same switch, in two places, disagreeing about which is
                     * the real one. This strip is for the wall, and only when
                     * the wall is what you are looking at.
                     */
                    model: Scripts.revision >= 0 && Prefs.scriptsEnabled
                        && !(detail && detail.open) && Lenses.activeId.length === 0
                        ? Scripts.openDocks() : []

                    delegate: ScriptDock {
                        required property var modelData

                        dock: modelData
                    }

                }

            }

            // Feedback belongs where the eye already is, and an export is the
            // one action here with a result worth reporting: a path.
            Snackbar {
                /*
                 * Spans the window, rather than being centred with no width.
                 *
                 * It sizes its bar from its own width — anchored by centre
                 * alone that width is zero, the background computes to a
                 * negative width and disappears, and every toast rendered as
                 * bare text floating over the gallery.
                 */
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                // Above the docks while any show, never across their buttons.
                anchors.bottomMargin: wallDocks.visible && wallDocks.height > 0 ? wallDocks.anchors.bottomMargin + wallDocks.height + 10 : 24
                z: 120
            }

        }

    }
    /*
     * THE VIEWER'S OWN WINDOW.
     *
     * Built whether or not the setting is on — it costs nothing until
     * `showAt` is called, and building it on demand would put the first
     * picture behind a window creation.
     *
     * The sheets it opens (export targets, collections) belong to the main
     * window: they are dialogs about one picture, and there is one of each.
     */

    MediaWindow {
        id: mediaWindow

        Component.onCompleted: Shell.mediaWindow = mediaWindow
        onExportRequested: (it, targetId) => {
            return content.runExport(it, targetId);
        }
        onTargetsRequested: (it) => {
            return exportSheet.openFor(it, content.topTarget());
        }
        onWallpaperRequested: (it, monitorTarget) => {
            return content.setWallpaper(it, monitorTarget);
        }
        onCopyRequested: (it, what) => {
            return content.copyItem(it, what);
        }
        onOpenRequested: (it, where) => {
            return content.openItem(it, where);
        }
        onKeepRequested: (it) => {
            return collectionSheet.openFor(it);
        }
        onHideRequested: (it) => {
            if (!it)
                return ;

            mediaWindow.hide();
            Catalog.hideItem(it);
        }
        onSimilarRequested: (it, method) => {
            if (!it)
                return ;

            Catalog.findSimilar(it, false, method || "all");
            mediaWindow.hide();
        }
    }

}
