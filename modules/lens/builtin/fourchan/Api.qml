import QtQuick

/*
 * a.4cdn.org, politely.
 *
 * The API asks for one request a second and for conditional requests. Both are
 * enforced here rather than at the call sites, so no screen can forget: every
 * GET goes through one queue with a minimum gap, and every URL remembers its
 * Last-Modified and sends it back. A 304 costs nothing and answers from the
 * copy already in memory — which is most of what a reader does, because going
 * back to a catalogue you just left is the normal move.
 */
QtObject {
    id: root

    readonly property string base: "https://a.4cdn.org"
    /// The documented floor. Not a tuning knob.
    readonly property int minGapMs: 1000

    property bool busy: false
    property int inFlight: 0

    // url -> { lastModified, data }
    property var _cache: ({})
    property var _queue: []
    property double _lastStart: 0

    signal failed(string url, string message)

    /*
     * `onDone(data, error)` — exactly one of the two. A request already queued
     * for the same url is not queued twice; both callers are answered from the
     * one response.
     */
    function get(path, onDone) {
        const url = path.indexOf("http") === 0 ? path : root.base + path;
        for (let i = 0; i < root._queue.length; i++) {
            if (root._queue[i].url === url) {
                root._queue[i].callbacks.push(onDone);
                return;
            }
        }
        const queue = root._queue.slice();
        queue.push({
            "url": url,
            "callbacks": [onDone]
        });
        root._queue = queue;
        root.busy = true;
        root._maybeStart();
    }

    /// Answer straight from memory if this url has been fetched before. Used to
    /// paint a screen you are going back to before the refresh lands.
    function cached(path) {
        const url = path.indexOf("http") === 0 ? path : root.base + path;
        const hit = root._cache[url];
        return hit ? hit.data : null;
    }

    /// Drop everything not yet started — navigating away should not keep the
    /// one-a-second budget spent on a screen nobody is looking at.
    function clearPending() {
        root._queue = [];
        root.busy = root.inFlight > 0;
    }

    function _maybeStart() {
        if (root._queue.length === 0) {
            root.busy = root.inFlight > 0;
            return;
        }
        const wait = root.minGapMs - (Date.now() - root._lastStart);
        if (wait > 0) {
            pump.interval = wait;
            pump.restart();
            return;
        }
        const queue = root._queue.slice();
        const job = queue.shift();
        root._queue = queue;
        root._lastStart = Date.now();
        root._send(job);
        // Keep the pump ticking so the next one leaves a second later.
        if (root._queue.length > 0) {
            pump.interval = root.minGapMs;
            pump.restart();
        }
    }

    function _send(job) {
        root.inFlight++;
        const known = root._cache[job.url];
        const xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return;
            root.inFlight--;
            let data = null;
            let error = "";
            if (xhr.status === 304 && known) {
                data = known.data;
            } else if (xhr.status === 200) {
                try {
                    data = JSON.parse(xhr.responseText);
                    const next = {};
                    for (const k in root._cache)
                        next[k] = root._cache[k];
                    next[job.url] = {
                        "lastModified": xhr.getResponseHeader("Last-Modified") || "",
                        "data": data
                    };
                    root._cache = next;
                } catch (e) {
                    error = "that answer was not JSON";
                }
            } else if (xhr.status === 404) {
                error = "gone — it was pruned or archived";
            } else if (xhr.status === 0) {
                error = "no answer — check the network";
            } else {
                error = "HTTP " + xhr.status;
            }
            if (error.length > 0)
                root.failed(job.url, error);
            for (let i = 0; i < job.callbacks.length; i++)
                if (job.callbacks[i])
                    job.callbacks[i](data, error);
            root.busy = root._queue.length > 0 || root.inFlight > 0;
            root._maybeStart();
        };
        xhr.open("GET", job.url);
        if (known && known.lastModified.length > 0)
            xhr.setRequestHeader("If-Modified-Since", known.lastModified);
        xhr.send();
    }

    property Timer _pump: Timer {
        id: pump
        repeat: false
        onTriggered: root._maybeStart()
    }
}
