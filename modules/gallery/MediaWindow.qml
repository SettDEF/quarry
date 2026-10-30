import qs.modules.common
import qs.services
import QtQuick
import Quickshell

/*
 * The viewer as a window of its own.
 *
 * Over the gallery, a picture covers the wall it came from: you cannot look at
 * one and keep browsing, and a video holds the whole app hostage. So the same
 * viewer can open here instead, and the wall behind it stays live — scroll it,
 * search it, open a second thing.
 *
 * It is the SAME DetailView, so every action, key and signal behaves the way it
 * does in the main window. Only where it is drawn changes.
 */
FloatingWindow {
    // browser-like scrolling for every list in the window (Momentum.qml)
    MomentumInjector { root: parent }
    id: root

    /// Forwarded from the viewer inside, so shell.qml wires one set of handlers.
    signal exportRequested(var item, string targetId)
    signal targetsRequested(var item)
    signal similarRequested(var item, string method)
    signal wallpaperRequested(var item, string monitor)
    signal copyRequested(var item, string what)
    signal openRequested(var item, string where)
    signal hideRequested(var item)
    signal keepRequested(var item)

    readonly property alias detail: detail
    readonly property bool showing: detail.open

    title: detail.item && detail.item.title ? `${detail.item.title} — quarry` : "quarry"
    color: Appearance.colors.colLayer0Base
    implicitWidth: Prefs.mediaWindowWidth
    implicitHeight: Prefs.mediaWindowHeight
    minimumSize: Qt.size(480, 360)
    visible: false

    function showAt(index, item) {
        // Size and fullscreen are settled BEFORE the window maps: a window that
        // appears and then jumps to fullscreen is a flash of the wrong thing.
        root.fullscreen = Prefs.mediaFullscreen;
        root.visible = true;
        detail.openAt(index, item);
        detail.forceActiveFocus();
    }

    function hide() {
        detail.close();
        root.visible = false;
    }

    function toggleFullscreen() {
        root.fullscreen = !root.fullscreen;
    }

    /*
     * Closing this window must not close quarry.
     *
     * The main window quits the process when it stops being visible (quickshell
     * 0.3.1 never fires `onClosed`, so `visible` is the only signal there is).
     * This one is a viewer: closing it means "I am done with this picture",
     * nothing more, so it only puts the viewer away.
     */
    onVisibleChanged: {
        if (!root.visible && detail.open)
            detail.close();
    }

    // The viewer closing from the inside — Esc, or its close button — takes the
    // window with it, or an empty frame is left sitting on the desktop.
    Connections {
        target: detail
        function onOpenChanged() {
            if (!detail.open && root.visible)
                root.visible = false;
        }
    }

    // Remember the size that was chosen, but never a fullscreen one: it would
    // reopen the next picture the size of the screen.
    onWidthChanged: if (!root.fullscreen && root.width > 0) Prefs.mediaWindowWidth = root.width
    onHeightChanged: if (!root.fullscreen && root.height > 0) Prefs.mediaWindowHeight = root.height

    DetailView {
        id: detail
        anchors.fill: parent
        inOwnWindow: true
        fullscreen: root.fullscreen
        onFullscreenToggled: root.toggleFullscreen()

        onExportRequested: (it, targetId) => root.exportRequested(it, targetId)
        onTargetsRequested: it => root.targetsRequested(it)
        onSimilarRequested: (it, method) => root.similarRequested(it, method)
        onWallpaperRequested: (it, monitor) => root.wallpaperRequested(it, monitor)
        onCopyRequested: (it, what) => root.copyRequested(it, what)
        onOpenRequested: (it, where) => root.openRequested(it, where)
        onHideRequested: it => root.hideRequested(it)
        onKeepRequested: it => root.keepRequested(it)
    }
}
