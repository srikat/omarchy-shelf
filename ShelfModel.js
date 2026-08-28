.pragma library

// Shelf - pure helpers over plain data, no QML object references.
//
// An item is: { path, fileName, ext, kind, icon, isImage, isDir, missing, addedAt }
//
// The path/uri helpers and the Nerd Font glyph table are adapted from
// bylund.ledge (MIT), which checked every codepoint against the font's own
// `post` table - the Material Design range is dense enough that a neighbouring
// codepoint is a completely unrelated picture.

var STATE_VERSION = 1

// The state file is world-writable-adjacent: anything that can write to
// ~/.local/state can replace it, and it is parsed by a service inside the
// long-lived shell process. So it is treated as untrusted input, and every
// dimension of it is bounded here. The read itself is bounded separately, in
// Service.qml, because a byte ceiling cannot stop a FIFO from blocking.
var MAX_ITEMS = 500
// Longer than PATH_MAX, so a real path is never the thing that trips it.
var MAX_PATH = 4096
// What any single label may render. Elision handles width; this handles the
// cost of laying out a pathological string in the first place.
var MAX_LABEL = 256

function truncate(text, limit) {
    var s = String(text)
    return s.length > limit ? s.slice(0, limit) : s
}

// A path this plugin is willing to hold. Absolute, bounded, and free of
// control characters -- a newline would also break the `text/uri-list`
// contract on drag-out and on the clipboard.
function acceptablePath(path) {
    if (typeof path !== "string")
        return false
    if (path.length === 0 || path.length > MAX_PATH)
        return false
    if (path.charAt(0) !== "/")
        return false
    for (var i = 0; i < path.length; i++) {
        var code = path.charCodeAt(i)
        if (code < 0x20 || code === 0x7f)
            return false
    }
    return true
}

var ICONS = {
    file: "\u{F0214}",     // nf-md-file
    image: "\u{F021F}",    // nf-md-file_image
    video: "\u{F022B}",    // nf-md-file_video
    audio: "\u{F0223}",    // nf-md-file_music
    pdf: "\u{F0226}",      // nf-md-file_pdf_box
    document: "\u{F0219}", // nf-md-file_document
    archive: "\u{F06EB}",  // nf-md-folder_zip
    code: "\u{F022E}",     // nf-md-file_code
    folder: "\u{F024B}"    // nf-md-folder
}

var EXTENSIONS = {
    png: "image", jpg: "image", jpeg: "image", gif: "image", webp: "image",
    bmp: "image", svg: "image", avif: "image", ico: "image", tiff: "image",
    mp4: "video", mkv: "video", webm: "video", mov: "video", avi: "video",
    mp3: "audio", flac: "audio", ogg: "audio", wav: "audio", m4a: "audio", opus: "audio",
    pdf: "pdf",
    doc: "document", docx: "document", odt: "document", rtf: "document",
    txt: "document", md: "document", csv: "document", xlsx: "document", ods: "document",
    zip: "archive", tar: "archive", gz: "archive", xz: "archive", zst: "archive",
    bz2: "archive", "7z": "archive", rar: "archive",
    js: "code", ts: "code", qml: "code", json: "code", yaml: "code", yml: "code",
    toml: "code", sh: "code", bash: "code", py: "code", rb: "code", rs: "code",
    go: "code", c: "code", h: "code", cpp: "code", lua: "code", html: "code", css: "code"
}

// "/home/me/a b.png" -> "a b.png"
function baseName(path) {
    var clean = String(path).replace(/\/+$/, "")
    var slash = clean.lastIndexOf("/")
    return slash === -1 ? clean : clean.slice(slash + 1)
}

// "/home/me/notes/a.md" -> "~/notes". Home is collapsed because the shelf is
// narrow and the interesting half of a path is the tail.
function parentLabel(path, home) {
    var clean = String(path).replace(/\/+$/, "")
    var slash = clean.lastIndexOf("/")
    var dir = slash <= 0 ? "/" : clean.slice(0, slash)
    if (home && dir === String(home))
        return "~"
    if (home && dir.indexOf(String(home) + "/") === 0)
        return truncate("~" + dir.slice(String(home).length), MAX_LABEL)
    return truncate(dir, MAX_LABEL)
}

function extensionOf(path) {
    var name = baseName(path)
    var dot = name.lastIndexOf(".")
    if (dot <= 0 || dot === name.length - 1)
        return ""
    return name.slice(dot + 1).toLowerCase()
}

// `isDir` comes from a stat done outside this file; until it has run, a
// trailing slash is the only hint a drop carries.
function kindOf(path, isDir) {
    if (isDir || String(path).slice(-1) === "/")
        return "folder"
    var kind = EXTENSIONS[extensionOf(path)]
    return kind ? kind : "file"
}

function iconFor(path, isDir) {
    var icon = ICONS[kindOf(path, isDir)]
    return icon ? icon : ICONS.file
}

// "file:///home/me/a%20b.png" -> "/home/me/a b.png". Non-file URLs return "".
function pathFromUrl(url) {
    var text = String(url)
    if (text.indexOf("file://") === 0)
        text = text.slice("file://".length)
    else if (text.indexOf("://") !== -1)
        return ""
    var hash = text.indexOf("#")
    if (hash !== -1)
        text = text.slice(0, hash)
    try {
        text = decodeURIComponent(text)
    } catch (e) {
        // Leave percent-escapes in place rather than dropping the file.
    }
    return text.indexOf("/") === 0 ? text : ""
}

// "/home/me/a b.png" -> "file:///home/me/a%20b.png"
function urlFromPath(path) {
    return "file://" + String(path).split("/").map(encodeURIComponent).join("/")
}

// text/uri-list payload for a drag or for the clipboard (CRLF per RFC 2483).
function uriList(paths) {
    return paths.map(urlFromPath).join("\r\n") + "\r\n"
}

function makeItem(path, addedAt, isDir) {
    var dir = isDir === true
    var kind = kindOf(path, dir)
    return {
        path: String(path).replace(/\/+$/, "") || "/",
        fileName: truncate(baseName(path), MAX_LABEL),
        ext: extensionOf(path),
        kind: kind,
        icon: iconFor(path, dir),
        isImage: kind === "image",
        isDir: dir,
        missing: false,
        addedAt: addedAt ? addedAt : 0
    }
}

// Re-derives the display fields after a stat has settled `isDir`, without
// losing `addedAt` or the item's place in the list.
function reclassify(item, state) {
    var dir = state === "d"
    var kind = kindOf(item.path, dir)
    return {
        path: item.path,
        fileName: item.fileName,
        ext: item.ext,
        kind: kind,
        icon: iconFor(item.path, dir),
        isImage: kind === "image",
        isDir: dir,
        missing: state === "x",
        addedAt: item.addedAt
    }
}

// Accepts urls (from a drop) or plain paths (from the CLI); returns clean,
// deduplicated items, skipping anything that is not a local path.
function itemsFromDrop(entries, addedAt) {
    var seen = {}
    var items = []
    for (var i = 0; i < entries.length; i++) {
        var raw = String(entries[i]).trim()
        if (!raw || raw.indexOf("#") === 0)
            continue
        var path = raw.indexOf("/") === 0 ? raw : pathFromUrl(raw)
        if (!path || seen[path] || !acceptablePath(path))
            continue
        if (items.length >= MAX_ITEMS)
            break
        seen[path] = true
        items.push(makeItem(path, addedAt))
    }
    return items
}

// New items go on top; anything already on the shelf keeps its old place
// rather than jumping, so re-dropping a file is a no-op you can't see.
function merge(existing, incoming) {
    var have = {}
    for (var i = 0; i < existing.length; i++)
        have[existing[i].path] = true
    var fresh = []
    for (var j = 0; j < incoming.length; j++) {
        if (have[incoming[j].path])
            continue
        have[incoming[j].path] = true
        fresh.push(incoming[j])
    }
    var merged = fresh.concat(existing)
    return {
        items: merged.length > MAX_ITEMS ? merged.slice(0, MAX_ITEMS) : merged,
        added: fresh.length
    }
}

var EDGES = ["right", "left", "top", "bottom"]
var REVEALS = ["hover", "click"]
// A connector name is short: "eDP-1", "DP-2", "HDMI-A-1", "HEADLESS-3".
var MAX_SCREEN = 64

// How the shelf comes out on its own: resting the pointer on its edge, or
// only a click on the handle.
function normalizeReveal(value) {
    var text = String(value === undefined || value === null ? "" : value).trim().toLowerCase()
    return REVEALS.indexOf(text) === -1 ? "hover" : text
}

// Anything unrecognized falls back to the right edge rather than leaving the
// panel anchored to nothing.
function normalizeEdge(value) {
    var text = String(value === undefined || value === null ? "" : value).trim().toLowerCase()
    return EDGES.indexOf(text) === -1 ? "right" : text
}

// The monitor the shelf lives on, spelled the way the compositor spells it.
// Bounded and held to the characters those names actually use, because this
// one comes back out of the state file and the state file is untrusted. Empty
// means no monitor has been chosen yet, which is not the same as a bad one:
// the shelf takes the first screen it is given and records that.
function normalizeScreen(value) {
    var text = String(value === undefined || value === null ? "" : value).trim()
    if (!text || text.length > MAX_SCREEN)
        return ""
    return /^[A-Za-z0-9._-]+$/.test(text) ? text : ""
}

// How many bytes the state helper should expect on stdin. It reads exactly
// this many rather than waiting for end of input, and a file name outside
// ASCII makes it differ from `text.length`.
function byteLength(text) {
    var s = String(text)
    var bytes = 0
    for (var i = 0; i < s.length; i++) {
        var code = s.charCodeAt(i)
        if (code < 0x80)
            bytes += 1
        else if (code < 0x800)
            bytes += 2
        else if (code >= 0xd800 && code <= 0xdbff) {
            // A surrogate pair is one codepoint and four bytes.
            bytes += 4
            i++
        } else
            bytes += 3
    }
    return bytes
}

function serialize(items, pinned, reveal, edge, handle, screen) {
    var plain = items.map(function (item) {
        return { path: item.path, addedAt: item.addedAt }
    })
    return JSON.stringify({
        version: STATE_VERSION,
        pinned: pinned === true,
        reveal: normalizeReveal(reveal),
        handle: handle !== false,
        edge: normalizeEdge(edge),
        screen: normalizeScreen(screen),
        items: plain
    }, null, 2) + "\n"
}

// Tolerates an empty file, a bare array, and unknown extra fields.
function deserialize(text) {
    var empty = { items: [], pinned: false, reveal: "hover", edge: "right", handle: true, screen: "" }
    if (!text || !String(text).trim())
        return empty
    var parsed
    try {
        parsed = JSON.parse(text)
    } catch (e) {
        return empty
    }
    var list = Array.isArray(parsed)
        ? parsed
        : (parsed && Array.isArray(parsed.items) ? parsed.items : [])
    var items = []
    for (var i = 0; i < list.length && items.length < MAX_ITEMS; i++) {
        var entry = list[i]
        var path = typeof entry === "string" ? entry : (entry && entry.path)
        if (!acceptablePath(path))
            continue
        var when = entry && typeof entry.addedAt === "number" && isFinite(entry.addedAt)
            ? entry.addedAt : 0
        items.push(makeItem(path, when))
    }
    return {
        items: items,
        pinned: !!(parsed && parsed.pinned === true),
        // `reveal` replaced a `hoverReveal` boolean; a state file written
        // before the rename still says what the user chose, so read it rather
        // than resetting them to the default.
        reveal: (parsed && parsed.reveal !== undefined)
            ? normalizeReveal(parsed.reveal)
            : ((parsed && parsed.hoverReveal === false) ? "click" : "hover"),
        edge: normalizeEdge(parsed && parsed.edge),
        handle: !(parsed && parsed.handle === false),
        screen: normalizeScreen(parsed && parsed.screen)
    }
}

// $XDG_STATE_HOME when the session sets one, ~/.local/state otherwise. An
// empty string means "nowhere to persist" - the shelf still works for as long
// as the shell runs.
function stateFile(home, stateHome) {
    var base = stateHome ? String(stateHome)
                         : (home ? String(home) + "/.local/state" : "")
    return base ? base + "/omarchy/shelf.json" : ""
}
