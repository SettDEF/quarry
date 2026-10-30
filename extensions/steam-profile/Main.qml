import qs.modules.common
import qs.modules.widgets
import qs.modules.gallery
import qs.services
import QtQuick
import Qt5Compat.GraphicalEffects

/*
 * THE STEAM PROFILE HEADER, AT THE SIZE STEAM DRAWS IT.
 *
 * A pack rather than part of the layout: the in-context view answers "is this a
 * good *avatar*", and which avatars you care about is personal. Someone who
 * never touches Steam should not have a third of that stage spent on it, and
 * the seam that makes that possible is the same one an outside pack would use.
 *
 * Everything here is in DEVICE pixels — 184 is the number Steam renders, and
 * `mock.u()` is what turns it into the logical units QML lays out in. The
 * numbers are the design, so they stay literal.
 */
Extension {
    id: root

    contextMocks: [
        {
            "id": "steam-profile",
            "label": "Steam profile",
            "detail": "184×184",
            "targetId": "steam-avatar",
            "designW": 560,
            "designH": 232,
            "component": header
        }
    ]

    Component {
        id: header

        Item {
            id: card

            /// Injected by ContextMock: u(), fit, dpr, record, ladderFor().
            property var mock: null

            readonly property real fit: card.mock ? card.mock.fit : 1
            function u(px) {
                return card.mock ? card.mock.u(px) : px;
            }

            Rectangle {
                anchors.fill: parent
                radius: card.u(10)
                color: Appearance.colors.colSurfaceContainerHighest
            }

            Item {
                id: avatar
                x: card.u(24)
                y: card.u(24)
                width: card.u(184)
                height: width

                ThumbImage {
                    anchors.fill: parent
                    item: card.mock ? card.mock.record : null
                    size: card.mock ? card.mock.ladderFor(184 * card.fit) : 320
                    // Three pictures on this stage; none of them may wait
                    // behind the filmstrip for a decode slot.
                    gated: false
                    fillMode: Image.PreserveAspectCrop
                    /*
                     * A masking layer, which tiles are not allowed — one FBO
                     * per tile is what makes a wall of them expensive. Here
                     * the corner radius is part of what is being judged, so
                     * it is paid for once and it buys the truth.
                     */
                    layer.enabled: true
                    layer.smooth: true
                    layer.effect: OpacityMask {
                        maskSource: Rectangle {
                            width: avatar.width
                            height: avatar.height
                            radius: card.u(14)
                        }
                    }
                }
            }

            Column {
                x: card.u(232)
                y: card.u(40)
                spacing: card.u(14)

                StyledText {
                    text: "Your persona"
                    font.pixelSize: Appearance.font.pixelSize.huge * card.fit
                    font.weight: Font.DemiBold
                    color: Appearance.colors.colOnLayer2
                }

                Row {
                    spacing: card.u(10)

                    Rectangle {
                        width: card.u(52)
                        height: card.u(52)
                        radius: Appearance.rounding.full
                        color: "transparent"
                        border.width: Math.max(1, card.u(3))
                        border.color: Appearance.colors.colPrimary

                        StyledText {
                            anchors.centerIn: parent
                            text: "42"
                            font.pixelSize: Appearance.font.pixelSize.small * card.fit
                            color: Appearance.colors.colOnLayer2
                        }
                    }

                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: card.u(6)

                        StyledText {
                            text: "Level 42"
                            font.pixelSize: Appearance.font.pixelSize.small * card.fit
                            color: Appearance.colors.colOnLayer1
                        }

                        Row {
                            spacing: card.u(8)

                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: card.u(12)
                                height: width
                                radius: Appearance.rounding.full
                                color: Appearance.colors.colPrimary
                            }

                            StyledText {
                                text: "Online"
                                font.pixelSize: Appearance.font.pixelSize.smaller * card.fit
                                color: Appearance.colors.colSubtext
                            }
                        }
                    }
                }
            }
        }
    }
}
