/*
 * Does the filter drawer still sit exactly on the gallery card?
 *
 * The drawer's whole geometry is read off `Shell.gallery.parent` — shell.qml's
 * content card — so the failure is a rect, not a picture, and it only shows at
 * sizes the window will not take: FloatingWindow reads `Prefs.windowWidth` once
 * and ignores it afterwards, so the real app cannot be resized from IPC.
 *
 * This puts the FilterPanel on a stand-in card with shell.qml's own margins in a
 * window whose size comes from the environment, and hands back both rects:
 *
 *   QGEOM_W=620 QGEOM_H=840 \
 *     ~/.claude/skills/hands-off-desktop/scripts/headless-qt.sh \
 *       env HOME=<private> qs -p filter-geometry.qml
 *   qs ipc --pid <pid> call geom refresh    # the catalogue, which shell.qml loads
 *   qs ipc --pid <pid> call geom rects      # card == cardRect == the surface
 *   qs ipc --pid <pid> call geom scroll 700
 *   qs ipc --pid <pid> call geom grab /tmp/drawer.png
 *
 * Nothing is drawn on the card, which is also what makes it safe to capture.
 * It sits beside shell.qml because `qs -p` roots the `qs.*` imports at the entry
 * file's own directory: from tools/ none of them resolve.
 *
 * NOTE: a config reload leaves an offscreen instance unreachable over IPC — run
 * it from a copy of the tree if anything else is editing this one.
 */
import qs.modules.common
import qs.modules.gallery
import qs.services
import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

ShellRoot {
    FloatingWindow {
        id: win
        title: "geomcheck"
        implicitWidth: parseInt(Quickshell.env("QGEOM_W")) || 1280
        implicitHeight: parseInt(Quickshell.env("QGEOM_H")) || 840
        color: Appearance.colors.colLayer0Base

        Item {
            id: content
            anchors.fill: parent

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 70
                }

                Rectangle {
                    id: card
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.leftMargin: 2
                    Layout.rightMargin: 12
                    Layout.bottomMargin: 12
                    radius: Appearance.rounding.large
                    color: Appearance.colors.colLayer1

                    Item {
                        id: standIn
                        anchors.fill: parent
                        Component.onCompleted: Shell.gallery = standIn
                    }
                }
            }

            FilterPanel {
                id: panel
                open: true
                anchors.fill: parent
                z: 95
            }
        }

        IpcHandler {
            target: "geom"

            function rects(): string {
                const c = card.mapToItem(content, 0, 0);
                return JSON.stringify({
                    "win": [Math.round(win.width), Math.round(win.height)],
                    "card": [Math.round(c.x), Math.round(c.y), Math.round(card.width), Math.round(card.height)],
                    "cardRect": [Math.round(panel.cardRect.x), Math.round(panel.cardRect.y), Math.round(panel.cardRect.width), Math.round(panel.cardRect.height)],
                    "surface": [Math.round(panel.surfaceWidth), Math.round(panel.surfaceHeight)],
                    "inset": Math.round(panel.inset),
                    "topInset": Math.round(panel.topInset),
                    "rows": panel.rows.length,
                    "activeCount": panel.activeCount
                });
            }
            // The drawer's Flickable has no handle from out here; find it by
            // shape, with an explicit stack — IpcHandler rejects a helper that
            // takes an untyped argument.
            function scroll(y: string): string {
                const stack = [panel];
                let f = null;
                while (stack.length > 0 && !f) {
                    const o = stack.shift();
                    const kids = (o && o.children) || [];
                    for (let i = 0; i < kids.length; i++) {
                        const c = kids[i];
                        if (c && c.contentY !== undefined && c.contentHeight > 400) {
                            f = c;
                            break;
                        }
                        stack.push(c);
                    }
                }
                if (!f)
                    return "no flickable";
                f.contentY = Math.max(0, Math.min(parseInt(y) || 0, f.contentHeight - f.height));
                return `contentY=${Math.round(f.contentY)} of ${Math.round(f.contentHeight)}`;
            }
            // shell.qml does this at startup; the harness has to ask.
            function refresh(): string {
                Catalog.load();
                Catalog.refreshFacets();
                return `facets=${Catalog.facetSources.length} count=${Catalog.count}`;
            }
            function q(text: string): string {
                Catalog.query = text || "";
                return Catalog.query;
            }
            function find(text: string): string {
                panel.query = text || "";
                return `filter="${panel.filter}" searching=${panel.searching} sourceFilter="${panel.sourceFilter}"`;
            }
            function groups(json: string): string {
                panel.openGroups = JSON.parse(json);
                return json;
            }
            function grab(path: string): string {
                content.grabToImage(r => r.saveToFile(path));
                return "grabbing " + path;
            }
        }
    }
}
