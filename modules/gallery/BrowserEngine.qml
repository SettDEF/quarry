import qs.modules.common
import qs.services
import QtQuick
import QtWebEngine

/*
 * THE ONLY FILE IN QUARRY THAT IMPORTS QtWebEngine.
 *
 * It is never referenced by type — BrowserView loads it by URL through a
 * Loader, so a machine without qt6-webengine gets a Loader error and a
 * sentence rather than a QML file that will not compile. Everything the chrome
 * needs is re-published here as plain properties and signals, which is also
 * what keeps BrowserView free of the import.
 */
Item {
    id: root

    property url startUrl: ""

    // What the chrome binds to. Mirrors rather than aliases: an alias would
    // drag WebEngineView's type into anything that touches them.
    readonly property url currentUrl: view.url
    readonly property string pageTitle: view.title
    readonly property bool loading: view.loading
    readonly property int progress: view.loadProgress
    readonly property bool canGoBack: view.canGoBack
    readonly property bool canGoForward: view.canGoForward
    property string hoveredLink: ""
    /// The image the pointer last sat on, so a toolbar button can pull it too.
    property string lastImageUrl: ""

    signal pulled(string path)
    signal pullFailed(string reason)
    signal loadFailed(string reason)

    function load(u) {
        view.url = u;
    }
    function goBack() {
        view.goBack();
    }
    function goForward() {
        view.goForward();
    }
    function reload() {
        view.reload();
    }
    function stop() {
        view.stop();
    }

    /*
     * The toolbar's route to the same place: the biggest picture on screen.
     *
     * `DownloadImageToDisk` only works on whatever the last context menu
     * pointed at, so a button cannot use it. This asks the page instead —
     * fetch the picture in its own session and hand the bytes back as a blob
     * download, which is a real Chromium download and lands in the same place.
     * A host that refuses cross-origin reads says so rather than half-working.
     */
    function pullLargest() {
        view.runJavaScript(`(function(){
            var best = null, area = 0;
            var imgs = document.images;
            for (var i = 0; i < imgs.length; i++) {
                var r = imgs[i].getBoundingClientRect();
                if (r.bottom < 0 || r.top > innerHeight) continue;
                var a = r.width * r.height;
                if (a > area && a > 10000) { area = a; best = imgs[i]; }
            }
            if (!best) return "none";
            var src = best.currentSrc || best.src;
            fetch(src).then(function (r) { return r.blob(); }).then(function (b) {
                var a = document.createElement("a");
                a.href = URL.createObjectURL(b);
                var name = (src.split("/").pop() || "picture").split("?")[0];
                try { name = decodeURIComponent(name); } catch (e) {}
                a.download = name;
                document.body.appendChild(a);
                a.click();
                a.remove();
            }).catch(function (e) { window.__quarryPullError = String(e); });
            return src;
        })()`, function (result) {
            if (result === "none")
                root.pullFailed("no picture big enough on this page");
            else
                root.lastImageUrl = String(result);
        });
    }

    /// Take the picture under the pointer into the catalogue. See
    /// `onContextMenuRequested` for why this is a web action and not a fetch.
    function pullImage() {
        if (root.lastImageUrl.length === 0) {
            root.pullFailed("point at a picture first");
            return;
        }
        view.triggerWebAction(WebEngineView.DownloadImageToDisk);
    }

    /// Everything reading a page can leave behind, in one place: the cache and
    /// cookies (only written at all when `browserPersist` is on), and the
    /// pictures pulled out of pages, which quarryd has its own copy of by now.
    function clearData() {
        profile.clearHttpCache();
        Sys.run(["bash", "-c", `rm -rf ${JSON.stringify(root.dataDir)} ${JSON.stringify(root.pullDir)}`]);
    }

    readonly property string dataDir: `${Sys.home}/.cache/quarry/browser`
    readonly property string pullDir: `${Sys.home}/.cache/quarry/browser-pulls`

    WebEngineProfile {
        id: profile

        /*
         * OFF THE RECORD BY DEFAULT.
         *
         * No storageName, so nothing — history, cookies, cache, local storage —
         * is written under ~/.local/share. Reading a page inside quarry should
         * not leave a second browser profile on the disk for someone to find.
         */
        offTheRecord: !Prefs.browserPersist
        storageName: Prefs.browserPersist ? "quarry" : ""
        // Named explicitly so "clear browsing data" has one directory to
        // delete rather than guessing at Qt's defaults.
        persistentStoragePath: root.dataDir
        cachePath: root.dataDir

        // Sites serve a different, worse page to anything that reads as a
        // toolkit browser; this is the desktop Chrome string they all expect.
        httpUserAgent: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
        downloadPath: root.pullDir

        onDownloadRequested: function (download) {
            download.downloadDirectory = root.pullDir;
            download.accept();
            download.stateChanged.connect(function () {
                if (download.state === WebEngineDownloadRequest.DownloadCompleted)
                    root._adopt(`${download.downloadDirectory}/${download.downloadFileName}`);
                else if (download.state === WebEngineDownloadRequest.DownloadInterrupted)
                    root.pullFailed(download.interruptReasonString);
            });
        }
    }

    /*
     * A FILE URI, NOT A PATH WITH A SCHEME ON THE FRONT.
     *
     * `adopt` percent-DECODES what it is given, because a drag from a file
     * manager arrives as a URI — so a file Chromium happened to name
     * `…tama%C3%B1os.jpg` (it keeps the encoding from the URL) was decoded back
     * to `…tamaños.jpg`, which is not what is on the disk, and the adopt failed
     * on a file that was sitting right there. Encoding each segment makes the
     * round trip exact for both spellings.
     */
    function _adopt(path) {
        const uri = "file://" + String(path).split("/").map(encodeURIComponent).join("/");
        Catalog.adoptFile(uri, function (item) {
            root.pulled(path);
        });
    }

    WebEngineView {
        id: view
        anchors.fill: parent
        profile: profile
        url: root.startUrl
        backgroundColor: Appearance.colors.colLayer1

        settings {
            // No sound without a click — this opens behind whatever the user is
            // already listening to.
            playbackRequiresUserGesture: true
            screenCaptureEnabled: false
            // A page that opens windows has nowhere to put them here.
            javascriptCanOpenWindows: false
            fullScreenSupportEnabled: true
            pdfViewerEnabled: true
        }

        /*
         * THE PAGE → CATALOGUE PATH, IN ONE STEP.
         *
         * `mediaUrl` is the picture under the pointer, and
         * `DownloadImageToDisk` fetches it through Chromium's own network stack
         * — same cookies, same referer — so hotlink-protected hosts that 403 a
         * bare `curl` still hand it over. The file lands in the pull directory,
         * `downloadRequested` sees it finish, and quarryd's `adopt` takes it
         * from there like any other local file.
         */
        onContextMenuRequested: function (request) {
            request.accepted = true;      // no Chromium menu; quarry draws its own
            if (request.mediaType === ContextMenuRequest.MediaTypeImage) {
                root.lastImageUrl = String(request.mediaUrl);
                view.triggerWebAction(WebEngineView.DownloadImageToDisk);
            } else {
                root.pullFailed("nothing but a picture can be added");
            }
        }

        onLinkHovered: function (url) {
            root.hoveredLink = String(url);
        }

        // A page's own console is the page's business. Left alone it lands in
        // quarry's log as ERROR — Wikimedia Commons alone posts one per visit —
        // and "no errors in the log" stops meaning anything.
        onJavaScriptConsoleMessage: function (level, message, lineNumber, sourceId) {}

        onLoadingChanged: function (info) {
            if (info.status === WebEngineView.LoadFailedStatus)
                root.loadFailed(info.errorString.length > 0 ? info.errorString : "the page would not load");
        }

        // A page that asks for the camera, the microphone or a notification
        // gets a no rather than a dialog: this is a reader, not a session.
        onPermissionRequested: function (permission) {
            permission.deny();
        }

        onNewWindowRequested: function (request) {
            // One view, so a target=_blank link opens here instead of nowhere.
            request.openIn(view);
        }
    }
}
