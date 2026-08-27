// Shelf — one file or folder on the shelf.
//
// Click opens it. Press and move drags it out into any other window as a real
// XDG drag (text/uri-list), which is the whole point of parking it here.
//
// The drag-out mechanics are the awkward part, and they are the same three
// facts every time (learned the hard way in bylund.ledge, MIT):
//
//   * Drag.mimeData and Drag.imageSource only do anything when dragType is
//     Drag.Automatic; a bare Drag.active toggle starts an internal-only drag
//     that looks exactly like nothing happening.
//   * Qt refuses to start an automatic drag on an attached object that is not
//     already active, and *warns* rather than throwing. So active is set,
//     startDrag() is called, and active is cleared again.
//   * Wayland needs a real input serial, so the drag has to begin inside the
//     mouse event that triggered it — never from a timer or a shortcut.
//
// What the target did with the file cannot be read back: under Wayland
// Drag.onDragFinished reports Qt.IgnoreAction for every drag. Nothing here
// branches on it. Dragging out is copy-only, so there is nothing to settle.

import QtQuick
import qs.Commons
import "ShelfModel.js" as Model

Rectangle {
  id: row

  property string fontFamily: Style.font.family
  property color foreground: Color.foreground
  property color muted: Color.muted
  property color accent: Color.accent
  property color fill: Util.alpha(Color.foreground, 0.05)
  property color fillHover: Util.alpha(Color.foreground, 0.11)

  // A chip on a horizontal shelf rather than a row on a vertical one: the
  // same layout, narrower, with the parent directory dropped. A 92px strip
  // has room for one line of text, and the file name is the one that matters.
  property bool compact: false

  property string path: ""
  property string fileName: ""
  property string parentDir: ""
  property string icon: ""
  property bool isImage: false
  property bool isDir: false
  property bool missing: false

  readonly property string uri: Model.urlFromPath(path)

  // What the footer should say while one of this row's buttons is hovered.
  // "Remove" is a trash can next to a file name, and that reads as "delete the
  // file" unless something says otherwise the moment before you click.
  readonly property string actionHint: {
    if (removeButton.hovered)
      return "Take it off the shelf — the file itself stays put"
    if (copyButton.hovered)
      return "Copy as a file, to paste into anything"
    return ""
  }

  signal openRequested()
  signal copyPathRequested()
  signal copyFileRequested()
  signal removeRequested()
  signal dragStarted()
  signal dragFinished()

  radius: Style.cornerRadius
  color: hover.hovered ? row.fillHover : row.fill
  border.width: hover.hovered ? Math.max(1, Style.space(1)) : 0
  border.color: Util.alpha(row.accent, 0.35)
  opacity: row.missing ? 0.5 : 1

  Behavior on color { ColorAnimation { duration: 90 } }

  // What the cursor carries. Handing Qt the file url instead would drag a
  // full-size image across the screen, and would leave every non-image file
  // with no drag picture at all, so the row grabs its own icon box.
  property url dragImage: ""

  function refreshDragImage() {
    thumbBox.grabToImage(function (result) {
      row.dragImage = result.url
    }, Qt.size(Style.space(44), Style.space(44)))
  }

  Drag.dragType: Drag.Automatic
  Drag.supportedActions: Qt.CopyAction
  Drag.proposedAction: Qt.CopyAction
  Drag.mimeData: ({
    "text/uri-list": Model.uriList([row.path]),
    "text/plain": row.path
  })
  // Only ever the grabbed thumbnail, never the file url: pointing this at the
  // file would drag a full-size image across the screen, and `imageSourceSize`
  // cannot bound it back down — Qt ignores that property on a grabToImage url
  // and says so in the log every time. `grabToImage` is already told the size,
  // so there is nothing left to bound. The grab runs on hover and the drag
  // needs a 10 px move, so it has landed by then; if it somehow has not, the
  // drag goes out without a picture rather than with a 4K one.
  Drag.imageSource: row.dragImage

  function beginDrag() {
    row.dragStarted()
    row.Drag.active = true
    // Blocks until the drop lands or is cancelled.
    row.Drag.startDrag(Qt.CopyAction)
    if (row.Drag.active)
      row.Drag.active = false
    row.dragFinished()
  }

  HoverHandler {
    id: hover
    cursorShape: Qt.OpenHandCursor
    // grabToImage is asynchronous and the drag has to start inside the press
    // event, so the picture is taken while the pointer is still on its way in.
    onHoveredChanged: if (hovered) row.refreshDragImage()
  }

  MouseArea {
    id: body
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    // The list must not steal the press: dragging a file out is the point,
    // and the shelf scrolls with the wheel.
    preventStealing: true

    property point pressPoint: Qt.point(0, 0)
    property bool dragging: false

    onPressed: mouse => {
      pressPoint = Qt.point(mouse.x, mouse.y)
      dragging = false
    }

    onPositionChanged: mouse => {
      if (!pressed || dragging || mouse.buttons !== Qt.LeftButton)
        return
      const dx = mouse.x - pressPoint.x
      const dy = mouse.y - pressPoint.y
      if (Math.sqrt(dx * dx + dy * dy) < 10)
        return
      // Stays true until the next press, so the release that ends a drag is
      // not mistaken for a click.
      dragging = true
      row.beginDrag()
    }

    onClicked: mouse => {
      if (dragging)
        return
      if (mouse.button === Qt.MiddleButton)
        row.removeRequested()
      else
        row.openRequested()
    }
  }

  Rectangle {
    id: thumbBox
    anchors.left: parent.left
    anchors.leftMargin: Style.spacing.md
    anchors.verticalCenter: parent.verticalCenter
    width: Style.space(40)
    height: Style.space(40)
    radius: Math.min(Style.cornerRadius, Style.space(8))
    clip: true
    color: row.isImage && thumb.status === Image.Ready ? "transparent"
                                                       : Util.alpha(row.foreground, 0.06)

    Image {
      id: thumb
      anchors.fill: parent
      visible: row.isImage && status === Image.Ready
      source: row.isImage ? row.uri : ""
      asynchronous: true
      cache: true
      fillMode: Image.PreserveAspectCrop
      sourceSize.width: Style.space(80)
      sourceSize.height: Style.space(80)
    }

    Text {
      anchors.centerIn: parent
      visible: !thumb.visible
      // A broken image — a file deleted since it was added — falls back to
      // the generic glyph rather than an empty box.
      text: row.isImage && thumb.status === Image.Error ? "\u{F0214}" : row.icon
      font.family: row.fontFamily
      font.pixelSize: Style.font.display
      color: row.isDir ? row.accent : row.muted
    }
  }

  Column {
    anchors.left: thumbBox.right
    anchors.leftMargin: Style.spacing.lg
    anchors.right: actions.left
    anchors.rightMargin: Style.spacing.sm
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.spacing.xxs

    Text {
      width: parent.width
      text: row.fileName
      elide: Text.ElideMiddle
      color: row.foreground
      font.family: row.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.strikeout: row.missing
    }

    Text {
      width: parent.width
      visible: !row.compact || row.missing
      text: row.missing ? "missing" : row.parentDir
      elide: Text.ElideLeft
      color: row.missing ? Color.urgent : row.muted
      font.family: row.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  Row {
    id: actions
    anchors.right: parent.right
    anchors.rightMargin: Style.spacing.sm
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.spacing.xxs
    opacity: hover.hovered ? 1 : 0
    enabled: opacity > 0

    Behavior on opacity { NumberAnimation { duration: 90 } }

    ShelfIconButton {
      id: copyButton
      fontFamily: row.fontFamily
      foreground: row.foreground
      accent: row.accent
      muted: row.muted
      icon: "\u{F018F}"          // nf-md-content_copy
      tooltip: "Copy as file"
      onClicked: row.copyFileRequested()
    }

    ShelfIconButton {
      id: removeButton
      fontFamily: row.fontFamily
      foreground: row.foreground
      accent: row.accent
      muted: row.muted
      danger: true
      icon: "\u{F01B4}"          // nf-md-delete
      // Not "Delete". The glyph is a trash can and the file is not going
      // anywhere; the word is the only thing that says so at a glance.
      tooltip: "Remove"
      onClicked: row.removeRequested()
    }
  }
}
