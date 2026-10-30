import qs.modules.common
import QtQuick

/*
 * A VIEW THAT KNOWS WHERE IT WAS.
 *
 * Attach it to any Flickable and give it a name:
 *
 *     RememberScroll { view: wall; key: `gallery:${Prefs.layoutMode}` }
 *
 * and that view opens where you left it — after switching screens, after
 * closing quarry, after a restart.
 *
 * WHY THIS IS ONE COMPONENT AND NOT FIVE COPIES
 *
 * Five surfaces want it: the wall, the grid, a lens's feed, a lens's
 * conversation and the rail. Each one needs the same four awkward details,
 * and each would get a different one of them wrong:
 *
 *   · DO NOT SAVE WHILE RESTORING. Setting contentY fires the change handler,
 *     which saves the position it just restored — harmless until the restore
 *     is clamped, at which point the saved position walks toward zero every
 *     launch.
 *   · DO NOT RESTORE INTO NOTHING. A view whose rows have not arrived has a
 *     contentHeight of zero and silently clamps any position to zero, so the
 *     restore has to wait until there is something to scroll.
 *   · WRITE RARELY. A scroll is hundreds of position changes a second and the
 *     settings file is on disk.
 *   · A NAME CAN CHANGE. Opening another subreddit is a different screen, so
 *     the old one is saved and the new one restored rather than the position
 *     carrying across.
 */
Item {
    id: root

    /// The Flickable (or ListView / GridView) to remember.
    property Item view: null
    /// What this screen is called. Empty means "do not remember this one".
    property string key: ""
    /// Restoring is pointless below this: a screen with two rows has no
    /// position worth keeping.
    property real minimumContent: 1

    property bool _restored: false
    property bool _restoring: false

    visible: false

    function save() {
        if (root._restoring || root.key.length === 0 || !root.view)
            return;
        Prefs.rememberPosition(root.key, root.view.contentY);
    }

    function restore() {
        if (root._restored || root.key.length === 0 || !root.view)
            return;
        // Nothing to scroll yet: the rows have not arrived, and a position
        // set now would be clamped to zero and then saved as zero.
        if (root.view.contentHeight <= root.minimumContent || root.view.height <= 0)
            return;
        const want = Prefs.positionFor(root.key);
        root._restored = true;
        if (want <= 0)
            return;
        root._restoring = true;
        root.view.contentY = Math.min(want, Math.max(0, root.view.contentHeight - root.view.height));
        root._restoring = false;
    }

    // A new name is a new screen: keep the old one's place, then take up the
    // new one's.
    onKeyChanged: {
        root._restored = false;
        root.restore();
    }

    Connections {
        target: root.view

        function onContentYChanged() {
            writeBack.restart();
        }

        function onContentHeightChanged() {
            root.restore();
        }
    }

    /*
     * The delay is deliberate rather than tuned: half a second after you stop
     * moving is far too slow to catch a flick in progress, which is exactly
     * the point — what gets written is where you came to rest.
     */
    Timer {
        id: writeBack

        interval: 500
        onTriggered: root.save()
    }

    Component.onCompleted: root.restore()
    // Leaving the screen is the one moment the position is certainly final.
    Component.onDestruction: root.save()
}
