import qs.modules.common
import QtQuick
import QtQuick.Controls

// ListView with the app's scrollbar and momentum settings pre-wired.
ListView {
    id: root

    boundsBehavior: Flickable.StopAtBounds
    flickDeceleration: Appearance.scroll.deceleration
    maximumFlickVelocity: Appearance.scroll.maxVelocity
    reuseItems: true
    cacheBuffer: 800
    // Left off deliberately: snapping contentY to whole pixels makes a
    // pixel-precise touchpad gesture stutter as it rounds each frame.
    pixelAligned: false

    ScrollBar.vertical: StyledScrollBar {}
}
