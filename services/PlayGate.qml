pragma Singleton
import QtQuick
import qs.modules.common

/*
 * WHICH TILES MAY PLAY, when playing is not something you hover for.
 *
 * Hover playback needs no gate: the pointer is in one place, so exactly one
 * tile is ever alive. "Play what I can see" has no such limit — a wall shows
 * forty tiles, and forty live decoders is not a feature, it is a stuttering
 * scroll and a fan. The budget in PLAN.md is 60 fps while scrolling a 5k
 * window, and a decoder costs far more than a tile.
 *
 * So a tile asks for a SLOT rather than simply playing. A small number of
 * slots go to the tiles nearest the middle of the view — the ones you are
 * actually looking at — and everything else holds still. A tile that scrolls
 * away gives its slot up and the next one in takes it.
 *
 * Modelled on ThumbGate, which solves the same shape for decoding: claim,
 * rank by distance from the viewport centre, admit a few. The difference is
 * that a decode finishes and a video does not, so this is an election that is
 * re-run rather than a queue that drains.
 */
QtObject {
    id: root

    /*
     * Three, and not more, from measuring what a tile costs rather than
     * guessing: hover playback was built around there being exactly one live
     * MediaPlayer, so this is the number that keeps the wall near that while
     * still looking like several things are moving at once.
     */
    // 0 means "all in view": tiles gate themselves on visibility, so no cap here.
    property int slots: Prefs.autoplaySlots === 0 ? 1000 : Math.max(1, Prefs.autoplaySlots)

    /// token -> priority. Lower is nearer the middle of the view.
    property var _claims: ({})
    /// The tokens currently allowed to play.
    property var _holders: ({})
    /// Bumped whenever `_holders` changes, so bindings re-read it — a plain
    /// object mutated in place notifies nothing.
    property int revision: 0

    /// Which tiles hold a slot, not just how many. The count alone cannot show
    /// that the election FOLLOWS the scroll, which is the whole point of
    /// ranking by distance — so the identities are reportable.
    readonly property var holderList: root.revision >= 0 ? Object.keys(root._holders) : []
    readonly property int playing: root.revision >= 0 ? Object.keys(root._holders).length : 0
    readonly property int waiting: root.revision >= 0
        ? Math.max(0, Object.keys(root._claims).length - Object.keys(root._holders).length) : 0

    function claim(token, priority) {
        if (!token)
            return ;

        root._claims[token] = priority;
        root._schedule();
    }

    function release(token) {
        if (!token || root._claims[token] === undefined)
            return ;

        delete root._claims[token];
        root._schedule();
    }

    function holds(token) {
        // `revision` is read so this re-evaluates when the election changes;
        // `_holders` is mutated in place and cannot notify on its own.
        return root.revision >= 0 && root._holders[token] === true;
    }

    /*
     * COALESCED, for the same reason ThumbGate defers its pump.
     *
     * A scroll moves every visible tile's priority in one turn of the event
     * loop. Re-running the election per claim would run it forty times and
     * hand the slots to whichever tile happened to update first — which is
     * delegate order, not distance. One run per turn sees the whole picture.
     */
    function _schedule() {
        if (root._pending)
            return ;

        root._pending = true;
        Qt.callLater(root._elect);
    }

    property bool _pending: false

    function _elect() {
        root._pending = false;
        const tokens = Object.keys(root._claims);
        tokens.sort(function (a, b) {
            return root._claims[a] - root._claims[b];
        });

        const next = {
        };
        for (let i = 0; i < tokens.length && i < root.slots; i++)
            next[tokens[i]] = true;

        /*
         * Only publish a CHANGE.
         *
         * Scrolling re-runs this constantly and the winners usually stay the
         * same; bumping `revision` regardless would re-evaluate every tile's
         * binding on every frame of a scroll, which is the cost this gate
         * exists to avoid.
         */
        const before = Object.keys(root._holders);
        const after = Object.keys(next);
        let same = before.length === after.length;
        if (same) {
            for (let i = 0; i < after.length; i++) {
                if (root._holders[after[i]] !== true) {
                    same = false;
                    break;
                }
            }
        }
        // Nearest the middle wins the sound (tokens are sorted by distance). It moves even
        // when the set of players does not, so it is chosen before the early return.
        const voice = tokens.find(t => next[t] === true) || "";
        if (voice !== root.soundToken)
            root.soundToken = voice;
        if (same)
            return ;

        root._holders = next;
        root.revision++;
    }

    /*
     * HOW LONG THE NEWEST PLAYER SHOULD BE WATCHED.
     *
     * The dwell used to be one number for everything, which is wrong in both
     * directions: eight seconds is most of a six-second clip and nothing at
     * all of a ten-minute one. A tile reports its video's length when it
     * starts, and the dwell is worked out from that.
     *
     * 0 means nothing has reported one — a picture, or a video whose length
     * nobody measured — and the caller falls back to the fixed seconds.
     */
    property real lastDuration: 0
    /// The playing tile nearest the middle: the only autoplay tile with sound.
    property string soundToken: ""

    function report(token, seconds) {
        if (root._holders[token] === true)
            root.lastDuration = Number(seconds) || 0;

    }

    /// Everything stops: the detail view opened, or autoplay was switched off.
    function clear() {
        root._claims = ({});
        root._holders = ({});
        root.revision++;
    }
}
