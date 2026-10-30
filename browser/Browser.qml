import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtWebEngine
import "tela-chrome" as Tela

/*
 * THE SITE, IN QUARRY'S CLOTHES — BUILT ON TELA'S.
 *
 * WHY THIS IS A SEPARATE PROGRAM
 *
 * The app runs under quickshell, which constructs Qt with an EMPTY argument
 * list. Qt WebEngine aborts the process when there is none — not a QML error a
 * Loader can catch, an abort — so a web view can never live inside quarry's
 * own process. See browser/main.cpp.
 *
 * WHY IT IS BUILT ON TELA
 *
 * The first version of this window had back, forward and a text field: enough
 * to read one page, which is all a lens needed. It was still not a browser —
 * no tabs, no find, no way to keep two pages open — and this machine already
 * has a browser whose chrome is plain QML with no dependency on its backend.
 *
 * So the tab strip and the find bar ARE tela's, imported from `tela-chrome`,
 * which is a SYMLINK into the tela checkout rather than a copy. Editing
 * `tela/crates/tela-app/qml/chrome/TabStrip.qml` changes this window and
 * tela's at once, and neither project holds a second copy to drift from the
 * first. The contract between them is Theme.qml: twenty-six names, no types.
 *
 * What is NOT shared is the address field. Tela's AddressBar is a display —
 * clicking it opens tela's command palette, which is a subsystem with history,
 * bookmarks and search engines behind it. Quarry keeps its own editable field,
 * which is three lines and does the one thing a lens needs: type an address,
 * go there.
 */
ApplicationWindow {
    // browser-like scrolling for every list in the window (Momentum.qml)
    MomentumInjector { root: parent }
    id: root

    readonly property color ground: "#121317"
    /// Anything the window wants to say, said for a few seconds and no longer.
    property string note: ""
    /// The view the chrome is about: whichever tab is on top.
    readonly property var current: views.itemAt(tabs.currentIndex)

    width: 1280
    height: 860
    // A dump has no window: it is a lens fetching data, not a person opening a
    // page. The engine still loads and runs the page exactly the same.
    visible: !dumpMode
    color: root.ground
    title: (tabs.currentTitle.length > 0 ? tabs.currentTitle : "quarry") + " — quarry"

    /// Quarry's palette in the shape tela's chrome expects — see Theme.qml
    /// for why the tokens are a JS object rather than QML properties.
    readonly property var ui: tokens.tokens

    Theme {
        id: tokens
    }

    /*
     * THE SESSION, KEPT.
     *
     * Declared HERE rather than in C++ deliberately — a profile built in C++
     * never gets a cookie store, so cookies would not survive a restart no
     * matter what path it was given (tela learned this the hard way; the same
     * comment lives in its Main.qml). Without it the window runs off the
     * record: every sign-in pointless, and the third-party cookie flags in
     * main.cpp with nothing to sign into.
     */
    WebEngineProfile {
        id: session

        storageName: "quarry"
        offTheRecord: false
        persistentStoragePath: storageDir
        cachePath: storageDir + "/cache"
        httpCacheType: WebEngineProfile.DiskHttpCache
        persistentCookiesPolicy: WebEngineProfile.ForcePersistentCookies

        /*
         * A page that hands you a file. The alternative is not "no downloads"
         * — it is a link that does nothing when clicked, which reads as the
         * window being broken.
         */
        onDownloadRequested: (download) => {
            download.downloadDirectory = downloadDir;
            download.accept();
            root.note = `Saving ${download.downloadFileName} to Downloads…`;
        }
    }

    Connections {
        target: session

        function onDownloadFinished(download) {
            root.note = download.state === WebEngineDownloadRequest.DownloadCompleted ? `Saved ${download.downloadFileName} to Downloads` : `Download failed: ${download.downloadFileName}`;
            noteTimer.restart();
        }
    }

    Timer {
        id: noteTimer

        interval: 4000
        onTriggered: root.note = ""
    }

    /*
     * THE TABS.
     *
     * A model of what is open, and a view per entry BUILT once and kept — a
     * tab that reloaded every time you came back to it is a tab that lost your
     * scroll position, your form and your video. Only the current one is
     * drawn; the rest keep running, which is what a tab is.
     */
    QtObject {
        id: tabs

        property int currentIndex: 0
        readonly property ListModel model: ListModel {}
        readonly property string currentTitle: {
            const view = root.current;
            return view && view.title ? String(view.title) : "";
        }

        function open(url, activate) {
            /*
             * EVERY ROLE THE DELEGATE REQUIRES HAS TO BE HERE.
             *
             * Tela's TabStrip declares `required property bool muted`, and a
             * delegate missing one required role does not fail loudly — it
             * simply never instantiates, so the strip draws its background
             * and no tabs at all. Tela's own Main.qml carries the same
             * warning over its model; this is that warning collected the
             * hard way from the other side of the contract.
             */
            tabs.model.append({
                "title": "New tab",
                "audible": false,
                "muted": false,
                "startUrl": String(url || "about:blank")
            });
            if (activate !== false)
                tabs.currentIndex = tabs.model.count - 1;
        }

        function close(index) {
            // The last tab closing IS the window closing: a browser with a tab
            // strip and no page is not a state worth having.
            if (tabs.model.count <= 1) {
                root.close();
                return;
            }
            tabs.model.remove(index);
            tabs.currentIndex = Math.min(tabs.currentIndex, tabs.model.count - 1);
        }
    }

    // ── the keys the window keeps ────────────────────────────────────────────
    Shortcut {
        sequences: ["Escape"]
        onActivated: find.visible ? find.visible = false : root.close()
    }

    Shortcut {
        sequences: [StandardKey.Refresh, "F5"]
        onActivated: if (root.current)
            root.current.reload()
    }

    Shortcut {
        sequences: [StandardKey.Back, "Alt+Left"]
        onActivated: if (root.current && root.current.canGoBack)
            root.current.goBack()
    }

    Shortcut {
        sequences: [StandardKey.Find, "Ctrl+F"]
        onActivated: find.visible = true
    }

    Shortcut {
        sequences: ["Ctrl+T"]
        onActivated: {
            tabs.open("about:blank");
            address.forceActiveFocus();
            address.selectAll();
        }
    }

    Shortcut {
        sequences: ["Ctrl+W"]
        onActivated: tabs.close(tabs.currentIndex)
    }

    Shortcut {
        sequences: ["Ctrl+L"]
        onActivated: {
            address.forceActiveFocus();
            address.selectAll();
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        /*
         * TELA'S TAB STRIP, UNCHANGED.
         *
         * Hidden while there is one tab: a strip showing a single tab is a row
         * of chrome that tells you nothing, and this window opens with one.
         */
        Tela.TabStrip {
            Layout.fillWidth: true
            // Served pages carry no chrome: quarry draws its own around the
            // frames it receives, and a tab strip inside the picture would be
            // a second one.
            visible: !serveMode && tabs.model.count > 1
            theme: root.ui
            tabs: tabs.model
            currentIndex: tabs.currentIndex

            onTabActivated: (index) => tabs.currentIndex = index
            onTabClosed: (index) => tabs.close(index)
            // The strip offers a mute button per tab; muting the view is what
            // that is supposed to do, so it does it.
            onTabMuteToggled: (index) => {
                const view = views.itemAt(index);
                if (!view)
                    return;

                view.audioMuted = !view.audioMuted;
                tabs.model.setProperty(index, "muted", view.audioMuted);
            }
            onNewTabRequested: {
                tabs.open("about:blank");
                address.forceActiveFocus();
            }
        }

        // ── the chrome ───────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 46
            visible: !serveMode
            color: ui.sidebar

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                spacing: 4

                ToolButton {
                    enabled: root.current && root.current.canGoBack
                    text: "←"
                    font.pixelSize: 17
                    opacity: enabled ? 1 : 0.35
                    onClicked: root.current.goBack()

                    contentItem: Label {
                        text: parent.text
                        color: ui.text
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                ToolButton {
                    enabled: root.current && root.current.canGoForward
                    text: "→"
                    font.pixelSize: 17
                    opacity: enabled ? 1 : 0.35
                    onClicked: root.current.goForward()

                    contentItem: Label {
                        text: parent.text
                        color: ui.text
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                ToolButton {
                    text: root.current && root.current.loading ? "✕" : "⟳"
                    font.pixelSize: 15
                    onClicked: root.current.loading ? root.current.stop() : root.current.reload()

                    contentItem: Label {
                        text: parent.text
                        color: ui.text
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                /*
                 * QUARRY'S OWN ADDRESS FIELD, NOT TELA'S.
                 *
                 * Tela's AddressBar is a display; clicking it opens a command
                 * palette backed by history, bookmarks and search engines —
                 * a subsystem, not a widget. Half of what this window exists
                 * for is following a link an API could not give you, and that
                 * needs something you can type in.
                 */
                TextField {
                    id: address

                    Layout.fillWidth: true
                    Layout.preferredHeight: 32
                    text: root.current ? root.current.url.toString() : ""
                    color: ui.text
                    selectByMouse: true
                    font.pixelSize: 13
                    onAccepted: {
                        const typed = text.trim();
                        if (typed.length === 0 || !root.current)
                            return;

                        root.current.url = typed.indexOf("://") > 0 || typed.indexOf("about:") === 0 ? typed : "https://" + typed;
                        root.current.forceActiveFocus();
                    }

                    background: Rectangle {
                        radius: ui.rounding
                        color: address.activeFocus ? ui.surfaceActive : ui.surfaceHigh
                        border.width: address.activeFocus ? ui.borderWidth : 0
                        border.color: ui.accent
                    }
                }

                ToolButton {
                    text: "+"
                    font.pixelSize: 17
                    ToolTip.visible: hovered
                    ToolTip.text: "New tab  ·  Ctrl+T"
                    onClicked: {
                        tabs.open("about:blank");
                        address.forceActiveFocus();
                    }

                    contentItem: Label {
                        text: parent.text
                        color: ui.textDim
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                ToolButton {
                    text: "⧉"
                    font.pixelSize: 15
                    ToolTip.visible: hovered
                    ToolTip.text: "Copy this link"
                    onClicked: {
                        address.selectAll();
                        address.copy();
                        address.deselect();
                    }

                    contentItem: Label {
                        text: parent.text
                        color: ui.textDim
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                ToolButton {
                    text: "✕"
                    font.pixelSize: 15
                    ToolTip.visible: hovered
                    ToolTip.text: "Close  ·  Esc"
                    onClicked: root.close()

                    contentItem: Label {
                        text: parent.text
                        color: ui.textDim
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }

        // How far along it is, where a browser puts it.
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 2
            color: ui.border
            visible: root.current !== null && root.current !== undefined && root.current.loading

            Rectangle {
                height: parent.height
                width: parent.width * (root.current ? Math.max(0, Math.min(1, root.current.loadProgress / 100)) : 0)
                color: ui.accent

                Behavior on width {
                    NumberAnimation {
                        duration: ui.durFast
                    }
                }
            }
        }

        // ── the pages ────────────────────────────────────────────────────────
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            Repeater {
                id: views

                model: tabs.model

                delegate: WebEngineView {
                    id: page

                    required property int index
                    required property string startUrl
                    property bool dumped: false

                    anchors.fill: parent
                    // Built once, kept running, and only the current one drawn.
                    visible: page.index === tabs.currentIndex
                    url: page.startUrl
                    profile: session
                    backgroundColor: root.ground

                    // The strip reads its labels from the model, so what a page
                    // calls itself has to get back into it.
                    onTitleChanged: tabs.model.setProperty(page.index, "title", String(page.title || "New tab"))
                    onRecentlyAudibleChanged: tabs.model.setProperty(page.index, "audible", page.recentlyAudible)

                    /*
                     * A link asking for a new window gets a new TAB now rather
                     * than replacing what you were reading — which is what a
                     * browser does, and what the first version of this window
                     * could not do at all.
                     */
                    onNewWindowRequested: (request) => {
                        tabs.open(request.requestedUrl);
                        request.action = WebEngineNewWindowRequest.InNewTab;
                    }

                    // Sites ask for these constantly and the answer is always
                    // the same: no. A lens reads a page; it is not a phone.
                    onFeaturePermissionRequested: (origin, feature) => page.grantFeaturePermission(origin, feature, false)

                    /*
                     * DUMP MODE: ANSWER ONE QUESTION AND GO.
                     *
                     * The page loads exactly as a person would load it — same
                     * profile, same cookies, same engine — then gets a moment
                     * to run whatever it runs, is asked the question, and the
                     * answer goes to stdout as one line. The settle is not
                     * politeness: the numbers a lens comes here for are
                     * written into the page by a script AFTER the load
                     * finishes, so asking at `loadFinished` reads a page its
                     * own JavaScript has not filled in yet.
                     *
                     * Only the first tab dumps: a dump opens exactly one page,
                     * and a second tab answering would be two answers on one
                     * stdout.
                     */
                    function dumpNow(reason) {
                        if (page.dumped)
                            return;

                        page.dumped = true;
                        if (reason.length > 0) {
                            dumpSink.fail(reason);
                            return;
                        }
                        page.runJavaScript(dumpScript, function (result) {
                            dumpSink.answer(typeof result === "string" ? result : JSON.stringify(result));
                        });
                    }

                    onLoadingChanged: (loadRequest) => {
                        if (dumpMode && page.index === 0 && loadRequest.status === WebEngineView.LoadSucceededStatus)
                            settle.restart();

                        if (dumpMode && page.index === 0 && loadRequest.status === WebEngineView.LoadFailedStatus)
                            page.dumpNow(`could not load ${loadRequest.url} — ${loadRequest.errorString}`);

                        if (loadRequest.status === WebEngineView.LoadFailedStatus)
                            failure.text = `Could not load that page — ${loadRequest.errorString}`;
                        else if (loadRequest.status === WebEngineView.LoadStartedStatus)
                            failure.text = "";
                    }

                    Timer {
                        id: settle

                        interval: dumpSettle
                        onTriggered: page.dumpNow("")
                    }

                    Timer {
                        // A page that never finishes must not leave an engine
                        // running for ever behind a lens.
                        running: dumpMode && page.index === 0
                        interval: dumpTimeout
                        onTriggered: page.dumpNow("timed out after " + dumpTimeout + "ms")
                    }
                }
            }
        }

        /*
         * TELA'S FIND BAR, UNCHANGED.
         *
         * Ctrl+F is the shortcut every browser has and the first version of
         * this window did not, which is most of what made it read as a viewer
         * rather than a browser.
         */
        Tela.FindBar {
            id: find

            Layout.fillWidth: true
            visible: false
            theme: root.ui
            page: root.current
        }
    }

    // Downloads and the like, along the bottom, out of the page's way.
    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 30
        visible: root.note.length > 0
        color: ui.sidebar

        Label {
            anchors.centerIn: parent
            width: parent.width - 24
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideMiddle
            text: root.note
            color: ui.textDim
            font.pixelSize: 12
        }
    }

    // Said out loud rather than left as a blank page.
    Label {
        id: failure

        anchors.centerIn: parent
        width: Math.min(parent.width - 80, 520)
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        visible: text.length > 0 && root.current && !root.current.loading
        color: ui.error
        font.pixelSize: 14
    }

    Component.onCompleted: {
        tabs.open(startUrl);
        // `--tab <url>`, repeatable — see main.cpp.
        for (const extra of extraTabs)
            tabs.open(extra, false);
    }
}
