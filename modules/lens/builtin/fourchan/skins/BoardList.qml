import qs.modules.common
import qs.modules.widgets
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/*
 * WHICH BOARDS YOU READ.
 *
 * The list is yours, and it starts as drawn and created work: boards whose
 * pictures are made rather than taken. Everything else is one click away and
 * stays off until you click it — the boards that carry reposted photographs of
 * real people are not a default anybody should inherit.
 */
Flickable {
    id: root

    required property var lens

    contentHeight: column.implicitHeight + 32
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    ColumnLayout {
        id: column
        x: 20
        y: 16
        width: root.width - 40
        spacing: 10

        StyledText {
            text: "Your boards"
            font.pixelSize: Appearance.font.pixelSize.small
            font.weight: Font.DemiBold
            color: Appearance.colors.colSubtext
        }

        Flow {
            Layout.fillWidth: true
            spacing: 10

            Repeater {
                model: root.lens.boards

                delegate: Rectangle {
                    id: card
                    required property var modelData
                    readonly property bool adult: modelData.ws_board !== 1

                    width: 190
                    height: 78
                    radius: Appearance.rounding.normal
                    color: cardTap.pressed ? Appearance.colors.colLayer1Active : cardHover.hovered ? Appearance.colors.colLayer1Hover : Appearance.colors.colLayer1
                    Behavior on color {
                        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(card)
                    }

                    HoverHandler {
                        id: cardHover
                        cursorShape: Qt.PointingHandCursor
                    }
                    TapHandler {
                        id: cardTap
                        gesturePolicy: TapHandler.ReleaseWithinBounds
                        onTapped: root.lens.showCatalog(card.modelData.board)
                    }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 0

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            StyledText {
                                text: `/${card.modelData.board}/`
                                font.pixelSize: Appearance.font.pixelSize.larger
                                font.weight: Font.DemiBold
                                color: Appearance.colors.colPrimary
                            }
                            Item {
                                Layout.fillWidth: true
                            }
                            MaterialSymbol {
                                visible: card.adult
                                text: "no_adult_content"
                                iconSize: 16
                                color: Appearance.colors.colError
                            }
                            MaterialSymbol {
                                visible: cardHover.hovered
                                text: "close"
                                iconSize: 16
                                color: Appearance.colors.colSubtext

                                TapHandler {
                                    gesturePolicy: TapHandler.ReleaseWithinBounds
                                    onTapped: root.lens.setBoardEnabled(card.modelData.board, false)
                                }
                            }
                        }
                        StyledText {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            text: card.modelData.title
                            font.pixelSize: Appearance.font.pixelSize.small
                            color: Appearance.colors.colOnLayer1
                        }
                        StyledText {
                            Layout.fillWidth: true
                            visible: card.adult
                            // The site's own ws_board flag. /wg/ and /ic/ are 0,
                            // so this is "may carry adult", not "is adult" —
                            // said calmly, and the rows are marked either way.
                            text: "not worksafe · rows marked adult"
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            color: Appearance.colors.colSubtext
                        }
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            Layout.topMargin: 12
            color: Appearance.colors.colOutlineVariant
            opacity: 0.6
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            StyledText {
                Layout.fillWidth: true
                text: "Add a board"
                font.pixelSize: Appearance.font.pixelSize.small
                font.weight: Font.DemiBold
                color: Appearance.colors.colSubtext
            }
            StyledText {
                text: Prefs.showNsfw ? "Offer adult boards" : "Adult boards are off in Settings"
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colSubtext
            }
            /*
             * Disabled rather than hidden while quarry's own switch is off.
             *
             * A switch that is present and does nothing is the worst of the
             * three options, and a control that vanishes leaves you hunting for
             * where the setting went. This one stays, greys out, and the label
             * beside it says which setting outranks it.
             */
            StyledSwitch {
                checked: root.lens.adultBoardsOffered
                enabled: Prefs.showNsfw
                opacity: Prefs.showNsfw ? 1 : 0.4
                onToggled: on => root.lens.offerAdultBoards(on)
            }
        }

        StyledText {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            visible: root.lens.adultBoardsOffered
            text: "Adult boards carry photographs of real people, reposted without them. Anything you take from one is marked adult so the blur and hide settings apply."
            font.pixelSize: Appearance.font.pixelSize.smallest
            color: Appearance.colors.colError
        }

        Flow {
            Layout.fillWidth: true
            spacing: 6

            Repeater {
                model: root.lens.offerableBoards

                delegate: Rectangle {
                    id: chip
                    required property var modelData

                    implicitWidth: chipText.implicitWidth + 22
                    height: 30
                    radius: Appearance.rounding.full
                    color: chipHover.hovered ? Appearance.colors.colLayer1Hover : Appearance.colors.colLayer1
                    border.width: 1
                    border.color: Appearance.colors.colOutlineVariant

                    HoverHandler {
                        id: chipHover
                        cursorShape: Qt.PointingHandCursor
                    }
                    TapHandler {
                        gesturePolicy: TapHandler.ReleaseWithinBounds
                        onTapped: root.lens.setBoardEnabled(chip.modelData.board, true)
                    }
                    StyledToolTip {
                        visible: chipHover.hovered
                        text: chip.modelData.title
                    }

                    StyledText {
                        id: chipText
                        anchors.centerIn: parent
                        text: `/${chip.modelData.board}/`
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: chip.modelData.ws_board === 1 ? Appearance.colors.colOnLayer1 : Appearance.colors.colError
                    }
                }
            }
        }
    }

    ScrollBar.vertical: StyledScrollBar {
        view: root
    }
}
