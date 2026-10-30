import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

/*
 * The full target list, grouped.
 *
 * Every row states the size it will actually produce, because that is the only
 * thing that distinguishes two targets from each other — "Discord avatar" and
 * "Steam avatar (512)" are the same recipe at the same size, and the label
 * alone would make that invisible.
 */
Sheet {
    id: root

    property var item: null

    signal chosen(var item, string targetId)

    surfaceWidth: 420
    surfaceHeight: Math.max(280, Math.min(560, layout.implicitHeight + 32))

    function openFor(picked) {
        root.item = picked;
        root.open = true;
    }

    function recipeLabel(target) {
        const recipe = target.recipe;
        if (recipe.fit === "none")
            return "original size · " + recipe.format;
        return `${recipe.width}×${recipe.height} · ${recipe.fit} · ${recipe.format}`;
    }

    ColumnLayout {
        id: layout
        anchors.fill: parent
        anchors.margins: 16
        spacing: 10

        RowLayout {
            Layout.fillWidth: true

            StyledText {
                text: "Export as…"
                font.pixelSize: Appearance.font.pixelSize.larger
                font.weight: Font.DemiBold
                color: Appearance.colors.colOnLayer1
            }

            Item {
                Layout.fillWidth: true
            }

            IconButton {
                icon: "close"
                onClicked: root.close()
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: root.item !== null
            /*
             * Dimensions only when they are known.
             *
             * Several sources publish no size in a listing — Iconify and
             * AniList among them — and "0×0" is worse than silence: it reads as
             * a broken picture rather than a fact the source did not give.
             */
            text: {
                if (!root.item)
                    return "";
                const size = (root.item.w > 0 && root.item.h > 0) ? `${root.item.w}×${root.item.h}` : (root.item.family === "vector" ? "any size" : "size unknown");
                return `${root.item.slug} · ${size} · ${root.item.family}`;
            }
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            elide: Text.ElideRight
        }

        Divider {
            Layout.fillWidth: true
        }

        StyledListView {
            id: list
            Layout.fillWidth: true
            /*
             * Sized from its rows, not from the space left over.
             *
             * `Layout.fillHeight` inside a layout whose parent takes its height
             * *from* that layout is circular: a list's implicit height is zero,
             * so the sheet collapsed to its header and the targets had nowhere
             * to be drawn. The sheet was a title and an empty box.
             */
            Layout.preferredHeight: Math.min(380, Math.max(120, list.contentHeight))
            clip: true
            spacing: 2
            model: Targets.all

            delegate: Rectangle {
                required property var modelData
                width: list.width
                height: 52
                radius: Appearance.rounding.small
                color: hover.hovered ? Appearance.colors.colLayer2Hover : "transparent"

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    spacing: 12

                    MaterialSymbol {
                        text: modelData.icon
                        iconSize: 20
                        color: Appearance.colors.colOnLayer1
                    }

                    ColumnLayout {
                        spacing: 0
                        Layout.fillWidth: true

                        StyledText {
                            text: modelData.label
                            font.pixelSize: Appearance.font.pixelSize.small
                            color: Appearance.colors.colOnLayer1
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }

                        StyledText {
                            text: root.recipeLabel(modelData)
                            font.family: Appearance.font.family.monospace
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            color: Appearance.colors.colSubtext
                        }
                    }

                    StyledText {
                        visible: Targets.recent.indexOf(modelData.id) >= 0
                        text: "recent"
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: Appearance.colors.colPrimary
                    }
                }

                HoverHandler {
                    id: hover
                    cursorShape: Qt.PointingHandCursor
                }

                TapHandler {
                    onTapped: {
                        root.close();
                        root.chosen(root.item, modelData.id);
                    }
                }
            }
        }
    }
}
