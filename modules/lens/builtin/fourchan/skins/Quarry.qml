import qs.modules.common
import qs.modules.lens
import qs.modules.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

/*
 * THE DEFAULT SKIN — the board reader wearing quarry's own clothes.
 *
 * Colour roles, ii surfaces: colLayer0 ground, colLayer1 cards at radius 17,
 * elementMoveFast for anything that moves. Someone who never looks at the site
 * should find this indistinguishable from the rest of the app.
 *
 * It holds no state of its own beyond scroll position: where you are and what
 * has been fetched belong to the lens, which is what lets you change skin
 * mid-thread and land on the same post.
 */
LensSkin {
    id: root

    ground: Appearance.colors.colLayer0

    readonly property var lensRef: root.lens

    // Each screen here IS its own list — see LensSkin.scrollable.
    scrollable: screen.item

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── chrome ───────────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 56
            color: Appearance.colors.colLayer0Base

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 8

                IconButton {
                    icon: "arrow_back"
                    tooltip: root.lensRef.canGoBack ? "Back" : "Close the lens"
                    onClicked: root.lensRef.canGoBack ? root.lensRef.back() : Lenses.close()
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: -2

                    StyledText {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        text: root.lensRef.screenTitle
                        font.pixelSize: Appearance.font.pixelSize.larger
                        font.weight: Font.DemiBold
                        color: Appearance.colors.colOnLayer0
                    }
                    StyledText {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        visible: text.length > 0
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: root.lensRef.errorText.length > 0 ? Appearance.colors.colError : Appearance.colors.colSubtext
                        text: {
                            if (root.lensRef.errorText.length > 0)
                                return root.lensRef.errorText;
                            if (root.lensRef.bulkRunning)
                                return `Adding ${root.lensRef.bulkDone} of ${root.lensRef.bulkTotal}…`;
                            if (root.lensRef.fetching)
                                return "Fetching…";
                            if (root.lensRef.screen === "catalog")
                                return `${root.lensRef.visibleThreads.length} threads`;
                            if (root.lensRef.screen === "thread")
                                return `${root.lensRef.posts.length} posts · ${root.lensRef.threadImages.length} images`;
                            return `${root.lensRef.boards.length} boards`;
                        }
                    }
                }

                MaterialTextField {
                    Layout.preferredWidth: 220
                    visible: root.lensRef.screen === "catalog"
                    leadingIcon: "search"
                    placeholder: "Filter this catalogue"
                    text: root.lensRef.filter
                    onEdited: value => root.lensRef.filter = value
                    onCleared: root.lensRef.filter = ""
                }

                // A thread is a conversation and a wall of pictures. Both, one
                // button apart, rather than one of them buried in a menu.
                PillTabBar {
                    visible: root.lensRef.screen === "thread" || root.lensRef.screen === "images"
                    tabs: [
                        {
                            "id": "thread",
                            "icon": "forum",
                            "label": "Posts"
                        },
                        {
                            "id": "images",
                            "icon": "grid_view",
                            "label": `Pictures ${root.lensRef.threadImages.length}`
                        }
                    ]
                    current: root.lensRef.screen
                    onTabSelected: id => id === "images" ? root.lensRef.showImages() : root.lensRef.screen = "thread"
                }

                IconButton {
                    visible: root.lensRef.screen === "thread"
                    icon: root.lensRef.spoilersShown ? "visibility" : "visibility_off"
                    toggled: root.lensRef.spoilersShown
                    tooltip: "Spoilers"
                    onClicked: root.lensRef.spoilersShown = !root.lensRef.spoilersShown
                }

                IconButton {
                    visible: root.lensRef.screen === "thread" || root.lensRef.screen === "images"
                    icon: root.lensRef.bulkRunning ? "stop_circle" : "library_add"
                    tooltip: root.lensRef.bulkRunning ? "Stop adding" : "Add every image in this thread"
                    onClicked: root.lensRef.bulkRunning ? root.lensRef.cancelBulk() : root.lensRef.addThread()
                }

                // The only way back from a hidden post that does not depend on
                // the app's own ⋮ — which is a different file's problem.
                IconButton {
                    visible: root.lensRef.hiddenCount > 0 && root.lensRef.screen !== "boards"
                    icon: "visibility"
                    tooltip: `Show the ${root.lensRef.hiddenCount} you hid on /${root.lensRef.board}/`
                    onClicked: root.lensRef.unhideAll()
                }

                IconButton {
                    icon: "refresh"
                    tooltip: "Fetch it again"
                    onClicked: root.lensRef.refresh()
                }

                // Skins are chosen while you are looking at one — that is the
                // only place the difference is visible.
                PillTabBar {
                    visible: Lenses.skinsOf(root.lensRef.lensId).length > 1
                    tabs: Lenses.skinsOf(root.lensRef.lensId).map(s => ({
                                "id": s.id,
                                "icon": s.id === "quarry" ? "lens_blur" : "palette",
                                "label": s.name
                            }))
                    current: Lenses.skinOf(root.lensRef.lensId)
                    onTabSelected: id => Lenses.setSkin(root.lensRef.lensId, id)
                }

                IconButton {
                    icon: "close"
                    tooltip: "Close"
                    onClicked: Lenses.close()
                }
            }
        }

        // ── the screen ───────────────────────────────────────────────────────
        Loader {
            id: screen

            Layout.fillWidth: true
            Layout.fillHeight: true
            sourceComponent: root.lensRef.screen === "images" ? imageScreen : root.lensRef.screen === "thread" ? threadScreen : root.lensRef.screen === "catalog" ? catalogScreen : boardScreen
        }
    }

    Component {
        id: boardScreen
        BoardList {
            lens: root.lensRef
        }
    }
    Component {
        id: catalogScreen
        CatalogGrid {
            lens: root.lensRef
            onContextRequested: (post, x, y) => postMenu.openFor(post, x, y)
        }
    }
    Component {
        id: threadScreen
        ThreadView {
            lens: root.lensRef
            onContextRequested: (post, x, y) => postMenu.openFor(post, x, y)
        }
    }
    Component {
        id: imageScreen
        ImageWall {
            lens: root.lensRef
            onContextRequested: (post, x, y) => postMenu.openFor(post, x, y)
        }
    }

    /*
     * ONE MENU AND ONE VIEWER FOR THE WHOLE SKIN.
     *
     * Both are drawn over everything else and both outlive the delegate that
     * asked for them — a post scrolled out of a recycled list must not take an
     * open menu with it.
     */
    PostMenu {
        id: postMenu
        lens: root.lensRef
    }

    Viewer {
        anchors.fill: parent
        z: 50
        lens: root.lensRef
        onContextRequested: (post, x, y) => postMenu.openFor(post, x, y)
    }
}
