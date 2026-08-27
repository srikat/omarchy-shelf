// Shelf — a small glyph button.
//
// No tooltip surface of its own: a layer-shell popup would be a second
// surface to manage mid-drag, and the card already has a footer line that is
// otherwise idle. The button just reports whether it is hovered and lets the
// footer do the talking.

import QtQuick
import qs.Commons

Rectangle {
  id: button

  property string icon: ""
  property string fontFamily: Style.font.family
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color muted: Color.muted
  property bool active: false
  property bool danger: false

  readonly property bool hovered: hover.hovered

  signal clicked()

  implicitWidth: Style.space(26)
  implicitHeight: Style.space(26)
  radius: Style.cornerRadius
  color: hover.hovered ? Util.alpha(button.danger ? Color.urgent : button.accent, 0.16)
                       : (button.active ? Util.alpha(button.accent, 0.12) : "transparent")

  Behavior on color { ColorAnimation { duration: 90 } }

  Text {
    anchors.centerIn: parent
    text: button.icon
    font.family: button.fontFamily
    font.pixelSize: Style.font.icon
    color: {
      if (hover.hovered) return button.danger ? Color.urgent : button.accent
      if (button.active) return button.accent
      return button.muted
    }

    Behavior on color { ColorAnimation { duration: 90 } }
  }

  HoverHandler {
    id: hover
    cursorShape: Qt.PointingHandCursor
  }

  TapHandler {
    acceptedButtons: Qt.LeftButton
    onTapped: button.clicked()
  }
}
