import qs.modules.common
import qs.modules.widgets
import qs.modules.gallery
import qs.services
import QtQuick
import Quickshell
import Quickshell.Io

/*
 * QUARRY BOARD — a reference board, in its own window.
 *
 * The same idea as RIA (github.com/mckset/RIA) and PureRef: an infinite canvas
 * you pan and zoom, with pictures placed on it freely, so a colour study can be
 * three pictures touching at sizes you chose.
 *
 * A SEPARATE APPLICATION rather than a layout inside quarry, and the split is
 * the right one. Arranging reference is not searching for it: you keep a board
 * open beside the thing you are drawing, for hours, while quarry comes and goes
 * — and a board that only exists inside a picture browser cannot sit next to
 * your canvas without the browser sitting there too.
 *
 * They are not disconnected. Both are clients of the same quarryd over the same
 * socket, so "add to a board" in quarry writes through the daemon and this
 * picks it up. The board holds quarry ids, not paths — which is why it survives
 * a re-crawl, and where RIA loses everything when a folder moves.
 */
ShellRoot {
    id: rootShell

    FloatingWindow {

        // browser-like scrolling for every list in the window (Momentum.qml)

        MomentumInjector { root: parent }
        id: win

        title: "quarry board"
        implicitWidth: 1280
        implicitHeight: 820

        /*
         * A WINDOW YOU CAN SEE THROUGH.
         *
         * `surfaceFormat.opaque: false` is what gives the surface an alpha
         * channel at all — without it the compositor is told the window is
         * opaque and a transparent colour just paints black. The window colour
         * is then fully clear and the GROUND below draws whatever solidity has
         * been asked for, so the transparency is a value rather than a mode.
         *
         * This is the one thing a reference board most wants and RIA does not
         * have: reference that floats over the canvas you are drawing on,
         * instead of a window you have to keep swapping to.
         */
        surfaceFormat.opaque: false
        color: "transparent"

        // Same lesson as quarry's own window: `onClosed` never fires for a
        // compositor close in Quickshell 0.3.1 and `Quickshell.quit()` is not a
        // function there, so a closed window otherwise leaves a live process
        // with no window and no way to get one. `visible` is the signal that
        // actually moves.
        onVisibleChanged: if (!visible) Qt.quit()

        Component.onCompleted: Catalog.refreshBoards()

        /*
         * OPEN A BOARD WHEN THE LIST ARRIVES, NOT ON A CLOCK.
         *
         * This was a 400ms timer, and it raced the socket: `refreshBoards`
         * returns early while the client is still connecting, so the list was
         * still empty when the timer fired and the app sat on "Pick a board"
         * with one board sitting right there in the strip. Reacting to the data
         * cannot race it.
         */
        property bool _opened: false

        Connections {
            target: Catalog
            function onBoardsChanged() {
                if (win._opened || Catalog.board.length > 0 || Catalog.boards.length === 0)
                    return;
                win._opened = true;
                const want = Quickshell.env("QUARRY_BOARD");
                // A named board that does not exist is worth saying nothing
                // about — it will be created the moment something is put on it.
                if (want && want.length > 0 && Catalog.boards.some(b => b.name === want)) {
                    Catalog.openBoard(want);
                    return;
                }
                Catalog.openBoard(Catalog.boards[0].name);
            }
        }

        // The list only arrives once the socket is up, and `Component.onCompleted`
        // usually beats that.
        Connections {
            target: Client
            function onConnectedChanged() {
                if (Client.connected)
                    Catalog.refreshBoards();
            }
        }

        Item {
            anchors.fill: parent

            // The ground is the canvas's own — see GalleryBoard. A second one
            // here would be the very thing that made the transparency look
            // broken: an opaque layer over a window that is not.

            GalleryBoard {
                id: board
                anchors.fill: parent
                anchors.margins: 8
                anchors.topMargin: 8

                // There is nowhere to open a picture TO here — this app has no
                // detail view, deliberately: it is for arranging, and quarry is
                // one keystroke away for looking.
                onActivated: it => board.fitTo(it)
                onContextRequested: (it, sx, sy) => menu.openFor(it, sx, sy)
                onContainerMenuRequested: (entry, sx, sy) => menu.openForContainer(entry, sx, sy)
            }

            /*
             * OFFLINE IS THE INTERESTING FAILURE HERE.
             *
             * quarry without a daemon still has a fixture to draw. A board
             * without one has nothing at all — the geometry lives in the
             * catalogue — so it has to say so rather than showing an empty
             * canvas that looks like a board you lost.
             */
            Rectangle {
                anchors.fill: parent
                visible: !Client.connected
                // Opaque regardless of the transparency setting: a message you
                // can see through is one you cannot read, and this one is the
                // explanation for an empty window.
                color: Appearance.colors.colLayer0Base

                PagePlaceholder {
                    anchors.fill: parent
                    icon: "cloud_off"
                    title: "quarryd is not running"
                    description: "A board lives in the catalogue, so there is nothing to show until "
                        + "the daemon is up. Start quarry, or run quarryd, and this fills in."
                }
            }

            BoardMenu {
                id: menu
                canvas: board

                // Renaming reuses the board's own naming field, which already
                // knows how to be pre-filled — a third text field that looked
                // like the other two and behaved differently would be worse.
                onRenameContainer: entry => board.renameContainer(entry)
            }

            /*
             * The board's own probe — same purpose as quarry's.
             *
             * This app has had more geometry bugs than any other part of the
             * project (an outline reporting empty while visibly full, pieces
             * reloading on every drop, a hit target that moved with the zoom),
             * and every one was a number somebody had to look at a screen to
             * notice.
             */
            IpcHandler {
                target: "board"

                function probe(): string {
                    let members = 0;
                    for (let i = 0; i < Catalog.boardItems.length; i++)
                        if (Catalog.boardItems[i].container > 0)
                            members++;
                    return JSON.stringify({
                        "connected": Client.connected,
                        "board": Catalog.board,
                        "boards": Catalog.boards.length,
                        "pieces": Catalog.boardItems.length,
                        // The model the Repeater is actually given: if this
                        // drifts from `pieces`, delegates are being rebuilt.
                        "pieceRows": board.boardOrder.length,
                        "containers": Catalog.boardContainers.length,
                        "containerRows": board.containerOrder.length,
                        "grouped": members,
                        "drawn": Catalog.boardItems.filter(i => Catalog.boardRecord(i.id) !== null).length,
                        "zoom": Math.round(board.zoom * 1000) / 1000,
                        "viewX": Math.round(board.viewX),
                        "viewY": Math.round(board.viewY),
                        "ground": Prefs.boardGround,
                        "pictureOpacity": Prefs.boardPieces
                    });
                }

                /// Drive the view from a test, so fitting and zooming can be
                /// asserted rather than eyeballed.
                function fit(): string {
                    board.fitAll();
                    return "fitting";
                }

                function zoom(factor: string): string {
                    const f = parseFloat(factor) || 1;
                    board.zoomAt(f, board.width / 2, board.height / 2);
                    return `zoom ${board.zoomTarget}`;
                }

                function open(name: string): string {
                    Catalog.openBoard(name);
                    return `opening ${name}`;
                }
            }

            Snackbar {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 24
            }
        }
    }
}
