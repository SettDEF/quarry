import QtQuick

/*
 * THE ROW YOU WERE LOOKING AT STAYS WHERE IT WAS.
 *
 * The lens replaces its arrays rather than editing them — a new message is
 * `[message].concat(messages)`, a chat-list refresh is a fresh page — and a
 * ListView given a new JS array resets to its start. So reading a chat's
 * history, any message arriving threw you to the newest; scrolling the chat
 * list, any message in any chat threw you to the top.
 *
 * This notes which row is in the middle of the view and how far from the
 * top it sits, by id, and puts that row back after the model changes. At the
 * edge where the first row is on screen (the newest end of a conversation, the top of the chat
 * list) it does nothing, so new things still arrive in view.
 */
Item {
    id: keep

    property ListView view: null
    /// The same array the view's model is bound to — read here rather than
    /// back through `view.model`, which hands out a copy.
    property var items: []
    property var idOf: m => m && m.id !== undefined ? String(m.id) : ""

    property string _id: ""
    property real _offset: 0
    property bool _atEdge: true
    property bool _fixing: false
    /// The array the note belongs to. The reset moves contentY too, and that
    /// must not overwrite the note before `fix` has used it.
    property var _model: null

    visible: false

    function note() {
        if (keep._fixing || !keep.view)
            return;
        const v = keep.view;
        if (keep._model !== null && keep.items !== keep._model)
            return;
        keep._model = keep.items;
        // At the edge = the first row is on screen. `atYEnd`/`atYBeginning`
        // miss by the list's margins and never read true.
        const first = v.itemAtIndex(0);
        keep._atEdge = !!first && first.y + first.height > v.contentY && first.y < v.contentY + v.height;
        const i = v.indexAt(v.width / 2, v.contentY + v.height / 2);
        const item = i >= 0 ? v.itemAtIndex(i) : null;
        const model = keep.items;
        if (!item || !model || i >= model.length)
            return;
        keep._id = keep.idOf(model[i]);
        keep._offset = item.y - v.contentY;
    }

    function fix() {
        const v = keep.view;
        const model = v ? keep.items : null;
        keep._model = model;
        if (!model || model.length === 0) {
            // A different chat, or a different folder: ids from the last one
            // mean nothing here (Telegram reuses message ids across chats).
            keep._id = "";
            keep._atEdge = true;
            return;
        }
        if (keep._atEdge || keep._id.length === 0)
            return;
        let j = -1;
        for (let k = 0; k < model.length; k++)
            if (keep.idOf(model[k]) === keep._id) {
                j = k;
                break;
            }
        if (j < 0)
            return;
        keep._fixing = true;
        v.positionViewAtIndex(j, ListView.Center);
        const item = v.itemAtIndex(j);
        if (item)
            v.contentY = item.y - keep._offset;
        keep._fixing = false;
    }

    Connections {
        target: keep.view

        function onContentYChanged() {
            keep.note();
        }

    }

    // After the view has taken the new array, not before.
    onItemsChanged: Qt.callLater(keep.fix)
}
