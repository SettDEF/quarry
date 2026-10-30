pragma Singleton
import QtQuick

/*
 * Decode gating.
 *
 * Qt loads `asynchronous: true` images on a thread pool, and a wall that asks
 * for two hundred at once does not get them sooner — it gets a stuttering
 * scroll and a pool full of work for tiles that have already left the screen.
 *
 * So tiles ask here before they load. A bounded number are in flight; the rest
 * wait in a queue ordered by distance from the viewport centre, and a tile that
 * scrolls away cancels itself out of the queue entirely.
 */
QtObject {
    id: root

    property int maxInFlight: 8
    property int inFlight: 0
    property var _queue: []          // [{ token, priority, start }]
    property int served: 0
    readonly property int queueLength: root._queue.length

    function request(token, priority, start) {
        /*
         * EVERYTHING QUEUES, INCLUDING WHEN THERE IS ROOM.
         *
         * This used to start any request immediately while a slot was free,
         * which threw the priority away exactly when it mattered. Requests do
         * not trickle in: a page lands and a hundred tiles ask at once, in one
         * turn of the event loop. Whichever eight happened to be first took
         * every slot — and "first" is DOM order, not distance from the
         * viewport, so the pictures you were looking at queued behind ones
         * scrolled far off screen.
         *
         * Queue first, pump second. Within a turn every request is on the queue
         * before any of them is chosen, so `_pump` picks the closest eight
         * rather than the earliest eight. The cost is one array push for a
         * request that could have started right away; the benefit is that the
         * visible screen fills first, every time.
         */
        const q = root._queue;
        q.push({
            "token": token,
            "priority": priority,
            "start": start
        });
        root._queue = q;
        /*
         * DEFERRED, and that is the whole trick.
         *
         * Pumping straight after the push would drain the queue one entry at a
         * time — the first request would still find a free slot and start, and
         * the ordering would never come into play. `Qt.callLater` coalesces:
         * every request made in this turn of the event loop is on the queue
         * before `_pump` runs once, so it chooses from the whole batch.
         */
        Qt.callLater(root._pump);
    }

    function cancel(token) {
        const q = root._queue;
        for (let i = 0; i < q.length; i++) {
            if (q[i].token === token) {
                q.splice(i, 1);
                root._queue = q;
                return true;
            }
        }
        return false;
    }

    // Called when a load finishes, fails, or is abandoned mid-flight.
    function done(token) {
        if (root.cancel(token))
            return;                  // it was still queued, no slot was held
        root.inFlight = Math.max(0, root.inFlight - 1);
        root._pump();
    }

    /*
     * A slot that is never handed back stalls every tile behind it, and the
     * symptom — a wall of placeholders with `inFlight` pinned at the maximum —
     * looks like a network problem rather than a bookkeeping one. So the gate
     * does not trust its callers: anything in flight longer than this is
     * assumed lost and the slot is reclaimed.
     */
    property Timer _watchdog: Timer {
        interval: 4000
        running: root.inFlight > 0
        repeat: true
        onTriggered: {
            if (root.inFlight >= root.maxInFlight && root._queue.length > 0) {
                root.leaked++;
                root.inFlight = Math.max(0, root.inFlight - 1);
                root._pump();
            }
        }
    }

    property int leaked: 0

    function _pump() {
        while (root.inFlight < root.maxInFlight && root._queue.length > 0) {
            const q = root._queue;
            // Lowest priority value first — priority is distance from the
            // viewport centre, so the tile you are looking at wins.
            let best = 0;
            for (let i = 1; i < q.length; i++)
                if (q[i].priority < q[best].priority)
                    best = i;
            const job = q.splice(best, 1)[0];
            root._queue = q;
            root.inFlight++;
            root.served++;
            job.start();
        }
    }
}
