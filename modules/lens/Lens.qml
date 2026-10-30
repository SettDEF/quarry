import QtQuick
import qs.modules.common
import qs.services

/*
 * Base type for a quarry LENS. A lens's entry file declares one of these as its
 * root:
 *
 *   import qs.modules.lens
 *   Lens {
 *       screenTitle: "4chan"
 *       onOpened: load()
 *       // …state and fetching live here; a skin only draws it
 *   }
 *
 * A lens holds the STATE. Skins are swapped over the top of it, so everything
 * you had navigated to survives changing how it looks. A skin that reaches back
 * into the lens for data is right; a lens that reaches into a skin is not — the
 * skin it finds may be gone by the next frame.
 *
 * Metadata comes from lens.json, not from here: the manifest has to be readable
 * before the component is instantiated, so a lens can be listed, described and
 * left switched off without its code ever loading.
 *
 * Talk to the app through the Host, Catalog and Sys singletons. Reaching into
 * views directly will break — delegates are recycled and layouts swap at
 * runtime.
 */
Item {
    // ── contributions ────────────────────────────────────────────────────────
    //     * Rows appended to the header's overflow menu:
    //     *   { label, icon, hint, checked, destructive, action }
    //         * YOUR BROWSER BY DEFAULT; QUARRY'S WINDOW IF YOU ASKED FOR IT.
    //         *
    //         * A link is somebody's address, and an address belongs in the browser
    //         * you are signed in to — your tabs, your extensions, your history.
    //         * That is where every other app on the desktop sends one, and it is
    //         * what `Prefs.browserSourceInApp` now defaults to.
    //         *
    //         * Turned on, the page opens in `quarry-browser` instead: a small Qt
    //         * program that ships with the app, and a separate process because
    //         * quickshell constructs Qt with an empty argument list and Qt
    //         * WebEngine aborts without one, taking the whole shell with it.
    //         *
    //         * When that window is wanted and missing — a checkout that has not
    //         * built it — the desktop's browser is still better than a dead
    //         * button, and that is said rather than silently done.
    //         * "HERE" MEANS HERE.
    //         *
    //         * This is the button a lens draws as "Open the real site here", and
    //         * it was made to respect `browserSourceInApp` — which now defaults to
    //         * your own browser, so pressing it opened the page anywhere BUT here
    //         * and the tooltip became a lie.
    //         *
    //         * The setting was asked for about LINKS: an address somebody sent you
    //         * belongs in the browser you are signed in to. An explicit "open it
    //         * here" is not a link, it is an instruction, so it obeys the word on
    //         * the button. Links go through `openLink` below, which is where the
    //         * setting lives now.

    id: root

    // Filled in by the registry from the manifest.
    property string lensId: ""
    /// The name the extension API used. Kept so legacy packs still read it.
    property string extensionId: ""
    property string name: ""
    property string description: ""
    property string version: ""
    property string author: ""
    /// Absolute path of the lens directory — for loading its own assets.
    property string lensDir: ""
    /// The manifest said this lens carries adult material. Rows it contributes
    /// should be marked so quarry's blur and hide settings apply.
    property bool adult: false
    /*
     * Persisted for you by the registry — what you switched on, where you were.
     * Small things only: it is one JSON blob beside the enabled list, not a
     * cache. Change it through `saveSettings`, which writes and hands it back.
     */
    property var settings: ({
    })
    /*
     * HOW A LENS LAYS ITS FEED OUT — one model, inherited by all of them.
     *
     * Reddit and Morse each grew their own copy of this: the same four
     * shapes, the same per-context memory, the same setter, written twice and
     * drifting. Worse, the app's layout button — the one control that means
     * "how is this laid out" everywhere else — could only drive a lens that
     * happened to implement the right names.
     *
     * So it lives here. A lens sets `layouts` to the shapes it can draw (the
     * standard four are `pictureLayouts` below) and `layoutContext` to
     * whatever the choice should be remembered against — a subreddit, a
     * board, a chat. Everything else is inherited, and LayoutMenu drives any
     * lens that declares any.
     */
    property var layouts: []
    /// What the choice is remembered against. Empty means one memory for the
    /// whole lens rather than one per screen.
    property string layoutContext: ""
    /// The four the gallery itself offers, for a lens that wants the standard
    /// set. Same ids, labels and icons — a person who has learned what
    /// "Contact sheet" means must not have to learn it again inside a lens.
    readonly property var pictureLayouts: [{
        "id": "wall",
        "label": "Wall",
        "icon": "view_quilt",
        "hint": "real shapes",
        "cell": 240
    }, {
        "id": "grid",
        "label": "Grid",
        "icon": "grid_view",
        "hint": "even tiles",
        "cell": 200
    }, {
        "id": "sheet",
        "label": "Contact sheet",
        "icon": "apps",
        "hint": "hundreds at a time",
        "cell": 120
    }, {
        "id": "compact",
        "label": "Compact",
        "icon": "view_list",
        "hint": "the facts, as rows",
        "cell": 0
    }]
    readonly property string layout: {
        if (root.layouts.length === 0)
            return "";

        const saved = root.settings.layouts || ({
        });
        const mine = root.layoutContext.length > 0 ? saved[root.layoutContext] : "";
        if (mine && String(mine).length > 0)
            return String(mine);

        // Then the last one chosen anywhere in this lens, then its first.
        if (root.settings.layout && String(root.settings.layout).length > 0)
            return String(root.settings.layout);

        return String(root.layouts[0].id);
    }
    readonly property int layoutCell: {
        for (const l of root.layouts) if (l.id === root.layout) {
            return Number(l.cell || 0);
        }
        return 200;
    }
    /// True where the layout keeps each picture's own shape.
    readonly property bool keepsShape: root.layout === "wall"
    /// Which skin is on. The registry assigns it; react in onSkinIdChanged if
    /// the lens needs to (most do not — the skin reads the lens, not the
    /// reverse).
    property string skinId: ""
    /*
     * Host-managed and persisted. Treat as read-only; react in onActivated /
     * onDeactivated.
     *
     * Named `active` rather than `enabled`: Item already has an `enabled`,
     * which controls input delivery, and shadowing it both warns at load time
     * and confuses the two meanings.
     */
    property bool active: false
    // ── the screen ───────────────────────────────────────────────────────────
    /// True while this lens has the content area.
    property bool isOpen: false
    /// What the host chrome prints — usually where you are, not what the lens is.
    property string screenTitle: root.name
    /// Whether the lens has somewhere of its own to go back to. When false, the
    /// host's back button closes the lens instead.
    property bool canGoBack: false
    /*
     * What the rail shows while this lens is open: [{ id, label, icon, count,
     * active }]. Empty means the rail keeps quarry's own rows — a lens with
     * one screen has nothing to navigate.
     */
    property var navItems: []
    /// Entries known by face (Morse's chats): drawn as tiles under navItems, two
    /// to a row. [{ id, label, picture, icon, initials, hue, count, active }]
    property var navTiles: []
    /// Whatever sent you here: a row, a source id, a URL. May be null.
    property var context: null
    /*
     * THE REAL SITE, INSIDE THE APP.
     *
     * A lens is a way of looking at a site, not a replacement for it: there is
     * always something the API does not carry — the comments under a video, a
     * thread's original formatting, a page that only exists on the site itself.
     * A lens that sets this gets one row in the header's overflow, and can put
     * a button wherever it likes by calling `showSite()`.
     *
     * Set it to where you ARE, not to the site's front door: the point is to
     * carry on with the same thing in the other window, not to start again.
     */
    property string siteUrl: ""
    /*
     * WHAT A RIGHT-CLICK ON ONE OF THIS LENS'S RAIL ROWS OFFERS.
     *
     * The rail's lower half is the lens's — a community, a chat, a board — and
     * nothing in the app knows what those are, so nothing in the app can say
     * what "remove this one" means for them. Answer with
     * `[{ label, icon, hint, destructive, action }]` for the row id you were
     * handed; return nothing and the row simply has no menu, which is the
     * right answer for a row that cannot be acted on.
     */
    function navMenu(id) {
        return [];
    }

    property var menuItems: []
    /*
     * Mockups contributed to the in-context layout:
     *   { id, label, detail, targetId, designW, designH, component }
     *
     * `designW`/`designH` are DEVICE pixels, the unit a target is specified in.
     * `component` is drawn inside a card that has already worked out the scale
     * and reads it through an injected `mock` property — `mock.u(px)` converts
     * a device-pixel measurement to logical units, `mock.record` is the picture.
     */
    property var contextMocks: []

    /*
     * WHO OPENS A LINK.
     *
     * `[{ id, label, matches: url => bool, command: ["prog", "%u"] }]` — every
     * web address quarry hands to the system goes to the first opener whose
     * `matches` says yes, with `%u` replaced by the address, instead of to
     * xdg-open. A pack (extensions/urlportal) is how somebody's own link router
     * takes over without quarry learning its name.
     */
    property var openers: []
    /// Drawn above the feed, filling the content area. FABs and HUDs.
    property Component overlay: null
    /// Rendered inside Settings when this lens is expanded.
    property Component settingsPage: null
    /// [{ sequence | sequences, action }] — installed while enabled.
    property var shortcuts: []

    /// The rail picked one of them.
    signal navPicked(string id)
    signal opened()
    signal closedDown()
    /// The host's back gesture. Answer it by navigating; ignore it and the host
    /// closes the lens.
    signal backRequested()
    signal activated()

    /*
     * THE DAEMON CAME BACK.
     *
     * A lens asks quarryd for everything it shows and gives up quietly when it
     * is not there — "Can't reach quarryd — start it and this fills in". That
     * sentence is correct and then becomes a lie the moment the daemon returns,
     * because nothing told the lens to look again: it sat on the message until
     * you navigated by hand. Restarting the daemon is a normal thing to do —
     * every upgrade does it — so this is the ordinary case, not an edge one.
     *
     * LensHost emits it for whichever lens is open. A lens that has nothing to
     * redo can ignore it.
     */
    signal reconnected()
    signal deactivated()

    function setLayout(id) {
        for (const l of root.layouts) if (l.id === id) {
            const saved = Object.assign({
            }, root.settings.layouts || ({
            }));
            if (root.layoutContext.length > 0)
                saved[root.layoutContext] = id;

            const next = Object.assign({
            }, root.settings);
            next.layouts = saved;
            // Also the plain default, so a screen you have never set opens the
            // way the last one you chose did.
            next.layout = id;
            root.saveSettings(next);
            return ;
        }
    }

    function saveSettings(values) {
        root.settings = values || {
        };
        Lenses.setSettings(root.lensId, root.settings);
    }

    /*
     * A LINK SOMEBODY SENT YOU — your browser, unless you asked otherwise.
     *
     * The other half of the split above: a lens calls this for an address
     * that came out of a message, a post or a page, and `browserSourceInApp`
     * decides where it lands. The default is your own browser, with your
     * tabs, your extensions and your history.
     *
     * NOT called `openLink`. Morse already has a function by that name — it
     * resolves `t.me` addresses to chats before anything opens — so a lens
     * calling `root.openLink` from inside its own `openLink` called ITSELF,
     * and every link in a message quietly did nothing at all. A base-type
     * helper must not share a name with the thing lenses override.
     */
    /*
     * `force` skips quarry's own window whatever the setting says.
     *
     * Holding shift is the universal "not here, out there" gesture — every
     * browser uses it for a new window — and it is wanted most exactly when
     * the in-app reader is on and this particular link is one you want in your
     * real browser, with your logins, your extensions and your history.
     */
    function openExternally(url, force) {
        const target = String(url || "").trim();
        if (target.length === 0)
            return ;

        if (Prefs.browserSourceInApp && !force) {
            root.showSite(target);
            return ;
        }
        Sys.open(target);
    }

    function showSite(url) {
        const target = String(url || root.siteUrl || "").trim();
        if (target.length === 0) {
            Toast.error("Nothing to open on the site");
            return ;
        }
        Sys.run(["quarry-browser", target, root.name || ""], function(ok) {
            if (ok)
                return ;

            if (Shell.browser) {
                Shell.browser.openUrl(target);
                return ;
            }
            Toast.show("Opening it in your own browser — quarry-browser is not installed");
            Sys.open(target);
        });
    }

    function open(ctx) {
        root.context = ctx || null;
        root.isOpen = true;
        root.opened();
    }

    function close() {
        if (!root.isOpen)
            return ;

        root.isOpen = false;
        root.closedDown();
    }

    function goBack() {
        if (root.canGoBack)
            root.backRequested();

    }

    onActiveChanged: {
        if (root.active) {
            root.activated();
        } else {
            root.close();
            root.deactivated();
        }
    }
    // A lens is logic, not layout — the host parents it off-screen and draws
    // its skin instead.
    visible: false
    width: 0
    height: 0
}
