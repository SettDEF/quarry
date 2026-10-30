import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/*
 * The source page, inside quarry.
 *
 * A result is a link to somewhere, and shelling out to the desktop browser
 * threw away everything quarry knows: a video page showed as its poster frame
 * and the pictures on it could only come back by hand. So the page opens here,
 * over the gallery, and a right-click on a picture in it goes straight into the
 * catalogue.
 *
 * This file deliberately does NOT import QtWebEngine — see BrowserEngine.qml.
 * Everything here is chrome, and it draws the same with or without the engine,
 * so a machine missing qt6-webengine gets a sentence rather than a blank window.
 */
Item {
    id: root

    property string pendingUrl: ""
    readonly property bool open: root.pendingUrl.length > 0
    /// The engine, once loaded. Null whenever WebEngine is unavailable, so
    /// every binding below has to tolerate that — which is the whole point.
    readonly property var engine: engineLoader.item

    visible: root.open
    focus: root.open

    function openUrl(url) {
        const target = String(url || "").trim();
        if (target.length === 0) {
            Toast.error("That result has no page to open");
            return;
        }
        root.pendingUrl = target;
        if (root.engine)
            root.engine.load(target);
        root.forceActiveFocus();
    }

    function close() {
        root.pendingUrl = "";
    }

    function openOutside() {
        const url = root.engine ? String(root.engine.currentUrl) : root.pendingUrl;
        Sys.open(url);
        Toast.show("Handed to your browser");
    }

    /*
     * WHY THE ENGINE IS GATED ON AN ARGUMENT LIST.
     *
     * Qt WebEngine asks Qt for the process's arguments to build Chromium's
     * command line, and calls qFatal when that list is empty. Quickshell 0.3.1
     * constructs the application with no arguments at all (`Qt.application
     * .arguments` is `[]`, measured), so merely instantiating a WebEngineView
     * under `qs` aborts the whole app — a Loader cannot catch it, because it is
     * not a QML error.
     *
     * So the condition Qt WebEngine itself fatals on is the condition checked
     * here, and quarry shows the panel below instead of dying. The day
     * quickshell passes its argv through, this starts working with no change.
     */
    readonly property bool engineAllowed: Qt.application.arguments.length > 0
    readonly property bool engineReady: engineLoader.status === Loader.Ready && !!root.engine
    readonly property string engineProblem: {
        if (!Prefs.browserEnabled)
            return "The in-app browser is switched off in Settings › Browser.";
        if (!root.engineAllowed)
            return "quickshell starts Qt with an empty argument list, and Qt WebEngine refuses to run without one — it would abort the whole app. Pages open in your own browser until quickshell passes its arguments through.";
        if (engineLoader.status === Loader.Error)
            return "qt6-webengine is not installed. Install it, or keep opening pages in your own browser.";
        return "";
    }

    // Escape has to come back from the page, which owns the keyboard while it
    // has focus — a Keys handler on this item never sees it.
    Shortcut {
        sequences: ["Escape"]
        enabled: root.open
        onActivated: {
            if (root.engine && root.engine.loading)
                root.engine.stop();
            else
                root.close();
        }
    }
    Shortcut {
        sequences: ["Alt+Left", "Back"]
        enabled: root.open
        onActivated: {
            if (root.engine && root.engine.canGoBack)
                root.engine.goBack();
            else
                root.close();
        }
    }
    Shortcut {
        sequences: ["Alt+Right", "Forward"]
        enabled: root.open && !!root.engine && root.engine.canGoForward
        onActivated: root.engine.goForward()
    }
    Shortcut {
        sequences: [StandardKey.Refresh, "F5"]
        enabled: root.open && !!root.engine
        onActivated: root.engine.reload()
    }

    // The ground. Opaque, because a half-lit web page over a gallery is
    // unreadable and the gallery underneath is still decoding thumbnails.
    Rectangle {
        anchors.fill: parent
        color: Appearance.colors.colLayer0

        // Nothing underneath gets the pointer or the wheel while this is up.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onWheel: wheel => wheel.accepted = true
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 10

        // ── chrome ──────────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 60
            radius: Appearance.rounding.normal
            color: Appearance.colors.colLayer1

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                spacing: 4

                IconButton {
                    icon: "arrow_back"
                    tooltip: "Back  ·  Alt+←"
                    enabled: !!root.engine && root.engine.canGoBack
                    onClicked: root.engine.goBack()
                }
                IconButton {
                    icon: "arrow_forward"
                    tooltip: "Forward  ·  Alt+→"
                    enabled: !!root.engine && root.engine.canGoForward
                    onClicked: root.engine.goForward()
                }
                IconButton {
                    readonly property bool busy: !!root.engine && root.engine.loading
                    icon: busy ? "close" : "refresh"
                    tooltip: busy ? "Stop" : "Reload  ·  F5"
                    enabled: !!root.engine
                    onClicked: busy ? root.engine.stop() : root.engine.reload()
                }

                // ── title over URL: what the page says it is, and where it is ──
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 8
                    Layout.rightMargin: 8
                    spacing: 0

                    StyledText {
                        Layout.fillWidth: true
                        text: {
                            if (root.engineProblem.length > 0)
                                return "Can't show this page here";
                            const t = root.engine ? root.engine.pageTitle : "";
                            return t.length > 0 ? t : "Loading…";
                        }
                        font.pixelSize: Appearance.font.pixelSize.small
                        font.weight: Font.DemiBold
                        color: Appearance.colors.colOnLayer1
                        elide: Text.ElideRight
                    }

                    // The URL is a fact you copy, not a field you type in: this
                    // is a viewer for a result's own page, not an address bar.
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 20
                        radius: Appearance.rounding.verysmall
                        color: urlMouse.containsPress ? Appearance.colors.colLayer1Active : urlMouse.containsMouse ? Appearance.colors.colLayer1Hover : ColorUtils.transparentize(Appearance.colors.colLayer1Hover, 1)
                        Behavior on color {
                            animation: Appearance.animation.stateChange.colorAnimation.createObject(this)
                        }

                        StyledText {
                            id: urlLabel
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: 4
                            anchors.rightMargin: 4
                            text: {
                                const hovered = root.engine ? root.engine.hoveredLink : "";
                                if (hovered.length > 0)
                                    return hovered;
                                return root.engine && String(root.engine.currentUrl).length > 0 ? String(root.engine.currentUrl) : root.pendingUrl;
                            }
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            font.family: Appearance.font.family.monospace
                            color: Appearance.colors.colSubtext
                            elide: Text.ElideRight
                        }

                        MouseArea {
                            id: urlMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                Sys.copyText(urlLabel.text);
                                Toast.show("Address copied");
                            }
                        }

                        StyledToolTip {
                            visible: urlMouse.containsMouse
                            text: "Click to copy"
                        }
                    }
                }

                IconButton {
                    icon: "add_photo_alternate"
                    tooltip: "Add the biggest picture on this page  ·  or right-click any picture"
                    enabled: !!root.engine
                    onClicked: root.engine.pullLargest()
                }
                IconButton {
                    icon: "open_in_new"
                    tooltip: "Open in my browser"
                    onClicked: root.openOutside()
                }
                IconButton {
                    icon: "close"
                    tooltip: "Close  ·  Esc"
                    onClicked: root.close()
                }
            }

            // ── the progress line, along the card's own bottom edge ─────────
            Rectangle {
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.leftMargin: Appearance.rounding.normal
                height: 2
                radius: 1
                color: Appearance.colors.colPrimary
                readonly property real span: parent.width - Appearance.rounding.normal * 2
                width: root.engine ? span * Math.max(0, Math.min(100, root.engine.progress)) / 100 : 0
                // Gone once the page is up, rather than a full bar left lying
                // under every finished page.
                opacity: !!root.engine && root.engine.loading ? 1 : 0
                Behavior on width {
                    NumberAnimation {
                        duration: Appearance.animation.elementMoveFast.duration
                        easing.type: Appearance.animation.elementMoveFast.type
                        easing.bezierCurve: Appearance.animation.elementMoveFast.bezierCurve
                    }
                }
                Behavior on opacity {
                    animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                }
            }
        }

        // ── the page ────────────────────────────────────────────────────────
        Rectangle {
            id: pageCard
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Appearance.rounding.normal
            color: Appearance.colors.colLayer1
            clip: true

            Loader {
                id: engineLoader
                anchors.fill: parent
                // By URL, never by type: naming BrowserEngine here would pull
                // the QtWebEngine import into this file's compile.
                source: root.open && Prefs.browserEnabled && root.engineAllowed ? Qt.resolvedUrl("BrowserEngine.qml") : ""
                asynchronous: true

                onLoaded: {
                    engineLoader.item.startUrl = root.pendingUrl;
                    engineLoader.item.pulled.connect(function (path) {
                        Toast.show("Added " + path.replace(/^.*\//, ""));
                    });
                    engineLoader.item.pullFailed.connect(function (why) {
                        Toast.error("Could not add that picture — " + why);
                    });
                    engineLoader.item.loadFailed.connect(function (why) {
                        Toast.error(why);
                    });
                }
            }

            // ── what to say when there is no engine ────────────────────────
            ColumnLayout {
                anchors.centerIn: parent
                width: Math.min(parent.width - 96, 460)
                visible: root.engineProblem.length > 0
                spacing: 12

                MaterialSymbol {
                    Layout.alignment: Qt.AlignHCenter
                    text: "public_off"
                    iconSize: 44
                    color: Appearance.colors.colSubtext
                }
                StyledText {
                    Layout.fillWidth: true
                    text: "This page opens in your browser"
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: Appearance.font.pixelSize.large
                    font.weight: Font.DemiBold
                    color: Appearance.colors.colOnLayer1
                }
                StyledText {
                    Layout.fillWidth: true
                    text: root.engineProblem
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                }
                TextButton {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.topMargin: 4
                    variant: "tonal"
                    icon: "open_in_new"
                    text: "Open in my browser"
                    onClicked: {
                        root.openOutside();
                        root.close();
                    }
                }
            }

            // `clip` is rectangular, so a web page squares off over the card's
            // four corners without these. See RoundedCorners.
            RoundedCorners {
                radius: pageCard.radius
                background: Appearance.colors.colLayer0
                borderWidth: 0
            }
        }
    }
}
