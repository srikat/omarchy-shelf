// Shelf - a sliding right-edge drop zone for files and folders.
//
// The plugin is a `service` rather than a `panel` because it has to be on
// screen *before* it is asked for: the whole gesture is picking a file up in
// another window and throwing it at the right edge, and you cannot summon a
// panel with a file already in your hand. So one layer-shell surface lives on
// the right edge for the whole session, and an input mask keeps it out of the
// way - a few pixels of hot edge while closed, the panel column while open.
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
  //
  // Which screen edge the shelf lives on: "right" (default), "left", "top" or
  // "bottom". Left and right are tall and narrow and hold a vertical list;
  // top and bottom are wide and short and hold a horizontal one. The two are
  // the same list with a different delegate width and one subtitle hidden -
  // a shelf you cannot read the names on is not worth having.
  property string edge: "right"
  readonly property bool vertical: root.edge === "left" || root.edge === "right"
  // True when the shelf hangs off the far side, so "closed" means translating
  // toward higher coordinates rather than toward zero.
  readonly property bool atFarSide: root.edge === "right" || root.edge === "bottom"

  readonly property int panelWidth: Style.space(330)
  readonly property int panelHeight: Style.space(92)
  // What the shelf costs the screen: its width on a side edge, its height on
  // a top or bottom one. This is also the exclusive zone when pinned.
  readonly property int thickness: root.vertical ? root.panelWidth : root.panelHeight

  // The hot edge. Thin enough that it costs nothing to leave armed, wide
  // enough to hit by throwing the cursor at the screen edge without aiming.
  readonly property int edgeWidth: Style.space(8)
  readonly property int rowHeight: Style.space(58)
  readonly property int chipWidth: Style.space(190)
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
  // NOT Color.muted. That token is decorative - in Tokyo Night it is #414868
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
  // What the surface underneath is doing, mirrored up here because the window
  // is a `Variants` delegate now: its ids are out of scope from the root, and
  // they stop existing at all while there is no screen to put it on. The
  // delegate keeps these in step and clears them on its way out.
  property bool surfaceHovered: false
  property bool dragOverSurface: false
  // Whether the state file has been read yet. Saving before it lands would
  // write an empty shelf over the items still in flight.
  property bool stateLoaded: false
  // True for as long as a row is being dragged out. Our own surface is a drag
  // *source* as well as a target, so the DropArea has to ignore the drag it
  // started itself, and the auto-hide has to stay out of the way until the
  // drop lands somewhere.
  property bool dragOutActive: false
  // How the shelf comes out on its own. "hover" rests the pointer on its edge;
  // "click" waits for the handle to be clicked, for anyone who would rather
  // the screen edge stayed inert -- it is also where scrollbars and window
  // edges live. Either way a drag arriving at the edge still opens it, and
  // the handle is always clickable.
  property string reveal: "hover"
  readonly property bool revealsOnHover: root.reveal === "hover"

  // Whether the handle is painted. The hot edge keeps working either way --
  // this hides the marker, not the target -- so a click, a hover or a drag at
  // the edge still opens the shelf with nothing drawn there.
  property bool showHandle: true

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

  function setEdge(value) {
    var next = Model.normalizeEdge(value)
    if (next === root.edge)
      return next
    // Closing first would animate the card out toward its old edge while the
    // window is already re-anchored to the new one. Snapping shut is the
    // honest transition here.
    var wasOpen = root.opened
    root.opened = false
    root.edge = next
    root.save()
    if (wasOpen || root.pinned)
      Qt.callLater(function() { root.opened = true })
    root.say("Shelf moved to the " + next)
    return next
  }

  function setReveal(value) {
    root.reveal = Model.normalizeReveal(value)
    if (!root.revealsOnHover)
      revealTimer.stop()
    root.save()
    root.say(root.revealsOnHover ? "Opens when you rest on the edge"
                                 : "Opens when you click the handle")
    return root.reveal
  }

  function setShowHandle(value) {
    root.showHandle = !!value
    root.save()
    if (root.showHandle)
      root.say("Handle shown")
    else
      root.say(root.revealsOnHover ? "Handle hidden - the edge still opens on hover"
                                   : "Handle hidden - the edge still opens on a click")
    return root.showHandle
  }

  // Auto-hide, with every reason to stay open checked in one place.
  function considerHiding() {
    if (root.pinned || root.surfaceHovered || root.dragOverSurface || root.dragOutActive)
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
    root.say("Off the shelf - " + Model.baseName(path) + " is untouched")
  }

  function clearAll() {
    root.items = []
    root.rowHint = ""
    root.save()
    root.say("Shelf cleared - no files were deleted")
  }

  function allPaths() {
    return root.items.map(function (item) { return item.path })
  }

  // `gio open`, not `xdg-open`. Two separate reasons, and a row that opened
  // nothing at all needed both fixed:
  //
  //   * Terminal apps. `xdg-open` runs a `Terminal=true` handler's Exec line
  //     with no terminal attached, so clicking a .md whose handler is nvim
  //     started a headless nvim that drew nothing and never exited - one more
  //     orphan per click. GLib finds a terminal (via xdg-terminal-exec) and
  //     runs `foot -e nvim <file>`.
  //   * They disagree about types. `xdg-mime query filetype notes.md` says
  //     text/plain, so xdg-open picked the text/plain handler; GIO says
  //     text/markdown and picks the markdown one, which is the app actually
  //     registered for it.
  //
  // Directories still land in the file manager either way.
  function openPath(path) {
    Quickshell.execDetached(["gio", "open", path])
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
    stateFile.setText(Model.serialize(root.items, root.pinned, root.reveal, root.edge,
                                      root.showHandle, root.screenName))
  }

  function restore(text) {
    var state = Model.deserialize(text)
    root.items = state.items
    root.pinned = state.pinned
    root.reveal = state.reveal
    root.showHandle = state.handle
    root.edge = state.edge
    root.screenName = state.screen
    root.stateLoaded = true
    root.pickScreen()
    if (root.pinned)
      root.opened = true
    root.classify()
  }

  // Write-only, deliberately. `preload` is off and there is no `onLoaded`,
  // because reading this file through FileView is what the hardening below
  // exists to avoid.
  FileView {
    id: stateFile
    path: root.statePath
    preload: false
    atomicWrites: true
    printErrors: false
  }

  // Reading it is the untrusted step. Anything that can write to
  // ~/.local/state can replace this file, and what comes out of it is parsed
  // inside the process that everything else on the desktop depends on.
  //
  // Checking a path and then reading a path are two different files. Between
  // the two, anything that can write to that directory can put something else
  // there, and every guarantee the check made is gone: `[ -f ]` and `[ ! -L ]`
  // followed by `head` is three separate resolutions of the same name and
  // proves nothing about the third. So the path is opened exactly once and
  // every question after that is asked of the descriptor.
  //
  //   O_NOFOLLOW   the open itself fails on a symlink, rather than a test
  //                something else can invalidate afterwards
  //   O_NONBLOCK   a FIFO with no writer returns instead of blocking, so the
  //                type check is reached rather than waited out
  //   S_ISREG      regular files only: no FIFOs, devices or directories
  //   st_uid       ours, on the descriptor
  //   st_size      a byte ceiling, checked on the descriptor and enforced
  //                again by the bounded read, which covers a file that grows
  //                after the check
  //   timeout      a deadline over all of it, since an open can still stall
  //                on an unresponsive mount
  //
  // A rename cannot reach the file behind an open descriptor, so the bytes
  // that arrive are the bytes that were validated. Every refusal prints
  // nothing, and deserialize answers an empty read with an empty shelf.
  //
  // O_NOFOLLOW covers the last component. A symlinked ~/.local/state is a
  // different problem, and one this shares with everything else that writes
  // there. Item count, path length and control characters are bounded
  // separately, in ShelfModel.deserialize.
  readonly property int stateReadLimit: 262144   // 256 KiB; 500 items is ~40 KB

  readonly property string stateReadScript: [
    "import os, stat, sys",
    "try:",
    "    fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)",
    "except OSError:",
    "    sys.exit(0)",
    "try:",
    "    limit = int(sys.argv[2])",
    "    st = os.fstat(fd)",
    "    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_size > limit:",
    "        sys.exit(0)",
    "    out = b''",
    "    while len(out) < limit:",
    "        chunk = os.read(fd, limit - len(out))",
    "        if not chunk:",
    "            break",
    "        out += chunk",
    "finally:",
    "    os.close(fd)",
    "sys.stdout.buffer.write(out)"
  ].join("\n")

  function loadState() {
    if (!root.statePath)
      return
    loadProc.command = ["timeout", "2", "python3", "-c", root.stateReadScript,
                        root.statePath, String(root.stateReadLimit)]
    loadProc.running = true
  }

  Process {
    id: loadProc
    stdout: StdioCollector {
      waitForEnd: true
      // Empty covers every refusal above as well as a missing file, and
      // deserialize answers all of them with an empty shelf and defaults.
      onStreamFinished: root.restore(text)
    }
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
    root.loadState()
    root.pickScreen()
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

    // "left" | "right" | "top" | "bottom"; anything else is rejected and the
    // current edge is reported back unchanged.
    function position(value: string): string {
      if (String(value).trim() === "")
        return root.edge
      return root.setEdge(value)
    }

    // "hover" | "click"; empty reports the current mode, anything else
    // toggles between the two.
    function reveal(mode: string): string {
      var text = String(mode).trim().toLowerCase()
      if (text === "") return root.reveal
      if (text === "hover" || text === "click") return root.setReveal(text)
      return root.setReveal(root.revealsOnHover ? "click" : "hover")
    }

    // "on" | "off"; empty reports, anything else toggles.
    function handle(mode: string): string {
      var text = String(mode).trim().toLowerCase()
      if (text === "") return root.showHandle ? "on" : "off"
      if (text === "on" || text === "true") root.setShowHandle(true)
      else if (text === "off" || text === "false") root.setShowHandle(false)
      else root.setShowHandle(!root.showHandle)
      return root.showHandle ? "on" : "off"
    }

    // The spelling this setting had before it grew a second mode.
    // "on" | "off" | anything else toggles.
    function hover(mode: string): string {
      var text = String(mode).trim().toLowerCase()
      if (text === "on" || text === "true") root.setReveal("hover")
      else if (text === "off" || text === "false") root.setReveal("click")
      else root.setReveal(root.revealsOnHover ? "click" : "hover")
      return root.revealsOnHover ? "on" : "off"
    }

    // Accepts {"paths": [...]} or newline separated paths. A bare JSON array
    // never survives the IPC layer - an argument starting with "[" is read as
    // an argument *list* and splatted across the method's parameters - so the
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

    // A connector name as the compositor spells it, "DP-1" or "eDP-1". Empty
    // reports the screen the shelf is on, which is the chosen one whenever it
    // is connected.
    function monitor(name: string): string {
      if (String(name).trim() === "")
        return root.targetScreen ? root.targetScreen.name : root.screenName
      return root.setScreen(name)
    }

    function list(): string { return root.allPaths().join("\n") }
    function count(): string { return String(root.items.length) }
    function clear(): string { root.clearAll(); return "0" }
  }

  // Normalizes an IPC argument into shelf items, so add and remove agree on
  // what a path is - urls, ~-free absolute paths, JSON or newlines.
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
      // Not JSON - fall through to the newline form.
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
    onTriggered: if (root.surfaceHovered) root.show()
  }

  Timer {
    id: hideTimer
    interval: root.hideDelay
    onTriggered: root.considerHiding()
  }

  // ---------------------------------------------------------------- screen
  //
  // A layer surface belongs to the screen it was created on, and when the
  // compositor destroys that screen the surface goes with it. Nothing brings
  // it back: the service keeps running, the state file is intact and the IPC
  // still answers - `omarchy-shelf show` returns success - but there is no
  // shelf on screen until the shell is restarted. That is not a rare corner.
  // Every DisplayPort link drop, dock unplug and monitor power cycle takes the
  // outputs away for a moment, and Qt hands out a nameless placeholder screen
  // while they are gone.
  //
  // So the window is a `Variants` delegate over a single screen rather than a
  // bare PanelWindow, the way the bar and the background are: screens coming
  // and going destroy and rebuild the surface. One shelf, not one per monitor
  // - it is a place to put things, and two of them would be two places.

  // A screen the compositor will actually put a surface on. The placeholder Qt
  // invents when every output is gone has no name and no size, and a layer
  // surface on it draws nothing and never recovers.
  function isRealScreen(candidate) {
    return !!candidate && !!candidate.name && candidate.width > 0 && candidate.height > 0
  }

  // Which monitor the shelf lives on, held by name rather than by object so
  // that unplugging and replugging one puts the shelf back where it was
  // instead of leaving it wherever the fallback dropped it. The name is
  // learned once, from the first screen the shelf ever gets, and then written
  // to the state file: re-learning it on every change would overwrite the
  // choice with the fallback at exactly the moment the preferred monitor is
  // unplugged, and re-learning it on every start would hand the shelf to
  // whichever screen the compositor happened to list first that time.
  property string screenName: ""
  property var targetScreen: null

  // Assigned rather than bound. A binding that read `screenName` while the
  // handler for it wrote one back is a binding loop as far as QML is
  // concerned, however well it settles, and it says so every time the screens
  // change.
  function pickScreen() {
    var screens = Quickshell.screens || []
    var preferred = null
    var fallback = null

    for (var i = 0; i < screens.length; i++) {
      var candidate = screens[i]
      if (!root.isRealScreen(candidate))
        continue
      if (!preferred && candidate.name === root.screenName)
        preferred = candidate
      if (!fallback)
        fallback = candidate
    }

    var next = preferred || fallback
    if (root.screenName === "" && root.isRealScreen(next)) {
      root.screenName = next.name
      if (root.stateLoaded)
        root.save()
    }
    root.targetScreen = next
  }

  // A monitor that is not connected is still worth accepting: setting the
  // shelf up for a dock you are not currently at is the reason to type this
  // at all. The shelf waits on the fallback until that screen appears.
  function setScreen(value) {
    var next = Model.normalizeScreen(value)
    if (next === "")
      return root.screenName
    root.screenName = next
    root.save()
    root.pickScreen()
    if (root.targetScreen && root.targetScreen.name === next)
      root.say("Shelf moved to " + next)
    else
      root.say("Shelf moves to " + next + " once it is connected")
    return next
  }

  // Monitors arriving and leaving. Every output can be gone at once - a
  // display sleep does it - so this fires with nothing to pick as often as it
  // fires with something, and the shelf has to survive both.
  Connections {
    target: Quickshell

    function onScreensChanged() {
      root.pickScreen()
    }
  }

  Variants {
    model: root.targetScreen ? [root.targetScreen] : []

    delegate: Component {
      ShelfPanel {
        required property var modelData

        screen: modelData
      }
    }
  }

  component ShelfPanel: PanelWindow {
    id: window

    // A rebuilt window has never been hovered and has nothing over it, and no
    // leave event is coming to correct a stale `true` - the pointer is
    // wherever it was when the monitor went away. Start from nothing, and
    // start closed unless the shelf is pinned, because an unpinned shelf that
    // came back open has no hover to fall out of.
    Component.onCompleted: {
      root.surfaceHovered = false
      root.dragOverSurface = false
      if (!root.pinned)
        root.opened = false
    }

    Component.onDestruction: {
      root.surfaceHovered = false
      root.dragOverSurface = false
    }

    color: "transparent"
    WlrLayershell.namespace: "omarchy-shelf"
    WlrLayershell.layer: WlrLayer.Top
    // Never take focus: the shelf is operated with the pointer, and stealing
    // keyboard focus from whatever you were typing in would be a bug.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Anchored to three sides: its own edge plus the two it runs along. The
    // fourth is what leaves room for `implicit` size to mean thickness.
    anchors {
      top: root.edge !== "bottom"
      bottom: root.edge !== "top"
      left: root.edge !== "right"
      right: root.edge !== "left"
    }
    implicitWidth: root.vertical ? root.panelWidth : 0
    implicitHeight: root.vertical ? 0 : root.panelHeight

    // Unpinned the shelf floats over whatever is underneath; pinned it takes
    // its strip out of the tiling area.
    exclusionMode: root.pinned ? ExclusionMode.Normal : ExclusionMode.Ignore
    exclusiveZone: root.pinned ? root.thickness : 0

    // The input region, and the reason drag-in works at all. Closed, it is the
    // hot edge and nothing else, so a press anywhere else on screen still
    // belongs to the window underneath.
    mask: Region {
      x: (root.opened || !root.vertical || !root.atFarSide) ? 0 : window.width - root.edgeWidth
      y: (root.opened || root.vertical || !root.atFarSide) ? 0 : window.height - root.edgeWidth
      width: (root.opened || !root.vertical) ? window.width : root.edgeWidth
      height: (root.opened || root.vertical) ? window.height : root.edgeWidth
    }

    HoverHandler {
      id: surfaceHover
      onHoveredChanged: {
        root.surfaceHovered = hovered
        if (hovered) {
          hideTimer.stop()
          if (!root.opened && root.revealsOnHover)
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

      onContainsDragChanged: root.dragOverSurface = dropArea.containsDrag

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
    //
    // Positioned with x/y rather than anchors: anchoring two opposite sides
    // and a size at once is over-constrained, and every one of these has to
    // flip between the two axes.
    Item {
      id: handle
      width: root.vertical ? Style.space(9) : Style.space(78)
      height: root.vertical ? Style.space(78) : Style.space(9)
      x: root.vertical ? (root.atFarSide ? parent.width - width : 0)
                       : (parent.width - width) / 2
      y: root.vertical ? (parent.height - height) / 2
                       : (root.atFarSide ? parent.height - height : 0)
      // The Item is the hit target and only tracks whether the shelf is out.
      // How much of it gets *painted* is a separate question -- `showHandle`
      // takes the marker away without taking the target with it, so the edge
      // still answers a click, a hover or a drag with nothing drawn on it.
      opacity: root.opened ? 0 : 1
      visible: opacity > 0

      Behavior on opacity { NumberAnimation { duration: 140 } }

      // In click mode the handle is the only way in, so it stops being a
      // hairline hint and starts being a control.
      readonly property real paint: !root.showHandle ? 0
        : (surfaceHover.hovered ? 1
           : (root.revealsOnHover ? (root.count > 0 ? 0.75 : 0.35) : 0.9))

      // Clicking the handle opens the shelf in either reveal mode, and is the
      // only way in once hover is switched off. It does not latch: the handle
      // is hidden while the shelf is out, so there would be nothing left to
      // click to put it away. Closing stays what it was -- move off it, or
      // pin it from the header if it should stay.
      HoverHandler {
        cursorShape: Qt.PointingHandCursor
      }

      TapHandler {
        acceptedButtons: Qt.LeftButton
        onTapped: root.toggle()
      }

      // A wallpaper can be any colour, and a bare accent hairline disappears
      // into half of them. The backing is what makes the pill legible without
      // making it loud. It runs off the screen edge so only its inner curve
      // shows, like a tab.
      Rectangle {
        anchors.fill: parent
        anchors.leftMargin: (root.vertical && !root.atFarSide) ? -parent.width : 0
        anchors.rightMargin: (root.vertical && root.atFarSide) ? -parent.width : 0
        anchors.topMargin: (!root.vertical && !root.atFarSide) ? -parent.height : 0
        anchors.bottomMargin: (!root.vertical && root.atFarSide) ? -parent.height : 0
        radius: Math.min(width, height) / 2
        color: Util.alpha(root.background, 0.55)
        opacity: handle.paint

        Behavior on opacity { NumberAnimation { duration: 140 } }
      }

      Rectangle {
        id: pill
        readonly property int thin: surfaceHover.hovered ? Style.space(4) : Style.space(3)
        width: root.vertical ? thin : parent.width - Style.space(8)
        height: root.vertical ? parent.height - Style.space(8) : thin
        radius: Math.min(width, height) / 2
        x: root.vertical ? (root.atFarSide ? parent.width - width - Style.space(2) : Style.space(2))
                         : (parent.width - width) / 2
        y: root.vertical ? (parent.height - height) / 2
                         : (root.atFarSide ? parent.height - height - Style.space(2) : Style.space(2))
        color: root.count > 0 ? root.accent : root.foreground
        opacity: handle.paint

        Behavior on opacity { NumberAnimation { duration: 140 } }
        Behavior on width { NumberAnimation { duration: 140 } }
        Behavior on height { NumberAnimation { duration: 140 } }
      }
    }

    // Drag hovering the closed edge: an accent seam the length of that edge,
    // so the throw has something to land on that you can see mid-drag.
    Rectangle {
      width: root.vertical ? Style.space(4) : parent.width
      height: root.vertical ? parent.height : Style.space(4)
      x: (root.vertical && root.atFarSide) ? parent.width - width : 0
      y: (!root.vertical && root.atFarSide) ? parent.height - height : 0
      color: root.accent
      opacity: dropArea.containsDrag && !root.opened ? 0.9 : 0
      Behavior on opacity { NumberAnimation { duration: 120 } }
    }

    // ---------------------------------------------------------------- card

    Rectangle {
      id: card

      width: root.vertical ? root.thickness - root.gap : window.width - root.gap * 2
      height: root.vertical ? window.height - root.gap * 2 : root.thickness - root.gap

      // Closed, the card sits one full thickness beyond its edge - entirely
      // off screen. Open, it lands flush against the gap.
      x: root.vertical
         ? (root.opened ? (root.atFarSide ? window.width - width - root.gap : root.gap)
                        : (root.atFarSide ? window.width : -width))
         : root.gap
      y: root.vertical
         ? root.gap
         : (root.opened ? (root.atFarSide ? window.height - height - root.gap : root.gap)
                        : (root.atFarSide ? window.height : -height))
      opacity: root.opened ? 1 : 0
      visible: opacity > 0

      color: root.background
      radius: root.cornerRadius
      border.width: Math.max(1, Style.space(1))
      border.color: dropArea.containsDrag ? root.accent : root.borderColor

      Behavior on x { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
      Behavior on y { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
      Behavior on opacity { NumberAnimation { duration: 180 } }
      Behavior on border.color { ColorAnimation { duration: 120 } }

      readonly property int pad: Style.spacing.lg

      // ------------------------------------------------------------ header
      //
      // Vertical: a full-width strip across the top, buttons at its right.
      // Horizontal: a name at the left end of the strip, buttons at the far
      // right, and the list running between them.
      Item {
        id: header
        x: card.pad
        y: card.pad
        width: root.vertical ? card.width - card.pad * 2
                             : title.implicitWidth + count.implicitWidth + Style.spacing.md * 2
        height: root.vertical ? Style.space(34) : card.height - card.pad * 2

        Text {
          id: title
          anchors.left: parent.left
          anchors.leftMargin: Style.spacing.sm
          anchors.verticalCenter: parent.verticalCenter
          text: "Shelf"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }

        Text {
          id: count
          anchors.left: title.right
          anchors.leftMargin: Style.spacing.md
          anchors.baseline: title.baseline
          text: root.count > 0 ? String(root.count) : ""
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Row {
        id: actions
        spacing: Style.spacing.xxs
        x: card.width - width - card.pad
        y: root.vertical ? card.pad + (Style.space(34) - height) / 2
                         : (card.height - height) / 2

        ShelfIconButton {
          id: clearButton
          fontFamily: root.fontFamily
          foreground: root.foreground
          accent: root.accent
          muted: root.muted
          danger: true
          visible: root.count > 0
          icon: "\u{F05E9}"          // nf-md-delete_sweep
          // "Remove", never "delete" -- the shelf holds paths, and the word
          // on a trash can is what decides whether that lands.
          tooltip: "Remove all"
          tooltipEdge: root.vertical ? "left" : "top"
          tooltipAlign: "right"
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
          tooltip: root.pinned ? "Unpin" : "Pin"
          tooltipEdge: root.vertical ? "left" : "top"
          tooltipAlign: "right"
          onClicked: root.togglePin()
        }
      }

      Rectangle {
        id: headerRule
        visible: root.vertical
        x: 0
        y: header.y + header.height + Style.spacing.md
        width: card.width
        height: 1
        color: Util.alpha(root.foreground, 0.12)
      }

      // -------------------------------------------------------------- list
      ListView {
        id: list
        orientation: root.vertical ? ListView.Vertical : ListView.Horizontal

        x: root.vertical ? card.pad : header.x + header.width + Style.spacing.lg
        y: root.vertical ? headerRule.y + headerRule.height + card.pad : card.pad
        width: root.vertical ? card.width - card.pad * 2
                             : Math.max(0, hint.x - Style.spacing.lg - x)
        height: root.vertical ? Math.max(0, hint.y - Style.spacing.sm - y)
                              : card.height - card.pad * 2

        clip: true
        spacing: Style.spacing.sm
        visible: root.count > 0
        model: root.items
        boundsBehavior: Flickable.StopAtBounds

        delegate: ShelfRow {
          required property var modelData
          compact: !root.vertical
          width: root.vertical ? list.width : root.chipWidth
          height: root.vertical ? root.rowHeight : list.height

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

      // ------------------------------------------------- empty state, tall
      Column {
        anchors.centerIn: parent
        anchors.verticalCenterOffset: -Style.space(10)
        width: card.width - Style.spacing.huge * 2
        spacing: Style.spacing.lg
        visible: root.count === 0 && root.vertical

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
          text: "Drop files and folders here - or throw them at the " + root.edge + " edge of the screen."
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

      // ------------------------------------------------- empty state, wide
      //
      // The same two sentences, on one line: a strip 92px tall has no room to
      // stack them, and shrinking them to fit would undo the contrast work.
      Row {
        x: list.x
        y: (card.height - height) / 2
        width: Math.max(0, hint.x - Style.spacing.lg - x)
        spacing: Style.spacing.lg
        visible: root.count === 0 && !root.vertical

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "\u{F0120}"          // nf-md-tray_arrow_down
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          color: dropArea.containsDrag ? root.accent : Util.alpha(root.foreground, 0.35)
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - Style.space(30)
          elide: Text.ElideRight
          text: "Drop files and folders here - the shelf keeps a path, never a copy, and taking something off it never deletes the file."
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // -------------------------------------------------------------- hint
      //
      // Vertical: a footer line along the bottom. Horizontal: right-aligned
      // in front of the buttons, and silent when it has nothing to add -
      // there is no room to spend on a permanent hint in a strip.
      Text {
        id: hint
        x: root.vertical ? card.pad + Style.spacing.sm
                         : actions.x - width - Style.spacing.lg
        y: root.vertical ? card.height - card.pad - height
                         : (card.height - height) / 2
        // Wide enough for the longest thing it says -- "Empty the shelf --
        // every file stays where it is" -- rather than eliding the half that
        // carries the reassurance. The list gives up the space; on a strip
        // there is far more of it than the chips need.
        width: root.vertical ? card.width - card.pad * 2 - Style.spacing.sm
                             : Style.space(320)
        horizontalAlignment: root.vertical ? Text.AlignLeft : Text.AlignRight
        // Carries file names inside its flash messages, so same rule as the
        // row labels.
        textFormat: Text.PlainText
        elide: Text.ElideRight

        text: {
          if (root.flash !== "") return root.flash
          if (clearButton.hovered)
            return "Empty the shelf - every file stays where it is"
          if (pinButton.hovered)
            return root.pinned ? "Unpin - let it slide away again"
                               : "Pin - keep it open and make room for it"
          if (root.rowHint !== "") return root.rowHint
          if (!root.vertical) return ""
          return root.count > 0 ? "Click opens · drag takes it out" : ""
        }
        color: root.flash !== "" ? root.accent : root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
