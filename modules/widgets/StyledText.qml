import qs.modules.common
import QtQuick

// Base text element — every string in the app goes through this so the family,
// weight axes and colour stay consistent.
Text {
    id: root

    renderType: Text.NativeRendering
    verticalAlignment: Text.AlignVCenter

    readonly property bool shouldUseNumberFont: /^\d+$/.test(root.text)

    font {
        hintingPreference: Font.PreferDefaultHinting
        family: root.shouldUseNumberFont ? Appearance.font.family.numbers : Appearance.font.family.main
        pixelSize: Appearance.font.pixelSize.small
        variableAxes: root.shouldUseNumberFont ? ({}) : Appearance.font.variableAxes.main
    }

    color: Appearance.colors.colOnLayer0
    linkColor: Appearance.colors.colPrimary
}
