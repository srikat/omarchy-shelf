// Shelf — a sliding right-edge drop zone for files and folders.
//
// The plugin is a `service` rather than a `panel` because it has to be on
// screen *before* it is asked for: the whole gesture is picking a file up in
// another window and throwing it at the right edge, and you cannot summon a
// panel with a file already in your hand. So one layer-shell surface lives on
// the right edge for the whole session, and an input mask keeps it out of the
// way — a few pixels of hot edge while closed, the panel column while open.
//
// That mask is the load-bearing part. A layer surface that claims the whole
// screen eats the mouse press that *starts* a drag in the window underneath,
// which breaks dragging files in no matter how well the DropArea works. The
// mask never covers more than the panel, and there is deliberately no
// click-outside dismissal overlay.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "ShelfModel.js" as Model

Scope {
  id: root

  // Injected by shell.qml for service plugins.
  property var shell: null
  property var manifest: null

  // ------------------------------------------------------------- geometry
  readonly property int panelWidth: Style.space(330)
  // The hot edge. Thin enough that it costs nothing to leave armed, wide
  // enough to hit by throwing the cursor at the screen edge without aiming.
  readonly property int edgeWidth: Style.space(8)
  readonly property int rowHeight: Style.space(58)
  readonly property int gap: Style.gapsOut
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.family

  // Hovering the hot edge opens the shelf after a short dwell, so brushing
  // past the screen edge on the way somewhere else does not fling it open.
  readonly property int revealDelay: 220
  readonly property int hideDelay: 420

  // ---------------------------------------------------------------- colors
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color borderColor: Color.menu.border
  readonly property color accent: Color.accent
  // NOT Color.muted. That token is decorative — in Tokyo Night it is #414868
  // on a #1a1b26 card, a contrast ratio of 1.9:1, which is invisible at
  // caption size. Secondary text here is the theme foreground held back with
  // alpha instead, which lands near 4.6:1 on the same card and follows any
  // theme's own foreground rather than its idea of "muted".
  readonly property color muted: Util.alpha(Color.foreground, 0.72)
  readonly property color rowFill: Util.alpha(Color.foreground, 0.05)
  readonly property color rowFillHover: Util.alpha(Color.foreground, 0.11)

  // ----------------------------------------------------------------- state
  property var items: []
  property bool pinned: false
  property bool opened: false
  // True for as long as a row is being dragged out. Our own surface is a drag
  // *source* as well as a target, so the DropArea has to ignore the drag it
  // started itself, and the auto-hide has to stay out of the way until the
  // drop lands somewhere.
  property bool dragOutActive: false
  // Hover-to-reveal is the fast path, but the right screen edge is also where
  // scrollbars and window edges live, so it is switchable and remembered.
  property bool hoverReveal: true
  property string flash: ""
  // Set by whichever row has a button under the pointer; the footer reads it.
  property string rowHint: ""

  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property string statePath: Model.stateFile(homeDir, Quickshell.env("XDG_STATE_HOME"))
  readonly property int count: items.length

  // ------------------------------------------------------------- behaviour

  function show() {
    revealTimer.stop()
    hideTimer.stop()
    root.opened = true
    root.classify()
  }

  function hide() {
    if (root.pinned)
      return
    revealTimer.stop()
    hideTimer.stop()
    root.rowHint = ""
    root.opened = false
  }

  function toggle() {
    if (root.opened && !root.pinned) root.hide()
    else root.show()
  }

  // Pinning is what turns the shelf from a peek into a place: it stays open
  // and reserves its column, so tiled windows shrink beside it instead of
  // sitting underneath.
  function setPinned(value) {
    root.pinned = !!value
    if (root.pinned) root.show()
    else hideTimer.restart()
    root.save()
  }

  function togglePin() { root.setPinned(!root.pinned) }

  function setHoverReveal(value) {
    root.hoverReveal = !!value
    if (!root.hoverReveal)
      revealTimer.stop()
    root.save()
    root.say(root.hoverReveal ? "Hover to reveal: on" : "Hover to reveal: off")
  }

  // Auto-hide, with every reason to stay open checked in one place.
  function considerHiding() {
    if (root.pinned || surfaceHover.hovered || dropArea.containsDrag || root.dragOutActive)
      return
    root.opened = false
  }

  // --------------------------------------------------------------- content

  function addEntries(entries) {
    var incoming = Model.itemsFromDrop(entries, Date.now())
    if (!incoming.length)
      return 0
    var merged = Model.merge(root.items, incoming)
    root.items = merged.items
    root.save()
    root.classify()
    if (merged.added > 0)
      root.say(merged.added === 1 ? "Added " + incoming[0].fileName
                                  : "Added " + merged.added + " items")
    else
      root.say("Already on the shelf")
    return merged.added
  }

  function removePath(path) {
    root.items = root.items.filter(function (item) { return item.path !== path })
    root.save()
  }

  // The row's delete button. Says what it did, because a trash can next to a
  // file name is worth contradicting out loud.
  function removeFromShelf(path) {
    root.removePath(path)
    // The row is gone, so its hover hint will never clear itself.
    root.rowHint = ""
    root.say("Off the shelf — " + Model.baseName(path) + " is untouched")
  }

  function clearAll() {
    root.items = []
    root.rowHint = ""
    root.save()
    root.say("Shelf cleared — no files were deleted")
  }

  function allPaths() {
    return root.items.map(function (item) { return item.path })
  }

  function openPath(path) {
    Quickshell.execDetached(["xdg-open", path])
    root.say("Opened " + Model.baseName(path))
  }

  function copyAsFiles(paths) {
    if (!paths.length) return
    Quickshell.execDetached(["sh", "-c",
      'printf "%s" "$1" | wl-copy --type text/uri-list',
      "omarchy-shelf", Model.uriList(paths)])
    root.say(paths.length === 1 ? "Copied as file" : "Copied " + paths.length + " as files")
  }

  // A one-line status in the footer instead of a desktop notification: the
  // shelf is already on screen whenever it has something to say.
  function say(message) {
    root.flash = String(message)
    flashTimer.restart()
  }

  Timer {
    id: flashTimer
    interval: 1800
    onTriggered: root.flash = ""
  }

  // ----------------------------------------------------- persistence + stat

  function save() {
    if (!root.statePath)
      return
    stateFile.setText(Model.serialize(root.items, root.pinned, root.hoverReveal))
  }

  function restore(text) {
    var state = Model.deserialize(text)
    root.items = state.items
    root.pinned = state.pinned
    root.hoverReveal = state.hoverReveal
    if (root.pinned)
      root.opened = true
    root.classify()
  }

  FileView {
    id: stateFile
    path: root.statePath
    preload: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.restore(stateFile.text())
    // A missing file is just an empty shelf on first run; it gets written as
    // soon as something lands.
    onLoadFailed: error => {}
  }

  // A drop carries a path, not a file type: whether it is a directory, and
  // whether it still exists at all, takes a stat. One process for the whole
  // list, run on restore, after every add, and whenever the shelf opens.
  property var statPaths: []
  property bool statQueued: false

  function classify() {
    if (!root.items.length)
      return
    if (statProc.running) {
      root.statQueued = true
      return
    }
    root.statPaths = root.allPaths()
    statProc.command = ["sh", "-c",
      'for p in "$@"; do if [ -d "$p" ]; then echo d; elif [ -e "$p" ]; then echo f; else echo x; fi; done',
      "omarchy-shelf"].concat(root.statPaths)
    statProc.running = true
  }

  function applyStat(output) {
    var states = String(output).split("\n")
    var byPath = ({})
    for (var i = 0; i < root.statPaths.length; i++)
      byPath[root.statPaths[i]] = String(states[i] || "").trim()
    // Items can have come and gone while the stat was in flight, so results
    // are matched back by path rather than by position.
    root.items = root.items.map(function (item) {
      var state = byPath[item.path]
      return state ? Model.reclassify(item, state) : item
    })
    if (root.statQueued) {
      root.statQueued = false
      root.classify()
    }
  }

  Process {
    id: statProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStat(text)
    }
  }

  Component.onCompleted: {
    // FileView writes the file but not the directory above it.
    if (root.statePath) {
      var slash = root.statePath.lastIndexOf("/")
      if (slash > 0)
        Quickshell.execDetached(["mkdir", "-p", root.statePath.slice(0, slash)])
    }
  }

  // ------------------------------------------------------------------- IPC

  IpcHandler {
    target: "shelf"

    function show(): void { root.show() }
    function hide(): void { root.pinned = false; root.hide() }
    function toggle(): void { root.toggle() }
    function pin(): string { root.setPinned(true); return "pinned" }
    function unpin(): string { root.setPinned(false); return "unpinned" }
    function togglePin(): string { root.togglePin(); return root.pinned ? "pinned" : "unpinned" }

    // "on" | "off" | anything else toggles.
    function hover(mode: string): string {
      var text = String(mode).trim().toLowerCase()
      if (text === "on" || text === "true") root.setHoverReveal(true)
      else if (text === "off" || text === "false") root.setHoverReveal(false)
      else root.setHoverReveal(!root.hoverReveal)
      return root.hoverReveal ? "on" : "off"
    }

    // Accepts {"paths": [...]} or newline separated paths. A bare JSON array
    // never survives the IPC layer — an argument starting with "[" is read as
    // an argument *list* and splatted across the method's parameters — so the
    // object wrapper is what keeps names with spaces or commas in one piece.
    function add(argument: string): string {
      var added = root.addFromArgument(argument)
      root.show()
      return String(added)
    }

    function addQuiet(argument: string): string {
      return String(root.addFromArgument(argument))
    }

    // Same argument shape as add(): {"paths": [...]} or newline separated.
    function remove(argument: string): string {
      var before = root.items.length
      var entries = root.entriesFromArgument(argument)
      for (var i = 0; i < entries.length; i++)
        root.removePath(entries[i].path)
      return String(before - root.items.length)
    }

    function list(): string { return root.allPaths().join("\n") }
    function count(): string { return String(root.items.length) }
    function clear(): string { root.clearAll(); return "0" }
  }

  // Normalizes an IPC argument into shelf items, so add and remove agree on
  // what a path is — urls, ~-free absolute paths, JSON or newlines.
  function entriesFromArgument(argument) {
    var text = String(argument)
    var entries = null
    try {
      var parsed = JSON.parse(text)
      if (Array.isArray(parsed))
        entries = parsed
      else if (parsed && Array.isArray(parsed.paths))
        entries = parsed.paths
    } catch (e) {
      // Not JSON — fall through to the newline form.
    }
    if (!entries)
      entries = text.split("\n")
    return Model.itemsFromDrop(entries, 0)
  }

  function addFromArgument(argument) {
    return root.addEntries(root.entriesFromArgument(argument).map(function (item) {
      return item.path
    }))
  }

  // --------------------------------------------------------------- surface

  Timer {
    id: revealTimer
    interval: root.revealDelay
    onTriggered: if (surfaceHover.hovered) root.show()
  }

  Timer {
    id: hideTimer
    interval: root.hideDelay
    onTriggered: root.considerHiding()
  }

  PanelWindow {
    id: window

    color: "transparent"
    WlrLayershell.namespace: "omarchy-shelf"
    WlrLayershell.layer: WlrLayer.Top
    // Never take focus: the shelf is operated with the pointer, and stealing
    // keyboard focus from whatever you were typing in would be a bug.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    anchors { top: true; bottom: true; right: true }
    implicitWidth: root.panelWidth

    // Unpinned the shelf floats over whatever is underneath; pinned it takes
    // its column out of the tiling area.
    exclusionMode: root.pinned ? ExclusionMode.Normal : ExclusionMode.Ignore
    exclusiveZone: root.pinned ? root.panelWidth : 0

    // The input region, and the reason drag-in works at all. Closed, it is the
    // hot edge and nothing else, so a press anywhere else on screen still
    // belongs to the window underneath.
    mask: Region {
      x: root.opened ? 0 : window.width - root.edgeWidth
      y: 0
      width: root.opened ? window.width : root.edgeWidth
      height: window.height
    }

    HoverHandler {
      id: surfaceHover
      onHoveredChanged: {
        if (hovered) {
          hideTimer.stop()
          if (!root.opened && root.hoverReveal)
            revealTimer.restart()
        } else {
          revealTimer.stop()
          if (root.opened && !root.pinned)
            hideTimer.restart()
        }
      }
    }

    // Fills the whole surface, not just the card: while the shelf is closed
    // the only part of it you can reach is the hot edge, and a drag landing
    // there has to count. Dropping on those few pixels works even if the card
    // never makes it out.
    DropArea {
      id: dropArea
      anchors.fill: parent

      onEntered: drag => {
        if (root.dragOutActive)
          return
        if (!drag.hasUrls && !drag.hasText)
          return
        drag.accept(Qt.CopyAction)
        hideTimer.stop()
        revealTimer.stop()
        root.opened = true
      }

      onExited: {
        if (root.opened && !root.pinned)
          hideTimer.restart()
      }

      onDropped: drop => {
        if (root.dragOutActive)
          return
        if (!drop.hasUrls && !drop.hasText)
          return
        var entries = drop.hasUrls ? drop.urls : String(drop.text).split("\n")
        root.addEntries(entries)
        drop.accept(Qt.CopyAction)
      }
    }

    // ------------------------------------------------------------ hot edge
    //
    // Visible only while the shelf is closed, and only just: a hairline pill
    // that says there is something here without being one more thing on
    // screen. It fills in once the shelf has anything on it.
    Item {
      id: handle
      width: Style.space(9)
      height: Style.space(78)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      opacity: root.opened ? 0 : (surfaceHover.hovered ? 1 : (root.count > 0 ? 0.75 : 0.35))
      visible: opacity > 0

      Behavior on opacity { NumberAnimation { duration: 140 } }

      // A wallpaper can be any colour, and a bare accent hairline disappears
      // into half of them. The backing is what makes the pill legible without
      // making it loud.
      Rectangle {
        anchors.fill: parent
        anchors.rightMargin: -parent.width
        radius: width / 2
        color: Util.alpha(root.background, 0.55)
      }

      Rectangle {
        width: surfaceHover.hovered ? Style.space(4) : Style.space(3)
        height: parent.height - Style.space(8)
        radius: width / 2
        anchors.right: parent.right
        anchors.rightMargin: Style.space(2)
        anchors.verticalCenter: parent.verticalCenter
        color: root.count > 0 ? root.accent : root.foreground

        Behavior on width { NumberAnimation { duration: 140 } }
      }
    }

    // Drag hovering the closed edge: a full-height accent seam, so the throw
    // has something to land on that you can see mid-drag.
    Rectangle {
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: Style.space(4)
      color: root.accent
      opacity: dropArea.containsDrag && !root.opened ? 0.9 : 0
      Behavior on opacity { NumberAnimation { duration: 120 } }
    }

    // ---------------------------------------------------------------- card

    Rectangle {
      id: card

      y: root.gap
      height: window.height - root.gap * 2
      width: root.panelWidth - root.gap
      // Closed, the card sits one full window width to the right — entirely
      // off screen. Open, it lands flush against the gap.
      x: root.opened ? (window.width - width - root.gap) : window.width
      opacity: root.opened ? 1 : 0
      visible: opacity > 0

      color: root.background
      radius: root.cornerRadius
      border.width: Math.max(1, Style.space(1))
      border.color: dropArea.containsDrag ? root.accent : root.borderColor

      Behavior on x { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
      Behavior on opacity { NumberAnimation { duration: 180 } }
      Behavior on border.color { ColorAnimation { duration: 120 } }

      // ------------------------------------------------------------ header
      Item {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.spacing.lg
        height: Style.space(34)

        Text {
          id: title
          anchors.left: parent.left
          anchors.leftMargin: Style.spacing.sm
          anchors.verticalCenter: parent.verticalCenter
          text: "Side Shelf"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }

        Text {
          anchors.left: title.right
          anchors.leftMargin: Style.spacing.md
          anchors.baseline: title.baseline
          text: root.count > 0 ? String(root.count) : ""
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.xxs

          ShelfIconButton {
            id: clearButton
            fontFamily: root.fontFamily
            foreground: root.foreground
            accent: root.accent
            muted: root.muted
            danger: true
            visible: root.count > 0
            icon: "\u{F05E9}"          // nf-md-delete_sweep
            onClicked: root.clearAll()
          }

          ShelfIconButton {
            id: pinButton
            fontFamily: root.fontFamily
            foreground: root.foreground
            accent: root.accent
            muted: root.muted
            active: root.pinned
            icon: root.pinned ? "\u{F0403}" : "\u{F0404}"   // nf-md-pin / pin_off
            onClicked: root.togglePin()
          }
        }
      }

      Rectangle {
        id: headerRule
        anchors.top: header.bottom
        anchors.topMargin: Style.spacing.md
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        color: Util.alpha(root.foreground, 0.12)
      }

      // -------------------------------------------------------------- list
      ListView {
        id: list
        anchors.top: headerRule.bottom
        anchors.bottom: footer.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Style.spacing.lg
        anchors.bottomMargin: Style.spacing.sm
        clip: true
        spacing: Style.spacing.sm
        visible: root.count > 0
        model: root.items
        boundsBehavior: Flickable.StopAtBounds

        delegate: ShelfRow {
          required property var modelData
          width: list.width
          height: root.rowHeight

          fontFamily: root.fontFamily
          foreground: root.foreground
          muted: root.muted
          accent: root.accent
          fill: root.rowFill
          fillHover: root.rowFillHover
          radius: root.cornerRadius

          path: modelData.path
          fileName: modelData.fileName
          parentDir: Model.parentLabel(modelData.path, root.homeDir)
          icon: modelData.icon
          isImage: modelData.isImage
          isDir: modelData.isDir
          missing: modelData.missing

          onOpenRequested: root.openPath(path)
          onCopyFileRequested: root.copyAsFiles([path])
          onRemoveRequested: root.removeFromShelf(path)
          onActionHintChanged: root.rowHint = actionHint
          onDragStarted: root.dragOutActive = true
          onDragFinished: {
            root.dragOutActive = false
            if (!root.pinned)
              hideTimer.restart()
          }
        }
      }

      // ------------------------------------------------------- empty state
      Column {
        anchors.centerIn: parent
        anchors.verticalCenterOffset: -Style.space(10)
        width: parent.width - Style.spacing.huge * 2
        spacing: Style.spacing.lg
        visible: root.count === 0

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: "\u{F0120}"          // nf-md-tray_arrow_down
          font.family: root.fontFamily
          font.pixelSize: Style.font.displayLarge
          color: dropArea.containsDrag ? root.accent : Util.alpha(root.foreground, 0.35)
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          text: "Drop files and folders here — or throw them at the right edge of the screen."
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        // The shelf holds paths, not copies. Worth saying once, up front,
        // where it is read before anything is at stake.
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          text: "The shelf keeps a path, never a copy. Taking something off it never deletes the file."
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // ------------------------------------------------------------ footer
      Item {
        id: footer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Style.spacing.lg
        height: Style.space(16)

        Text {
          anchors.left: parent.left
          anchors.leftMargin: Style.spacing.sm
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideRight
          text: {
            if (root.flash !== "") return root.flash
            if (clearButton.hovered)
              return "Empty the shelf — every file stays where it is"
            if (pinButton.hovered)
              return root.pinned ? "Unpin — let it slide away again"
                                 : "Pin — keep it open and make room for it"
            if (root.rowHint !== "") return root.rowHint
            return root.count > 0 ? "Click opens · drag takes it out" : ""
          }
          color: root.flash !== "" ? root.accent : root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
