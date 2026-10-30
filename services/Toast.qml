pragma Singleton
import qs.modules.common
import QtQuick

// Snackbar queue. Anything in the app can call Toast.show(...) / Toast.error(...);
// the Snackbar instance in Main.qml renders whatever is current.
QtObject {
    id: root

    property var queue: []
    property var current: null

    readonly property bool active: current !== null

    function show(message, actionText, actionCallback) {
        _enqueue({
            "message": message,
            "actionText": actionText || "",
            "action": actionCallback || null,
            "isError": false
        });
    }

    function error(message, actionText, actionCallback) {
        _enqueue({
            "message": message,
            "actionText": actionText || "",
            "action": actionCallback || null,
            "isError": true
        });
    }

    function _enqueue(entry) {
        const q = root.queue.slice();
        q.push(entry);
        root.queue = q;
        if (!root.current)
            _next();
    }

    function _next() {
        if (!root.queue.length) {
            root.current = null;
            return;
        }
        const q = root.queue.slice();
        root.current = q.shift();
        root.queue = q;
        dismissTimer.restart();
    }

    function dismiss() {
        dismissTimer.stop();
        _next();
    }

    function runAction() {
        const entry = root.current;
        dismiss();
        if (entry && entry.action)
            entry.action();
    }

    property Timer _dismissTimer: Timer {
        id: dismissTimer
        // Errors deserve longer than confirmations, and an offered action
        // needs time to be noticed.
        interval: root.current && (root.current.isError || root.current.actionText) ? 6500 : 3200
        onTriggered: root._next()
    }
}
