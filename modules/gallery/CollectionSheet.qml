import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

/*
 * Where a picture is kept.
 *
 * Two jobs, deliberately in one surface: putting the item in front of you into
 * a collection, and going to a collection to see what is in it. They are the
 * same list, and splitting them would mean two panels that each show half of
 * what you want to know — whether this is already kept, and what else is.
 */
Sheet {
    id: root

    property var item: null

    surfaceWidth: 380
    surfaceHeight: Math.max(280, Math.min(520, layout.implicitHeight + 32))

    function openFor(picked) {
        root.item = picked;
        Catalog.refreshCollections();
        if (picked)
            Catalog.collectionsOf(picked);
        root.open = true;
    }

    function belongs(name) {
        return Catalog.collectionsOfItem.indexOf(name) >= 0;
    }

    ColumnLayout {
        id: layout
        anchors.fill: parent
        anchors.margins: 16
        spacing: 10

        RowLayout {
            Layout.fillWidth: true

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                StyledText {
                    text: root.item ? "Keep this" : "Collections"
                    font.pixelSize: Appearance.font.pixelSize.larger
                    font.weight: Font.DemiBold
                    color: Appearance.colors.colOnLayer1
                }

                StyledText {
                    visible: root.item !== null
                    text: root.item ? (root.item.title && root.item.title.length > 0 ? root.item.title : root.item.slug) : ""
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    color: Appearance.colors.colSubtext
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
            }

            IconButton {
                icon: "close"
                size: 30
                onClicked: root.close()
            }
        }

        // Naming a new one is the common case the first few times, so it is a
        // field rather than a button that reveals a field.
        MaterialTextField {
            id: newName
            Layout.fillWidth: true
            placeholder: "New collection…"
            leadingIcon: "bookmark_add"
            onAccepted: {
                if (text.trim().length === 0)
                    return;
                Catalog.keep(root.item, text.trim(), true);
                text = "";
            }
        }

        Divider {
            Layout.fillWidth: true
        }

        StyledListView {
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(300, Math.max(80, contentHeight))
            clip: true
            spacing: 2
            model: Catalog.collections

            delegate: Rectangle {
                required property var modelData
                width: ListView.view.width
                height: 40
                radius: Appearance.rounding.small
                color: rowHover.hovered ? Appearance.colors.colLayer2Hover : "transparent"

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    spacing: 10

                    MaterialSymbol {
                        // Filled when this item is already in it — the question
                        // "have I kept this?" answered without reading.
                        text: root.item && root.belongs(modelData.name) ? "bookmark" : "bookmark_border"
                        iconSize: 18
                        color: root.item && root.belongs(modelData.name) ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                    }

                    StyledText {
                        Layout.fillWidth: true
                        text: modelData.name
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: Appearance.colors.colOnLayer1
                        elide: Text.ElideRight
                    }

                    StyledText {
                        text: modelData.items
                        font.family: Appearance.font.family.monospace
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: Appearance.colors.colSubtext
                    }

                    // Opening a collection is a different act from keeping
                    // something in it, so it is a different control.
                    IconButton {
                        icon: "arrow_forward"
                        size: 28
                        tooltip: "Show what is in it"
                        onClicked: {
                            Catalog.query = `in:${modelData.name}`;
                            root.close();
                        }
                    }
                }

                HoverHandler {
                    id: rowHover
                    cursorShape: Qt.PointingHandCursor
                }

                TapHandler {
                    onTapped: {
                        if (!root.item) {
                            Catalog.query = `in:${modelData.name}`;
                            root.close();
                            return;
                        }
                        Catalog.keep(root.item, modelData.name, !root.belongs(modelData.name));
                    }
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: Catalog.collections.length === 0
            text: "Nothing kept yet. Name one above, and it is made when you use it."
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            wrapMode: Text.WordWrap
        }
    }
}
