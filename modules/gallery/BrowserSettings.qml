import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

/*
 * The Browser section of the settings panel, as one self-contained card.
 *
 * Kept out of SettingsPanel.qml so it can be dropped in without touching that
 * file: give it `shown` (the page test) and `filter` (the search text) and it
 * behaves like the sections declared inline there.
 *
 *   BrowserSettings { shown: root.page === "browser"; filter: root.filter }
 */
SettingSection {
    id: root

    /// The caller's page test. Rows hide themselves on the search; this hides
    /// the whole card when another page is showing.
    property bool shown: true
    /// Lower-cased search text from the panel, passed down to every row.
    property string filter: ""

    title: "In-app browser"
    footer: root.available ? "Pages open over the gallery, off the record — nothing is written to disk but the pictures you add. Right-click a picture in a page to put it in your catalogue." : "Qt WebEngine will not start in a process with no argument list, and that is how quickshell starts quarry. Until that changes, a source page opens in your own browser."

    /// Whether the engine could run here at all. Qt WebEngine refuses to start
    /// when the process has no argument list, which is how quickshell starts
    /// it — see BrowserView.qml for the whole story.
    readonly property bool available: Qt.application.arguments.length > 0
    /// One reason, said once: a row is off because the engine cannot run, or
    /// because the browser itself is switched off. Never "not wired up".
    readonly property string offNote: root.available ? "browser off" : "unavailable"

    visible: root.shown && root.visibleRows > 0

    SettingRow {
        filter: root.filter
        icon: "captive_portal"
        label: "Read pages inside quarry"
        description: "Open a result's source page over the gallery instead of switching to your browser."
        terms: "web browser webengine embedded in-app"
        available: root.available
        unavailableNote: "unavailable"
        hasSwitch: true
        checked: Prefs.browserEnabled
        onToggled: on => Prefs.browserEnabled = on
    }

    SettingRow {
        filter: root.filter
        icon: "open_in_new"
        label: "\"Source\" opens it here"
        description: "Off, Source hands the page to your own browser. The in-app browser still has a button to pass it on."
        terms: "source page link external default"
        available: root.available && Prefs.browserEnabled
        unavailableNote: root.offNote
        hasSwitch: true
        checked: Prefs.browserSourceInApp
        onToggled: on => Prefs.browserSourceInApp = on
    }

    SettingRow {
        filter: root.filter
        icon: "history_toggle_off"
        label: "Remember cookies and history"
        description: "Off, every page is read off the record and nothing survives closing quarry."
        terms: "private incognito cookies history off the record persist"
        available: root.available && Prefs.browserEnabled
        unavailableNote: root.offNote
        hasSwitch: true
        checked: Prefs.browserPersist
        onToggled: on => Prefs.browserPersist = on
    }

    SettingRow {
        filter: root.filter
        icon: "delete_sweep"
        label: "Clear browsing data"
        description: "Throws away the cache, any stored cookies, and pictures pulled from pages that quarry has already taken in."
        terms: "clear delete cache cookies browsing data privacy"
        destructive: true
        onClicked: {
            // Both halves, whichever mode the browser is in: the profile's own
            // cache, and the pull directory the downloads land in.
            if (Shell.browser && Shell.browser.engine)
                Shell.browser.engine.clearData();
            else
                Sys.run(["bash", "-c", `rm -rf ${JSON.stringify(Sys.home + "/.cache/quarry/browser-pulls")} ${JSON.stringify(Sys.home + "/.cache/quarry/browser")}`]);
            Toast.show("Browsing data cleared");
        }
    }
}
