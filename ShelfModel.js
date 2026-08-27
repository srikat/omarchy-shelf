.pragma library

// Shelf — pure helpers over plain data, no QML object references.
//
// An item is: { path, fileName, ext, kind, icon, isImage, isDir, missing, addedAt }
//
// The path/uri helpers and the Nerd Font glyph table are adapted from
// bylund.ledge (MIT), which checked every codepoint against the font's own
// `post` table — the Material Design range is dense enough that a neighbouring
// codepoint is a completely unrelated picture.

var STATE_VERSION = 1

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
        return "~" + dir.slice(String(home).length)
    return dir
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
        fileName: baseName(path),
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
        if (!path || seen[path])
            continue
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
    return { items: fresh.concat(existing), added: fresh.length }
}

function serialize(items, pinned, hoverReveal) {
    var plain = items.map(function (item) {
        return { path: item.path, addedAt: item.addedAt }
    })
    return JSON.stringify({
        version: STATE_VERSION,
        pinned: pinned === true,
        hoverReveal: hoverReveal !== false,
        items: plain
    }, null, 2) + "\n"
}

// Tolerates an empty file, a bare array, and unknown extra fields.
function deserialize(text) {
    var empty = { items: [], pinned: false, hoverReveal: true }
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
    for (var i = 0; i < list.length; i++) {
        var entry = list[i]
        var path = typeof entry === "string" ? entry : (entry && entry.path)
        if (!path || String(path).indexOf("/") !== 0)
            continue
        items.push(makeItem(String(path), entry && entry.addedAt ? entry.addedAt : 0))
    }
    return {
        items: items,
        pinned: !!(parsed && parsed.pinned === true),
        // Absent means on: the hot edge is the shelf's whole reason to exist,
        // and a state file written before the setting existed should keep it.
        hoverReveal: !(parsed && parsed.hoverReveal === false)
    }
}

// $XDG_STATE_HOME when the session sets one, ~/.local/state otherwise. An
// empty string means "nowhere to persist" — the shelf still works for as long
// as the shell runs.
function stateFile(home, stateHome) {
    var base = stateHome ? String(stateHome)
                         : (home ? String(home) + "/.local/state" : "")
    return base ? base + "/omarchy/shelf.json" : ""
}
