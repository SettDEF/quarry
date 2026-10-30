import "../fmt.js" as Fmt
import Qt5Compat.GraphicalEffects
import QtQuick
import qs.modules.common
import qs.modules.widgets

/*
 * A CHAT'S (OR A PERSON'S) FACE: its photo, else a colour and initials.
 *
 * One component for the list, the chat header and the faces beside group
 * messages, so all three agree. `who` is anything with an `id`/`title` and
 * optionally a `photo` (a chat), or a sender name for a message — the hue and
 * the initials come from whichever is given, so a person keeps one colour.
 *
 * The photo counts only once it has decoded: a path whose file is missing or
 * still arriving falls back to the initials rather than an empty circle.
 */
Rectangle {
    id: root

    property var who: null
    property int size: 40

    readonly property string photo: String((root.who && root.who.photo) || "")
    readonly property string initials: Fmt.initials(root.who)
    readonly property bool showsPhoto: root.photo.length > 0 && photoImage.status === Image.Ready

    width: root.size
    height: root.size
    radius: root.size / 2
    color: root.showsPhoto || root.initials.length === 0
        ? Appearance.colors.colLayer2
        : Qt.hsla(Fmt.hueOf((root.who && (root.who.id || root.who.title)) || ""), 0.42, Appearance.darkmode ? 0.38 : 0.64, 1)

    Image {
        id: photoImage

        anchors.fill: parent
        visible: root.showsPhoto
        source: root.photo
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        smooth: true
        // Decoded at the size it is drawn.
        sourceSize.width: root.size * 2
        sourceSize.height: root.size * 2
        layer.enabled: true

        layer.effect: OpacityMask {
            maskSource: Rectangle {
                width: root.width
                height: root.height
                radius: root.radius
            }
        }
    }

    StyledText {
        anchors.centerIn: parent
        visible: !root.showsPhoto && root.initials.length > 0
        text: root.initials
        font.pixelSize: Math.round(root.size * (root.initials.length > 1 ? 0.36 : 0.42))
        font.weight: Font.DemiBold
        color: ColorUtils.contrastingText(root.color, "#ffffff", "#141414")
    }

    MaterialSymbol {
        anchors.centerIn: parent
        visible: !root.showsPhoto && root.initials.length === 0
        text: Fmt.chatIcon(root.who)
        iconSize: Math.round(root.size * 0.5)
        color: Appearance.colors.colOnLayer2
    }
}
