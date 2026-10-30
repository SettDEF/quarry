import QtQuick
import qs.services

/*
 * Base type for a lens SKIN — one named look a lens can wear.
 *
 * The host loads it with `lens` already set, fills it to the content area, and
 * throws it away when you pick another. So a skin owns nothing that must
 * survive: no fetch state, no navigation stack, no caches. Everything it draws
 * it reads back out of `lens`.
 *
 * That is what makes a second skin cheap, and why one may look nothing like the
 * rest of quarry — the default skin uses Appearance roles and ii surfaces, and
 * a site skin is free not to.
 */
Item {
    id: root

    /// The lens being drawn. Set by the host before the skin is created.
    property var lens: null

    /*
     * DOES THIS SKIN WANT QUARRY'S CHROME ON TOP OF ITS OWN?
     *
     * False by default, because a skin fills the content area and every one
     * written so far draws its own header with its own title, its own search
     * and its own close button — so the honest default is "I have this".
     * Until now nothing read the property at all and both bars were drawn:
     * two titles, two search fields, two ways out.
     *
     * A skin that wants the host's heading and search above it sets this true.
     * See Lenses.skinDrawsChrome for what it actually hides.
     */
    property bool wantsChrome: false

    /// Drawn behind the skin so an unfilled corner is never the window's
    /// wallpaper. Override for a skin with its own ground.
    property color ground: "transparent"

    /*
     * THE SURFACE THAT SCROLLS, named by the skin that built it.
     *
     * Autoscroll and keyboard navigation used to find it by walking the window
     * and taking the biggest scrollable — which in a two-pane skin is a coin
     * toss between the list you are reading and the sidebar next to it, and in
     * a skin with stacked screens is whichever one was built last.
     *
     * A skin with one list sets it once; a skin with several screens reassigns
     * it as the screen changes, and nothing else has to happen.
     */
    property var scrollable: null

    /// The dock floats over every skin, as it does over the gallery's wall,
    /// and the list it drives is padded by the host so its last row clears it.
    /// A skin whose lists already pad themselves by `Host.bottomInset` says so
    /// here and is left alone.
    property bool padsItself: false

    function _publish() {
        if (root.visible && root.scrollable)
            Host.claimView(root.scrollable, root);
        else
            Host.releaseView(root);
    }

    onScrollableChanged: root._publish()
    onVisibleChanged: root._publish()
    Component.onCompleted: root._publish()
    Component.onDestruction: Host.releaseView(root)
}
