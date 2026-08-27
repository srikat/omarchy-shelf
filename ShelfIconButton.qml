// Shelf — a small glyph button, with a tooltip drawn inside the panel.
//
// The tooltip is a plain Rectangle in the panel's own scene, not a popup: a
// second layer-shell surface would be one more thing to manage while a drag is
// in flight, and a drag arriving over a stray surface is how drag-in breaks.
// It defaults to the left edge because every button here sits against the
// right side of a narrow card, where anything to the right is off screen.
//
// The tooltip names the action; the panel footer says what it means. "Remove"
// and "takes it off the shelf, the file stays put" are both worth saying, and
// neither fits comfortably in the other's space.

import QtQuick
import qs.Commons

Rectangle {
  id: button

  property string icon: ""
  property string tooltip: ""
  // "left" | "right" | "top" | "bottom"
  property string tooltipEdge: "left"
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

  Rectangle {
    id: tip

    readonly property bool vertical: button.tooltipEdge === "top" || button.tooltipEdge === "bottom"

    visible: hover.hovered && button.tooltip !== ""
    // Above the neighbouring button, whichever way it opens.
    z: 100

    anchors.horizontalCenter: tip.vertical ? parent.horizontalCenter : undefined
    anchors.verticalCenter: tip.vertical ? undefined : parent.verticalCenter
    anchors.bottom: button.tooltipEdge === "top" ? parent.top : undefined
    anchors.top: button.tooltipEdge === "bottom" ? parent.bottom : undefined
    anchors.right: button.tooltipEdge === "left" ? parent.left : undefined
    anchors.left: button.tooltipEdge === "right" ? parent.right : undefined
    anchors.margins: Style.spacing.xs

    width: tipText.implicitWidth + Style.spacing.lg * 2
    height: tipText.implicitHeight + Style.spacing.xs * 2
    radius: Style.cornerRadius
    color: Color.tooltip.background
    border.width: Math.max(1, Style.space(1))
    border.color: Util.alpha(Color.tooltip.border, 0.5)

    Text {
      id: tipText
      anchors.centerIn: parent
      text: button.tooltip
      color: Color.tooltip.text
      font.family: button.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
