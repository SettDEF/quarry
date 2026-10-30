import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
// Prefs lives in qs.modules.common and needs the import; the singletons in
// qs.services resolve without one because they are this file's own directory.
// Without it `ipc call app layout <name>` threw "Prefs is not defined" and
// answered with an empty line, which reads exactly like a handler that worked.
import qs.modules.common
pragma Singleton

/*
 * IPC, from Phase 0 rather than Phase 9, for a practical reason: on this
 * machine a test must not raise a window — that steals focus from whatever is
 * fullscreen. So the perf harness is driven from a terminal:
 *
 *   qs -c quarry ipc call perf scale 1000
 *   qs -c quarry ipc call perf report
 *   qs -c quarry ipc call catalog query "kind:wallpaper"
 */
Singleton {
    /// The two things a screenshot keeps catching: a control that is
    /// present, correct and far too small to see.
    //         * EVERY MEASURABLE FACT, AS JSON, WITH NO SIDE EFFECTS.
    //         *
    //         * The other probes here are prose, written one at a time to chase one
    //         * bug each, and several of them TOGGLE the thing they measure — fine
    //         * for a person at a terminal, useless for a test that has to run the
    //         * same way twice.
    //         *
    //         * This exists because every UI defect this session was found by eye and
    //         * every one of them was a NUMBER: a search bar 4px wide, a filter panel
    //         * 70px tall holding 73 rows, a dropdown 900px from its field, a panel
    //         * listing 0 of 29 sources, a text field whose clickable band was 20px
    //         * of a 46px control. None of that needs judgement. It needs an assert.
    // Where media opens, and what that window is doing — the only
    // way to check the second window without looking at a screen.
    // Read, never toggled: a probe that opens a panel to measure it
    // cannot be run twice in a row and cannot run while you work.
    // What the last filter change actually cost, split.
    // Empty because it is empty, or empty because the file is
    // broken — the probe has to be able to tell them apart too.
    //         * THE WINDOW, AS A PICTURE, FROM THE INSIDE.
    //         *
    //         * A screenshot of the real screen captures whatever is actually there —
    //         * which has repeatedly been someone's private window, not this one.
    //         * The scene graph grabbing its own content item cannot be anything but
    //         * quarry, and it works offscreen, so a headless instance can be looked
    //         * at while the person at the machine carries on.
    //         * Toggle the rail and measure the animation, frame by frame.
    //         *
    //         * Smoothness is a number: the worst frame and how many missed the
    //         * display's budget while the rail moved. Answers after the tween ends.
    //         * What a lens has SAVED against what it is HOLDING.
    //         *
    //         * The two disagreeing is the shape of a settings bug — a lens
    //         * instantiated before its state file had been read holds defaults and
    //         * writes them back over the real ones — so a probe has to report both,
    //         * not one.
    // Drive the crop tool from a terminal: open it, move the box, export.
    //         * No default arguments: QML rejects a default value on an annotated
    //         * parameter outright ("type annotations are not supported"), and the
    //         * whole config fails to load — so a status call gets its own function
    //         * rather than a dummy second argument.
    /// Which packs ship mockups, and which of them are actually drawing —
    /// the two are different, and only the second one proves the seam works.
    //         * The boards this catalogue holds, and what quarry can do with them.
    //         *
    //         * quarry has no canvas — the board is its own application — so this
    //         * reports the shared state rather than a view: what exists, and whether
    //         * the last "add to a board" actually landed.
    // WHY IS IT BLANK. Everything else here counts events; this reports the
    // sizes the view is actually laying out into. A width or height that
    // has collapsed draws nothing while every counter still looks healthy.
    //         * WHY DOES IT LOOK LIKE THAT.
    //         *
    //         * Every other counter here records events — frames drawn, tiles made,
    //         * pages asked for. None of them can describe a view that is laying out
    //         * correctly into nothing, which is exactly the failure that is hardest
    //         * to see and hardest to guess at: a zero-height column with a zero-count
    //         * model draws no pixels, reports no blanks and raises no error, and the
    //         * event counters all stay healthy while the screen stays empty.
    //         *
    //         * So this reports STATE: the sizes and counts the visible view is
    //         * actually working from. Optional fields are omitted rather than faked,
    //         * because a view that has no columns should say nothing about columns.
    // What the app thinks you are filling. A result that does not
    // match the dock is a bug you can otherwise only see by eye.
    // What the Storage page is showing, so "it says 3 GB" can
    // be checked without a screenshot of a panel.
    // A whitelist, not a fallback chain: `layout compre` silently landing
    // on the wall is a test that measures the wrong view and says nothing.
    //         * THE SAME PATH THE MENU TAKES, so a probe can check the thing a
    //         * person actually presses rather than a parallel one that happens to
    //         * work. A lens that declares layouts owns this while it is open.

    id: root

    /*
     * The window itself, and the entry points the launcher uses.
     *
     * A desktop action ("Wallpapers", "Avatars") is just this app opened on a
     * query, so the launcher shells out to `quarry --query …`, which either
     * starts the app with that query or hands it to the instance already
     * running.
     */
    property Timer railTimer
    property IpcHandler _app
    property IpcHandler _perf
    property IpcHandler _catalog

    railTimer: Timer {
        interval: 450
        onTriggered: Perf.endMeasure()
    }

    _app: IpcHandler {
        // SAY WHEN IT DID NOT OPEN. This threw the answer away and returned
        // "open" either way, so a windowless instance reported success and the
        // launcher believed it. `qs ipc call` exits 0 regardless, so the string
        // is the only signal there is — it should at least be true.
        function open() : string {
            return Shell.present() ? "open" : "no window";
        }

        /// Open the viewer on a result row — the same door a click uses, so the
        /// second window and the fullscreen setting can be checked without a
        /// screen to look at.
        // Not `show`: that is one of `qs ipc`'s own subcommands, and the CLI
        // refuses to pass an argument to a function with that name.
        function view(at: string) : string {
            const index = Math.max(0, parseInt(at || "0", 10) || 0);
            const item = Catalog.itemAt(index);
            if (!item)
                return `no row at ${index}`;

            if (!Shell.content || !Shell.content.showMedia)
                return "no content";

            Shell.content.showMedia(index, item);
            return `showing ${item.id}`;
        }

        /// Put the viewer away, wherever it opened.
        function unview() : string {
            if (Shell.mediaWindow && Shell.mediaWindow.visible) {
                Shell.mediaWindow.hide();
                return "closed the media window";
            }
            if (Shell.detail && Shell.detail.open) {
                Shell.detail.close();
                return "closed the viewer";
            }
            return "nothing open";
        }

        /// Move what is open into a window of its own — the viewer's own
        /// "open in its own window" button, from a terminal.
        function detach() : string {
            if (!Shell.detail || !Shell.detail.open)
                return "nothing open";

            Shell.detail.windowRequested();
            return "moved to its own window";
        }

        function fullscreen() : string {
            const w = Shell.mediaWindow;
            if (w && w.visible) {
                w.toggleFullscreen();
                return w.fullscreen ? "fullscreen" : "windowed";
            }
            // The main window fills the screen too; the viewer does not have to
            // be detached for this to mean something.
            const main = Shell.window;
            if (!main)
                return "no window";

            main.fullscreen = !main.fullscreen;
            return main.fullscreen ? "fullscreen" : "windowed";
        }

        function toggle() : string {
            return Shell.toggle() ? "shown" : "hidden";
        }

        function query(q: string) : string {
            // A query is an instruction to show that query, "like this" or not.
            Catalog.clearSimilar();
            Catalog.query = q || "";
            const shown = Shell.present();
            return `${shown ? "open" : "no window"} on: ${q}`;
        }

        /// Set one preference as the Settings screen would: `app pref autoplayThreshold 100`.
        /// The value is read as JSON when it parses (numbers, true/false), else as text.
        function pref(key: string, value: string) : string {
            if (!(key in Prefs) || typeof Prefs[key] === "function")
                return `no preference called ${key}`;
            let next = value;
            try {
                next = JSON.parse(value);
            } catch (e) {}
            const before = Prefs[key];
            Prefs[key] = next;
            return `${key}: ${JSON.stringify(before)} -> ${JSON.stringify(Prefs[key])}`;
        }

        function layout(mode: string) : string {
            /*
             * Through the MENU's own function where there is one, so this
             * probe exercises the thing a person presses rather than a
             * parallel path that happens to work.
             */
            if (Shell.layoutMenu && Shell.layoutMenu.lensDriving) {
                Shell.layoutMenu.choose(mode);
                const driven = Shell.layoutMenu.lens;
                const owner = Shell.historyPanel && Shell.historyPanel.open ? "history" : (Lenses.activeId.length > 0 ? Lenses.activeId : "screen");
                return `${owner} layout ${driven ? driven.layout : "?"} (through the menu)`;
            }
            const lens = Lenses.activeId.length > 0 ? Lenses.instanceOf(Lenses.activeId) : null;
            const lensLayouts = lens && lens.layouts ? lens.layouts : [];
            if (lensLayouts.length > 0) {
                if (!lensLayouts.some((l) => {
                    return l.id === mode;
                }))
                    return `${Lenses.activeId} has no layout ${mode} — it has ${lensLayouts.map(l => l.id).join(", ")}`;

                if (typeof lens.setLayout !== "function")
                    return `${Lenses.activeId} offers layouts but has no setLayout()`;

                lens.setLayout(mode);
                return `${Lenses.activeId} layout ${lens.layout}`;
            }
            // The app's six, plus whatever an extension registered — the menu
            // already offers those, and a harness that cannot reach them cannot
            // test them.
            const known = ["wall", "grid", "sheet", "compact", "compare", "context"].concat(Host.layouts.filter(l => l && l.id).map(l => l.id));
            if (known.indexOf(mode) < 0)
                return `unknown layout: ${mode} (${known.join(", ")})`;

            Prefs.layoutMode = mode;
            return `layout ${Prefs.layoutMode}`;
        }

        // Open the detail view on a result index, so the view can be exercised
        // without a pointer.
        function detail(index: string) : string {
            const i = parseInt(index) || 0;
            if (!Shell.detail)
                return "no detail view";

            Shell.detail.openAt(i);
            return `detail ${i} of ${Catalog.count}`;
        }

        // Drive the detail page's actions from a terminal.
        /// Pick a filter the way the panel does, and report the query it
        /// produced — the check that a filter you chose is visible in the bar
        /// rather than hidden in a property.
        function pick(field: string, value: string) : string {
            Catalog.setFilter(field, value);
            return `query is now: "${Catalog.query}"`;
        }

        /// Put text in the search field the way a person does.
        ///
        /// `query` sets the catalogue's query directly, which is the right
        /// thing for "show me this" and the wrong thing for testing the bar:
        /// it skips the field entirely, so nothing that reacts to typing —
        /// the debounce, the completions, the clear button — ever runs.
        function type(text: string) : string {
            if (!Shell.queryBar)
                return "no search bar";

            Shell.queryBar.text = text || "";
            return `typed: "${text}"`;
        }

        function probe() : string {
            const q = Shell.queryBar;
            const bar = Shell.scrollBar;
            const panel = Shell.settingsPanel;
            const filter = Shell.filterPanel;
            const win = Shell.window;
            return JSON.stringify({
                "window": {
                    "width": win ? Math.round(win.width) : 0,
                    "height": win ? Math.round(win.height) : 0
                },
                // Whether the list a dock drives has room for it — "the last
                // row is under the dock" is otherwise only seen by eye.
                "dock": {
                    "inset": Math.round(Host.bottomInset),
                    "view": Host.activeFlickable ? String(Host.activeFlickable).split("(")[0] : "",
                    "viewBottomMargin": Host.activeFlickable && Host.activeFlickable.bottomMargin !== undefined ? Math.round(Host.activeFlickable.bottomMargin) : -1
                },
                "media": {
                    "ownWindow": Prefs.mediaOwnWindow,
                    "startsFullscreen": Prefs.mediaFullscreen,
                    "windowUp": Shell.mediaWindow ? Shell.mediaWindow.visible : false,
                    "showing": Shell.mediaWindow ? Shell.mediaWindow.showing : false,
                    "fullscreen": Shell.mediaWindow ? Shell.mediaWindow.fullscreen : false,
                    "inWindow": Shell.detail ? Shell.detail.open : false
                },
                "search": {
                    "width": q ? Math.round(q.width) : 0,
                    "completions": q ? q.suggestionCount : 0,
                    "dropdown": q ? Math.round(q.popupHeight) : 0,
                    "placement": q ? String(q.popupPlacement) : ""
                },
                "scrollbar": {
                    "handle": bar && bar.height > 0 ? Math.round(bar.size * bar.height) : 0,
                    "track": bar ? Math.round(bar.height) : 0,
                    "visible": bar ? bar.visible : false
                },
                "filter": {
                    "rows": filter ? filter.rows.length : -1,
                    "height": filter ? Math.round(filter.surfaceHeight) : 0
                },
                "settings": {
                    "sources": Catalog.sourcePrefs.length,
                    "rows": panel ? panel.sourceOrder.length : -1,
                    "blend": Catalog.blend,
                    "storage": {
                        "caches": panel ? panel.storageDirs.length : -1,
                        "total": panel ? panel.storageTotal : "",
                        "catalogue": panel ? panel.catalogueSize : "",
                        "thumbsMb": panel && panel.budgets ? (panel.budgets.thumbsMb !== undefined ? panel.budgets.thumbsMb : -1) : -1,
                        "failingSources": panel ? panel.healthFailing : -1,
                        "scripts": Scripts.scripts.length,
                        "scriptsFailing": Scripts.failing,
                        "scriptRowHooks": Scripts.rowHookCount,
                        "scriptMenus": Scripts.menuItems().length,
                        "scriptHidden": Catalog.scriptHiddenCount,
                        "untestedSources": panel ? panel.healthUnknown : -1,
                        "httpMb": panel && panel.budgets ? (panel.budgets.httpMb !== undefined ? panel.budgets.httpMb : -1) : -1
                    }
                },
                "catalog": {
                    "connected": Client.connected,
                    "count": Catalog.count,
                    "timing": {
                        "queryMs": Catalog.lastQueryMs,
                        "applyMs": Catalog.lastApplyMs,
                        "rows": Catalog.lastResultCount,
                        "ratiosMs": Catalog._ratiosMs,
                        "pagesMs": Catalog._pagesMs,
                        "viewMs": Catalog._changedMs
                    },
                    "facets": Catalog.facetSources.length,
                    "boards": Catalog.boards.length,
                    "damaged": Catalog.damaged
                },
                "layout": Prefs.layoutMode
            });
        }

        function rail() : string {
            Prefs.railExpanded = !Prefs.railExpanded;
            Perf.beginMeasure();
            railTimer.restart();
            return `rail ${Prefs.railExpanded ? "opening" : "closing"} · measuring for 450ms — read it with: app railReport`;
        }

        function railReport() : string {
            return `worst ${Perf.worstFrameMs.toFixed(1)}ms · ${Perf.measuredFrames} frames · ${Perf.missedFrames} over ${Perf.frameBudgetMs.toFixed(1)}ms budget · ${Perf.badFrames} over 32ms`;
        }

        /// The viewer's video player, as numbers: is it actually playing?
        function video() : string {
            const v = Shell.detail ? Shell.detail.videoView : null;
            if (!v)
                return "no viewer";

            const p = v.probe;
            return JSON.stringify({
                "active": v.active,
                "playing": v.playing,
                "ready": v.ready,
                "position": Math.round(p.position),
                "duration": Math.round(p.duration),
                "status": p.status,
                "failure": v.failure,
                "loaded": v._loaded.slice(-40),
                "wanted": v.wanted.slice(-40),
                "controls": v.controlsOpacity,
                "posterCovering": Shell.detail.posterCovering,
                "focused": p.focused
            });
        }

        /*
         * Force the window to a size, so a layout can be tested at the widths
         * it actually has to survive. The breakpoints in the player's bar were
         * written as numbers in conditions and never once measured at them.
         */
        function resize(w: string, h: string) : string {
            const win = Shell.window;
            if (!win)
                return "no window";

            const width = parseInt(w, 10);
            const height = parseInt(h, 10);
            if (!(width > 0) || !(height > 0))
                return "usage: resize <w> <h>";

            win.width = width;
            win.height = height;
            return `${win.width}x${win.height}`;
        }

        /*
         * Press a key AT THE PLAYER, the way the viewer now does.
         *
         * The player's shortcuts were dead for a long time without anyone
         * noticing, because nothing could press a key at them. This is the
         * route the viewer takes — the same `handleKey`, the same answer about
         * whether the key was taken.
         */
        function key(name: string) : string {
            const d = Shell.detail;
            const v = d ? d.videoView : null;
            if (!v || !v.visible)
                return "no video on screen";

            const keys = {
                "space": Qt.Key_Space,
                "left": Qt.Key_Left,
                "right": Qt.Key_Right,
                "comma": Qt.Key_Comma,
                "period": Qt.Key_Period,
                "m": Qt.Key_M,
                "l": Qt.Key_L,
                "s": Qt.Key_S,
                "bracketright": Qt.Key_BracketRight
            };
            const k = keys[String(name).toLowerCase()];
            if (k === undefined)
                return `unknown key: ${name}`;

            const took = v.handleKey({
                "key": k,
                "modifiers": 0
            });
            return took ? `${name}: the player took it` : `${name}: not the player's`;
        }

        /// Hold the player still so its bar can be looked at: paused, awake,
        /// and at a position far enough in that the timeline has something to
        /// show. A bar photographed while playing photographs itself hiding.
        function videoHold(at: string) : string {
            const v = Shell.detail ? Shell.detail.videoView : null;
            if (!v)
                return "no viewer";

            if (v.playing)
                v.toggle();

            v.wake();
            // Relative: from a fresh open the playhead is at zero, so this
            // lands where it says. `nudge` is the only seek the view exposes.
            const want = parseInt(at || "0", 10);
            if (want > 0)
                v.nudge(want);

            return `held at ${Math.round(v.probe.position)} of ${Math.round(v.probe.duration)}`;
        }

        /// The control bar's geometry — what share of it the timeline gets.
        function videoBar() : string {
            const v = Shell.detail ? Shell.detail.videoView : null;
            if (!v)
                return "no viewer";

            return JSON.stringify(v.barProbe);
        }

        /// Open the video quality menu and say where it landed. Called twice,
        /// the second answer is the settled one: a menu reports the size it
        /// had before its rows existed until the layout has run.
        function quality() : string {
            const v = Shell.detail ? Shell.detail.videoView : null;
            if (!v)
                return "no viewer";

            if (!v.showQualities())
                return "nothing to choose";

            const m = v.qualityPopup;
            return JSON.stringify({
                "open": m.visible,
                "x": Math.round(m.x),
                "y": Math.round(m.y),
                "w": Math.round(m.width),
                "h": Math.round(m.height),
                "paneW": Math.round(v.width),
                "paneH": Math.round(v.height),
                "fits": m.x >= 0 && m.y >= 0 && m.x + m.width <= v.width && m.y + m.height <= v.height
            });
        }

        /*
         * Put the app into a failure state on purpose.
         *
         * Failure UI is the least-looked-at UI in any program: it appears when
         * something rare has gone wrong, which is exactly when nobody is taking
         * screenshots. This lets the harness raise the state and photograph it —
         * it writes only what the strip reads, and the next answer from the
         * daemon overwrites it.
         */
        function pretend(what: string, text: string) : string {
            const say = text && text.length > 0 ? text : "a pretended failure";
            switch (String(what)) {
            case "damaged":
                Catalog.damaged = say;
                break;
            case "userdata":
                Catalog.userDataError = say;
                break;
            case "none":
                Catalog.damaged = "";
                Catalog.userDataError = "";
                return "cleared";
            default:
                return "usage: pretend damaged|userdata|none <text>";
            }
            return `${what}: ${say}`;
        }

        /*
         * What the layout on screen has been told to show, and what a tile
         * would therefore draw. The toggles live in a menu nobody can click
         * from a terminal, so this is how the harness sees them.
         */
        function layoutOptions(which: string) : string {
            const lay = which && which.length > 0 ? which : Prefs.layoutMode;
            const opts = Prefs.layoutSettings(lay);
            const buttons = ["export", "open", "keep", "board", "wallpaper", "copy", "similar", "hide"].filter((k) => {
                return opts[k] === true;
            });
            return JSON.stringify({
                "layout": lay,
                "buttons": buttons,
                "badges": opts.badges !== false,
                "length": opts.length !== false,
                "ring": opts.ring !== false,
                "strip": opts.strip !== false,
                "title": opts.title !== false,
                "meta": opts.meta !== false,
                "sort": opts.sort || "",
                "changed": Object.keys((Prefs.layoutOptions || {
                })[lay] || {
                }).length
            });
        }

        /// Set one of them, the way the menu does.
        function setLayoutOption(layout: string, key: string, value: string) : string {
            if (!layout || !key)
                return "usage: setLayoutOption <layout> <key> <on|off|value>";

            const v = value === "on" ? true : value === "off" ? false : value;
            Prefs.setLayoutOption(layout, key, v);
            return `${layout}.${key} = ${v}`;
        }

        /// Close any open menu; and with text, show it as a toast.
        function toast(text: string) : string {
            for (const m of [Shell.itemMenu, Shell.layoutMenu, Shell.settingsMenu]) if (m && m.visible) {
                m.close();
            }
            if (text && text.length > 0)
                Toast.show(text, "Undo", function() {
            });

            return text && text.length > 0 ? `toast: ${text}` : "menus closed";
        }

        /// Open a menu where it can be captured: `item`, `layout` or `more`.
        /*
         * The rail's right-click, without a pointer.
         *
         * `<id>` is what the row carries: "app:everything", "app:history",
         * "app:kind:video", or a lens's own id like "sub:wallpapers". Answers
         * with the rows the menu would draw, and opens it.
         */
        function railMenu(id: string) : string {
            const rows = String(id).indexOf("app:") === 0 ? (Shell.railMenuFor ? Shell.railMenuFor(String(id).slice(4)) : []) : (() => {
                const lens = Lenses.activeLens;
                return lens && typeof lens.navMenu === "function" ? lens.navMenu(id) : [];
            })();
            if (!rows || rows.length === 0)
                return `no menu for ${id}`;

            if (Shell.navRowMenu) {
                Shell.navRowMenu.rows = rows;
                Shell.navRowMenu.popupAt(240, 240);
            }
            return `${rows.length} rows: ${rows.map((r) => {
                return r.destructive === true ? `${r.label}!` : r.label;
            }).join(", ")}`;
        }

        function menu(which: string) : string {
            const w = Shell.window;
            const cx = w ? Math.round(w.width / 2) : 600;
            // A menu under an open panel cannot be seen; clear the way first.
            if (Shell.settingsPanel && Shell.settingsPanel.open)
                Shell.settingsPanel.close();

            if (Shell.filterPanel && Shell.filterPanel.open)
                Shell.filterPanel.close();

            if (Shell.detail && Shell.detail.open)
                Shell.detail.close();

            switch (which) {
            case "item":
                if (!Shell.itemMenu || Catalog.count === 0)
                    return "no item menu";

                Shell.itemMenu.openFor(Catalog.itemAt(0), cx, 240);
                return "item menu open";
            case "layout":
                if (!Shell.layoutMenu)
                    return "no layout menu";

                Shell.layoutMenu.popupAt(w ? w.width - 260 : cx, 60);
                {
                    /*
                     * WHAT IT IS OFFERING, not merely that it opened.
                     *
                     * A lens can drive this menu now, and "layout menu open"
                     * cannot tell a menu showing the catalogue's shapes from
                     * one showing Reddit's five — which is exactly the thing
                     * that needed checking.
                     */
                    const menu = Shell.layoutMenu;
                    const rows = menu.lensDriving ? menu.lensLayouts : menu.layouts;
                    const who = !menu.lensDriving ? "catalogue" : (Shell.historyPanel && Shell.historyPanel.open ? "history" : Lenses.activeId);
                    // The same name in both answers, so a probe reading one
                    // and then the other is not comparing two vocabularies.
                    const current = menu.lensDriving ? menu.lens.layout : Prefs.layoutMode;
                    return `layout menu open · ${who} · ${rows.length} rows: ${rows.map(r => r.id).join(", ")} · on ${current}`;
                };
            case "more":
                if (!Shell.settingsMenu)
                    return "no settings menu";

                Shell.settingsMenu.popupAt(w ? w.width - 300 : cx, 60);
                {
                    /*
                     * WHAT IT IS OFFERING, not merely that it opened — the same
                     * reason the layout menu says so. This menu's script and
                     * dock rows are filtered to where you are standing, and
                     * "it opened" cannot tell a correct filter from one that
                     * quietly matched nothing.
                     */
                    const here = Prefs.scriptsEnabled ? Scripts.hereScripts() : [];
                    const docks = Scripts.docks().filter(d => Scripts.appliesHere(d.match));
                    const on = here.filter(s => s.enabled).length;
                    // The control rows by name, because a menu popup does not
                    // appear in a window grab: this is the only way to see what
                    // the scripts actually contributed without a pointer.
                    const rows = Scripts.menuControls().map(c => `${c.label}[${c.kind}${c.kind === "toggle" ? (c.value === true ? " on" : " off") : c.kind === "slider" ? " " + Math.round(Number(c.value) || 0) : ""}]`);
                    /*
                     * The extension contributions in the same breath. Every one
                     * of these lists was written to by extensions and read by
                     * nothing until they were wired up, and "it opened" could
                     * never have told the difference.
                     */
                    const verbs = Lenses.menuItems.map(r => `${r.item.label}${r.scoped ? "" : "*"}`);
                    const acts = Host.actions.map(a => a.label || a.id);
                    const extras = `lens rows: ${verbs.length > 0 ? verbs.join(", ") : "none"} · actions: ${acts.length > 0 ? acts.join(", ") : "none"} · layouts: ${Host.layouts.length} · targets: ${Host.targets.length}`;
                    return `settings menu open · scripts: ${on}/${here.length} on here (${Scripts.scripts.length} loaded) · docks offered: ${docks.length} · rows: ${rows.length > 0 ? rows.join(", ") : "none"} · ${extras}`;
                };
            }
            return `unknown menu: ${which} (item, layout, more)`;
        }

        function shot(path: string) : string {
            const item = Shell.content;
            if (!item)
                return "no content item";

            const out = path && path.length > 0 ? path : "/tmp/quarry-shot.png";
            const ok = item.grabToImage(function(result) {
                result.saveToFile(out);
            });
            // Menus and popups are drawn in the window's overlay, which the
            // content item does not contain. Each open menu is grabbed on its
            // own, and its position reported so the pieces can be laid back
            // together: `<path>-<menu>.png` at `x,y`.
            const placed = [];
            for (const [name, menu] of [["item", Shell.itemMenu], ["layout", Shell.layoutMenu], ["more", Shell.settingsMenu]]) {
                if (!menu || !menu.visible || !menu.contentItem)
                    continue;

                const surface = menu.contentItem.parent;
                const target = out.replace(/\.png$/, "") + `-${name}.png`;
                const at = surface.mapToItem(item, 0, 0);
                if (surface.grabToImage(function(result) {
                    result.saveToFile(target);
                }))
                    placed.push(`${name}@${Math.round(at.x)},${Math.round(at.y)}`);

            }
            return (ok ? `grabbing to ${out}` : "grab refused") + (placed.length > 0 ? ` · menus ${placed.join(" ")}` : "");
        }

        function chrome() : string {
            const bar = Shell.scrollBar;
            const q = Shell.queryBar;
            const handle = bar && bar.height > 0 ? Math.round(bar.size * bar.height) : 0;
            return `scroll handle ${handle}px of ${bar ? Math.round(bar.height) : 0}px` + ` · visible ${bar ? bar.visible : "?"}` + ` | search ${q ? Math.round(q.width) : 0}px` + ` · completions ${q ? q.suggestionCount : 0}` + ` · dropdown ${q ? Math.round(q.popupHeight) : 0}px` + (q ? ` | ${q.popupPlacement}` : "");
        }

        /// Open settings on a page and report what that page actually holds.
        ///
        /// The same class of check as `filter`: a page can be present, correct
        /// and drawing nothing, and only a count says which.
        function settings(page: string, find: string) : string {
            const panel = Shell.settingsPanel;
            if (!panel)
                return "no settings panel";

            if (page && page.length > 0)
                panel.page = page;

            /*
             * The search box, from outside. The panel is a long scrolling list
             * and nothing could reach past the first screenful of it, so a row
             * below the fold could only be checked by asking the person at the
             * keyboard to scroll — which is not a check, it is a request.
             */
            if (find !== undefined)
                panel.query = String(find);

            panel.open = true;
            const grouped = panel.sourceOrder;
            const shape = grouped.map((id) => {
                return `${(Catalog.sourcePrefMap[id] || {}).category}/${id}`;
            }).join(",");
            return `settings open · page ${panel.page} · ${Catalog.sourcePrefs.length} sources known` + ` · ${grouped.length} rows · blend ${Catalog.blend}` + `\n${shape}`;
        }

        /// Open the filter panel and say what is in it.
        ///
        /// Reports the row count and the height it opened at, because the way
        /// this breaks is not an error — it is a panel that opens correctly
        /// and is too short to draw anything in.
        function filter() : string {
            if (!Shell.filterPanel)
                return "no filter panel";

            Shell.filterPanel.toggle();
            if (!Shell.filterPanel.open)
                return "filter closed";

            return `filter open · ${Shell.filterPanel.rows.length} rows · ${Math.round(Shell.filterPanel.surfaceHeight)}px`;
        }

        /// Open a lens by id (empty closes), and report what the host is showing.
        /// `app lensNav <id>` — pick one of the open lens's own rows (a board,
        /// a section), the way the rail does.
        function lensNav(id: string) : string {
            if (Lenses.activeId.length === 0)
                return "no lens open";

            Lenses.navPick(id);
            return `picked ${id}`;
        }

        function lens(id: string) : string {
            if (!id || id.length === 0) {
                Lenses.close();
                return "lens closed";
            }
            const entry = Lenses.find(id);
            if (!entry)
                return `no lens called ${id} · have ${Lenses.catalog.map(e => e.id).join(", ")}`;

            Lenses.open(id, {
            });
            return `lens ${Lenses.activeId} · error ${entry.error || "none"}`;
        }

        /// Turn a lens on or off — what the switch in the menu does.
        function lensToggle(id: string) : string {
            const entry = Lenses.find(id);
            if (!entry)
                return `no lens called ${id} · have ${Lenses.catalog.map(e => e.id).join(", ")}`;

            Lenses.toggle(id);
            return JSON.stringify({
                "id": id,
                "enabled": Lenses.isEnabled(id),
                "inRail": Lenses.railEntries.some((e) => {
                    return e.id === id;
                })
            });
        }

        function lensState(id: string) : string {
            const entry = Lenses.find(id);
            if (!entry)
                return `no lens called ${id}`;

            return JSON.stringify({
                "saved": Lenses.settingsOf(id),
                "live": entry.instance ? entry.instance.settings : null,
                "enabled": Lenses.isEnabled(id),
                "skin": Lenses.skinOf(id)
            });
        }

        /*
         * PRESS A KEY A SCRIPT BOUND, and say what it did.
         *
         * `key` above belongs to the video player. A script's bindings are a
         * different surface with a different question — "is this script
         * wired up at all" — and answering it by hand needs a keyboard and a
         * screen, which is exactly what this app is tested without.
         */
        function script(name: string) : string {
            if (!Prefs.scriptsEnabled)
                return "scripts are off";

            /*
             * `dock:<id>` switches one on or off, so a dock can be bound to a
             * key in the compositor the way anything else here can — and so a
             * probe can turn one on without a pointer.
             */
            if (String(name).indexOf("dock:") === 0) {
                const which = String(name).slice(5);
                if (!Scripts.docks().some(d => d.id === which))
                    return `no dock called ${which}`;

                Scripts.setDockShowing(which, !Scripts.dockShowing(which));
                return `${which} ${Scripts.dockShowing(which) ? "showing" : "hidden"}`;
            }
            const took = Scripts.key(String(name), {
                "item": Catalog.itemAt(0),
                "query": Catalog.query,
                "lens": Lenses.activeId
            });
            const view = Scripts.scrollable();
            /*
             * WHO CLAIMED THE SURFACE, beside what the walk would have found.
             *
             * The two should agree on the wall and must NOT agree inside a
             * two-pane lens — the walk takes the biggest list, the claim takes
             * the one the skin meant. Printing both is the only way to check
             * that from a terminal.
             */
            const claimed = Host.activeFlickable;
            const owner = Host.activeOwner;
            // `at` and `from` are the scroll position and the range's origin:
            // a bottom-to-top list runs negative, which is the one fact a
            // scrolling bug in a chat always turns out to be about.
            const claim = claimed ? `${owner ? String(owner).split("(")[0].trim() : "?"} ${Math.round(claimed.height)}px holding ${Math.round(claimed.contentHeight)} at ${Math.round(claimed.contentY)} from ${Math.round(claimed.originY || 0)}` : "nobody";
            /*
             * The docks are named here because a dock is the one part of a
             * script with no other way to be checked: it draws itself into a
             * floating strip, and "is it on screen" is otherwise a screenshot
             * question. `name` still means the key to press — passing one that
             * is not bound is how you ask for this report alone.
             */
            const docks = Scripts.docks().map(d => `${d.id}${Scripts.dockShowing(d.id) ? "*" : ""}[${d.items.length}]${Scripts.appliesHere(d.match) ? "" : " (not here)"}`);
            return `${took ? "taken" : "nothing bound"} · ${Scripts.scripts.length} scripts · scroll ${Scripts.scrollSpeed} px/s · claimed by ${claim} · walk found ${view ? Math.round(view.height) + "px tall holding " + Math.round(view.contentHeight) : "nothing"} · docks: ${docks.length > 0 ? docks.join(", ") : "none"}`;
        }

        /// Read one of a lens's own properties — its screen, what it has
        /// fetched, what it is showing. Arrays and objects come back as JSON.
        function lensRead(id: string, prop: string) : string {
            const instance = Lenses.instanceOf(id);
            if (!instance)
                return `${id} is not running`;

            const value = instance[prop];
            if (value === undefined)
                return `${id} has no ${prop}`;

            if (typeof value !== "object" || value === null)
                return String(value);

            // Capped: a whole catalogue of posts closes the IPC socket, and a
            // probe that kills the connection reports nothing at all.
            const text = JSON.stringify(value);
            const head = Array.isArray(value) ? `${value.length} · ` : "";
            return head + (text.length > 1200 ? text.slice(0, 1200) + "…" : text);
        }

        /// Call a lens's own function, the way its UI would. Arguments are
        /// separated by `|` and each is read as JSON when it parses — `qs ipc`
        /// splits an argument on commas, so a JSON array cannot be passed.
        /// `lensDo fourchan setBoardEnabled "wg|true"`.
        function lensDo(id: string, fn: string, args: string) : string {
            const instance = Lenses.instanceOf(id);
            if (!instance)
                return `${id} is not running`;

            if (typeof instance[fn] !== "function")
                return `${id} has no ${fn}()`;

            const parts = (args || "").length > 0 ? String(args).split("|") : [];
            const values = parts.map((part) => {
                try {
                    return JSON.parse(part);
                } catch (e) {
                    return part;
                }
            });
            instance[fn].apply(instance, values);
            return `${id}.${fn} called`;
        }

        /// The kept record: open it and say how many entries it is showing.
        function history() : string {
            if (!Shell.historyPanel)
                return "no history panel";

            Shell.historyPanel.toggle();
            if (!Shell.historyPanel.open)
                return "history closed";

            return `history open · ${Shell.historyPanel.entries.length} entries`;
        }

        function act(what: string, arg: string) : string {
            if (!Shell.detail || !Shell.detail.open)
                return "detail is closed";

            const item = Shell.detail.shown;
            if (!item)
                return "nothing shown";

            switch (what) {
            case "wallpaper":
                Shell.detail.wallpaperRequested(item, arg || "wallpaper-eDP-1");
                return `wallpaper -> ${arg}`;
            case "copy":
                Shell.detail.copyRequested(item, arg || "url");
                return `copy ${arg}`;
            case "open":
                Shell.detail.openRequested(item, arg || "page");
                return `open ${arg}`;
            case "export":
                Shell.detail.exportRequested(item, arg || "steam-avatar");
                return `export ${arg}`;
            case "similar":
                Shell.detail.similarRequested(item, arg || "all");
                return `similar to ${item.id}`;
            default:
                return `unknown action: ${what}`;
            }
        }

        function cropState() : string {
            const sheet = Shell.exportSheet;
            if (!sheet)
                return "no export sheet";

            return `${sheet.targetId} crop=${Math.round(sheet.cropX)},${Math.round(sheet.cropY)} ${Math.round(sheet.cropW)}x${Math.round(sheet.cropH)} of ${sheet.sourceW}x${sheet.sourceH}` + (sheet.modified ? " · edited" : "");
        }

        function crop(action: string, amount: string) : string {
            const sheet = Shell.exportSheet;
            if (!sheet)
                return "no export sheet";

            const step = parseFloat(amount) || 0;
            switch (action) {
            case "open":
                sheet.openFor(Shell.detail && Shell.detail.shown ? Shell.detail.shown : Catalog.itemAt(0), amount || "steam-avatar");
                return `crop open on ${sheet.targetId}`;
            case "move":
                sheet.cropX = sheet.clampX(sheet.cropX + step, sheet.cropW);
                sheet.refreshPreview();
                return `x=${Math.round(sheet.cropX)}`;
            case "zoom":
                sheet.zoomCrop(step > 0 ? step : 0.9);
                return `${Math.round(sheet.cropW)}x${Math.round(sheet.cropH)}`;
            case "state":
                return `${sheet.targetId} crop=${Math.round(sheet.cropX)},${Math.round(sheet.cropY)} ${Math.round(sheet.cropW)}x${Math.round(sheet.cropH)} of ${sheet.sourceW}x${sheet.sourceH}`;
            default:
                return `unknown crop action: ${action}`;
            }
        }

        // Keep and unkeep from a terminal, so the flow can be tested headlessly.
        function keep(name: string) : string {
            const item = (Shell.detail && Shell.detail.shown) ? Shell.detail.shown : Catalog.itemAt(0);
            if (!item)
                return "nothing to keep";

            Catalog.keep(item, name, true);
            return `keeping ${item.id} in ${name}`;
        }

        // Extensions, from a terminal — enabling one is the whole test.
        function extensions() : string {
            if (Extensions.count === 0)
                return "(none found)";

            return Extensions.catalog.map((e) => {
                return `${e.id}${Extensions.isEnabled(e.id) ? " [on]" : ""}${e.error ? " ERROR: " + e.error : ""}`;
            }).join(", ");
        }

        function boards() : string {
            if (Catalog.boards.length === 0)
                return "no boards yet · make one in quarry-board, or add a picture to one";

            return Catalog.boards.map((b) => {
                return `${b.name}(${b.items})`;
            }).join(", ") + " · arrange them with quarry-board";
        }

        function packs() : string {
            const packs = Extensions.mockPacks.map((p) => {
                return `${p.id}${Extensions.isEnabled(p.id) ? " [on]" : " [off]"}`;
            });
            const live = Extensions.contextMocks.map((m) => {
                return `${m.extensionId}:${m.mock.id} ${m.mock.designW}×${m.mock.designH}`;
            });
            return `packs: ${packs.join(", ") || "(none)"}\ndrawing: ${live.join(", ") || "(none)"}`;
        }

        function extension(id: string) : string {
            const on = !Extensions.isEnabled(id);
            Extensions.setEnabled(id, on);
            return `${id} ${on ? "enabled" : "disabled"}`;
        }

        function kept() : string {
            return Catalog.collections.map((c) => {
                return `${c.name} (${c.items})`;
            }).join(", ") || "(nothing kept)";
        }

        function shown() : string {
            if (!Shell.detail || !Shell.detail.shown)
                return "(nothing)";

            const it = Shell.detail.shown;
            return `${it.id} · ${it.title || it.slug} · ${it.w}x${it.h} · ${it.family} · related ${Shell.detail.related.length}`;
        }

        function step(delta: string) : string {
            if (!Shell.detail || !Shell.detail.open)
                return "detail is closed";

            Shell.detail.step(parseInt(delta) || 1);
            return `at ${Shell.detail.index}`;
        }

        function kind(k: string) : string {
            Catalog.kind = k || "";
            Catalog.query = "";
            Shell.present();
            return `open on kind: ${k}`;
        }

        /*
         * Open a page in the in-app browser, and say what it did.
         *
         * `browse` with no URL closes it; `browse state` answers without
         * touching anything, which is what a check that runs twice needs.
         */
        function browse(url: string) : string {
            const b = Shell.browser;
            if (!b)
                return "no browser view";

            const arg = (url || "").trim();
            if (arg === "state") {
                const e = b.engine;
                return JSON.stringify({
                    "open": b.open,
                    "enabled": Prefs.browserEnabled,
                    "sourceInApp": Prefs.browserSourceInApp,
                    "engineAllowed": b.engineAllowed,
                    "engineReady": b.engineReady,
                    "problem": b.engineProblem,
                    "url": e ? String(e.currentUrl) : b.pendingUrl,
                    "title": e ? e.pageTitle : "",
                    "loading": e ? e.loading : false,
                    "progress": e ? e.progress : 0,
                    "canGoBack": e ? e.canGoBack : false,
                    "canGoForward": e ? e.canGoForward : false,
                    "lastImage": e ? e.lastImageUrl : ""
                });
            }
            if (arg.length === 0) {
                b.close();
                return "browser closed";
            }
            b.openUrl(arg);
            Shell.present();
            return `browsing ${arg}`;
        }

        /// Drive the browser without a pointer: back, forward, reload, stop,
        /// pull (add the biggest picture on the page), external, close.
        function browseAct(what: string) : string {
            const b = Shell.browser;
            if (!b)
                return "no browser view";

            switch (what) {
            case "back":
                if (b.engine)
                    b.engine.goBack();

                break;
            case "forward":
                if (b.engine)
                    b.engine.goForward();

                break;
            case "reload":
                if (b.engine)
                    b.engine.reload();

                break;
            case "stop":
                if (b.engine)
                    b.engine.stop();

                break;
            case "pull":
                if (b.engine)
                    b.engine.pullLargest();

                // what the toolbar button does
                break;
            case "external":
                b.openOutside();
                break;
            case "close":
                b.close();
                break;
            default:
                return "unknown: back forward reload stop pull external close";
            }
            return `${what} · open ${b.open}`;
        }

        target: "app"
    }

    _perf: IpcHandler {
        function scale(times: string) : string {
            const n = parseInt(times) || 1;
            Catalog.multiply(n);
            return Perf.report();
        }

        function geometry() : string {
            const g = Shell.gallery;
            if (!g)
                return "no gallery view";

            const out = {
                "layoutMode": Prefs.layoutMode,
                "slot": Slots.current ? Slots.current.id : null,
                "slotQuery": Slots.current ? Slots.current.query : null,
                "target": Slots.activeTargetId,
                "w": Math.round(g.width),
                "h": Math.round(g.height),
                "visible": g.visible,
                "opacity": g.opacity,
                "dpr": Screen.devicePixelRatio,
                "items": Catalog.count,
                "ratios": Catalog.ratios ? Catalog.ratios.length : 0,
                "facets": (Catalog.facetKinds ? Catalog.facetKinds.length : 0) + (Catalog.facetSources ? Catalog.facetSources.length : 0) + (Catalog.facetFamilies ? Catalog.facetFamilies.length : 0)
            };
            if (Catalog.facetError && Catalog.facetError.length > 0)
                out.facetError = Catalog.facetError;

            // A view that is sized but shows nothing is the case worth naming.
            if (g.width <= 0 || g.height <= 0 || !g.visible || g.opacity <= 0)
                out.verdict = "the view itself has no drawable area";

            // Each field on its own: the grid has a column COUNT but no column
            // WIDTH, and reporting `null` for it would be inventing a fact.
            if (g.columnCount !== undefined)
                out.columnCount = g.columnCount;

            if (g.columnWidth !== undefined) {
                out.columnWidth = Math.round(g.columnWidth);
                out.drawPx = Math.ceil(g.columnWidth * (Screen.devicePixelRatio || 1));
            }
            if (g.ladder !== undefined)
                out.ladderStep = g.ladder;

            if (g.geometry) {
                out.totalHeight = Math.round(g.geometry.totalHeight);
                out.revision = g.geometry.revision;
                if (g.geometry.hs)
                    out.hsLen = g.geometry.hs.length;

                if (g.geometry.colIndex)
                    out.colCounts = g.geometry.colIndex.map((a) => {
                    return (a ? a.length : 0);
                });

            }
            if (g.columnReport) {
                out.columns = g.columnReport();
                // The two numbers that were zero while everything else looked
                // right. Named, so nobody has to notice them in a wall of JSON.
                const dead = out.columns.filter((c) => {
                    return c && (c.h <= 0 || c.count <= 0);
                });
                if (dead.length)
                    out.verdict = `${dead.length}/${out.columns.length} columns have no height or no rows`;

            }
            return JSON.stringify(out);
        }

        function report() : string {
            return Perf.sample();
        }

        // Scripted scroll: `ipc call perf scroll 4000` sweeps 20000px over 4s
        // and leaves the frame statistics in `report`.
        function scroll(durationMs: string) : string {
            if (!Perf.wall)
                return "no wall";

            const ms = parseInt(durationMs) || 4000;
            Perf.wall.scrollTest(ms, 20000);
            return `sweeping 20000px over ${ms}ms`;
        }

        // Force a collection, so a memory number can distinguish "held" from
        // "not yet collected" instead of guessing. Named `collect` because
        // `gc` is reserved by the IPC layer.
        function collect() : string {
            Perf.collect();
            return Perf.sample();
        }

        // Decodes off: the same sweep with no images loaded isolates what the
        // geometry and the delegates cost from what the pixmaps cost.
        // Render tuning knobs, so each one's cost is a measurement.
        function render(knob: string, value: string) : string {
            const on = value === "on" || value === "1" || value === "true";
            switch (knob) {
            case "clip":
                Prefs.tileClip = on;
                break;
            case "smooth":
                Prefs.tileSmoothing = on;
                break;
            case "radius":
                Prefs.tileRadius = parseFloat(value) || 0;
                break;
            default:
                return `unknown knob: ${knob}`;
            }
            return `${knob} = ${value}`;
        }

        function images(on: string) : string {
            ThumbGate.maxInFlight = (on === "off" || on === "0") ? 0 : 8;
            return `maxInFlight=${ThumbGate.maxInFlight}`;
        }

        function reset() : string {
            Catalog.load();
            return "reloaded";
        }

        target: "perf"
    }

    _catalog: IpcHandler {
        /*
         * Queries are a round trip to the daemon now, so this cannot answer
         * with a count: it would report the *previous* query's result, which is
         * exactly the kind of quietly-wrong number a harness must never print.
         * Set it here, read `count` once it lands.
         */
        function query(q: string) : string {
            Catalog.query = q;
            return `queued: ${q}`;
        }

        /// The query as it stands, words and tokens — what a layout's own sort
        /// actually wrote into it, among other things.
        function text() : string {
            return Catalog.query.length > 0 ? Catalog.query : "(everything)";
        }

        function thumbstats() : string {
            return Catalog.thumbStats();
        }

        /// Back/forward stacks as JSON — the history menu's model, for tests.
        function history() : string {
            return JSON.stringify({
                "back": Catalog.history.map((s) => {
                    return Catalog.describeStep(s);
                }),
                "here": Catalog.describeStep({
                    "query": Catalog.query,
                    "similar": Catalog.similarTo
                }),
                "forward": Catalog.future.map((s) => {
                    return Catalog.describeStep(s);
                })
            });
        }

        function back(steps: string) : string {
            Catalog.back(parseInt(steps) || 1);
            return "back";
        }

        function forward(steps: string) : string {
            Catalog.forward(parseInt(steps) || 1);
            return "forward";
        }

        function count() : string {
            // `exhausted` and the page tally travel with the count: "the wall
            // stopped growing" is answered by those two, not by the count.
            return `${Catalog.count} items · sort ${Catalog.sort} · pages ${Catalog.pagesLoaded} · exhausted ${Catalog.exhausted}` + (Catalog.unknownKeys.length > 0 ? ` · unknown ${Catalog.unknownKeys.join(",")}` : "");
        }

        function kind(k: string) : string {
            Catalog.kind = k;
            return `queued: kind=${k}`;
        }

        // Crawl the live sources for the current query.
        function search(sources: string) : string {
            const list = (sources || "wallhaven,danbooru").split(",");
            Catalog.searchSources(list);
            return `searching ${list.join(", ")}`;
        }

        function report() : string {
            return Catalog.searchReport || (Catalog.searching ? "searching…" : "idle");
        }

        // Endless scroll, driven from a terminal.
        function more(pages: string) : string {
            const n = parseInt(pages);
            if (n > 0)
                Catalog.pagesPerLoad = n;

            Catalog.loadMore();
            return `loading ${Catalog.pagesPerLoad} pages`;
        }

        // Export from a terminal, so the pipeline can be verified without
        // raising a window over whatever is fullscreen.
        function export_(id: string, target: string) : string {
            const item = Catalog.itemById(id);
            if (!item)
                return `no such item: ${id}`;

            Catalog.exportItem(item, target || "steam-avatar", function(err, payload) {
                console.log("[quarry] export", err ? "failed: " + err : payload.path);
            });
            return `exporting ${id} -> ${target}`;
        }

        function targets() : string {
            // Whether it APPLIES is the most important thing about a target: an
            // export that writes a file and one that also sets the wallpaper
            // look identical from here otherwise, and a contributed target that
            // lost its `apply` would be the silent version of broken.
            return Targets.all.map((t) => {
                const verbs = [];
                if (t.apply)
                    verbs.push("apply");
                if (t.applyVideo)
                    verbs.push("applyVideo");
                if (t.after)
                    verbs.push("after");
                return `${t.id} (${t.recipe.width}x${t.recipe.height})${verbs.length > 0 ? " · " + verbs.join("+") : ""}`;
            }).join("\n");
        }

        function lastExport() : string {
            return Catalog.lastExport || "(nothing exported yet)";
        }

        /// Which sources the first `n` results come from, tallied — a wall that
        /// looks like one source can be checked without looking at it.
        function mix(n: string) : string {
            const count = Math.min(Catalog.count, Math.max(1, parseInt(n) || 100));
            const tally = {
            };
            let loaded = 0;
            for (let i = 0; i < count; i++) {
                const item = Catalog.itemAt(i);
                if (!item)
                    continue;

                loaded++;
                tally[item.source] = (tally[item.source] || 0) + 1;
            }
            const parts = Object.keys(tally).sort((a, b) => {
                return tally[b] - tally[a];
            }).map((k) => {
                return `${k} ${tally[k]}`;
            });
            return `first ${count} (${loaded} loaded) of "${Catalog.query}": ${parts.join(", ")}`;
        }

        function first() : string {
            const item = Catalog.itemAt(0);
            return item ? item.id : "(empty)";
        }

        function clear() : string {
            Catalog.query = "";
            Catalog.kind = "";
            Catalog.source = "";
            Catalog.family = "";
            return "queued: cleared";
        }

        target: "catalog"
    }

}
