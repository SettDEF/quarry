pragma Singleton
import QtQuick

/*
 * DEPRECATED — the extension system is now the LENS system (Lenses.qml).
 *
 * A lens is what an extension was, plus the two things it needed and did not
 * have: the sources it applies to, and skins. Everything here forwards, so the
 * call sites that still say `Extensions` keep working while they are renamed —
 * several of them belong to other people right now.
 *
 * Nothing new should be written against this. Delete it once
 * `services/Ipc.qml`, `modules/gallery/SettingsMenu.qml`, `SettingsPanel.qml`,
 * `LayoutMenu.qml` and `GalleryContext.qml` say `Lenses`.
 */
QtObject {
    id: root

    readonly property var catalog: Lenses.catalog
    readonly property int count: Lenses.count
    readonly property int enabledCount: Lenses.enabledCount
    readonly property bool scanning: Lenses.scanning
    readonly property var live: Lenses.live
    readonly property var menuItems: Lenses.menuItems
    readonly property var contextMocks: Lenses.contextMocks
    readonly property var mockPacks: Lenses.mockPacks

    signal catalogUpdated
    signal extensionError(string id, string message)

    function isEnabled(id) {
        return Lenses.isEnabled(id);
    }
    function setEnabled(id, on) {
        Lenses.setEnabled(id, on);
    }
    function toggle(id) {
        Lenses.toggle(id);
    }
    function find(id) {
        return Lenses.find(id);
    }
    function instanceOf(id) {
        return Lenses.instanceOf(id);
    }
    function rescan() {
        Lenses.rescan();
    }
    function containerReady(item) {
        Lenses.containerReady(item);
    }

    property Connections _relay: Connections {
        target: Lenses
        function onCatalogUpdated() {
            root.catalogUpdated();
        }
        function onLensError(id, message) {
            root.extensionError(id, message);
        }
    }
}
