// Drives one process through the macOS accessibility API, as a user does, for the QA protocol (docs/qa/protocol.md):
// reads its windows' elements, presses, clicks, types, scrolls and screenshots its windows and no other: a click, a
// hover or a scroll is refused unless one of the process's windows is the frontmost one at that point, as the pointer's
// events reach whatever window is there. It never reads the system's Apple menu, which lists the user's own recent
// files, nor an open file panel, which lists the user's folders, and takes no screenshot while one is open. Built and
// run by scripts/qa-drive.sh; the terminal running it needs Accessibility in System Settings.
import AppKit
import ApplicationServices
import Foundation

let usage = """
    usage: qa-drive.sh <command> <pid> [arguments]
      tree <pid> [depth] [menus]             the windows' elements: role, title, description, value, help, frame
      windows <pid>                          the process's windows
      find <pid> <text> [role]               elements whose title, description, value or help has text (=text: exactly)
      press <pid> <text> [role] [n]          press the n-th match, else click its centre
      click | dclick | rclick <pid> <text> [role] [n]   click, double-click or right-click the n-th match
      clickat <pid> <x> <y> [clicks]         click a point of the screen
      hover <pid> <x> <y>                    move the pointer there
      set <pid> <text> <value> [role] [n]    click a field, select all of it and type value
      type <pid> <text>                      type into what has focus
      key <pid> <name> [cmd,shift,opt,ctrl]  return, escape, tab, delete, space, arrows, a letter
      focused <pid>                          the element with keyboard focus
      scroll <pid> <text> <steps>            scroll over the match, negative steps down
      resize <pid> <width> <height>          resize the first window
      shot <pid> <file> [window title]       screenshot of the window (the first, or the one titled so)
    """

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[2]) else { fail(usage, code: 2) }
let command = args[1]
let rest = Array(args.dropFirst(3))
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 5)

// MARK: Reading elements

func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
}

func element(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
}

func axValue(_ value: CFTypeRef?) -> AXValue? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    return unsafeBitCast(value, to: AXValue.self)
}

func str(_ e: AXUIElement, _ name: String) -> String? {
    switch attr(e, name) {
    case let s as String: s.isEmpty ? nil : s
    case let n as NSNumber: n.stringValue
    default: nil
    }
}

func children(_ e: AXUIElement) -> [AXUIElement] {
    (attr(e, kAXChildrenAttribute) as? [CFTypeRef] ?? []).compactMap(element)
}

func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = axValue(attr(e, kAXPositionAttribute)), let s = axValue(attr(e, kAXSizeAttribute)) else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p, .cgPoint, &point)
    AXValueGetValue(s, .cgSize, &size)
    return CGRect(origin: point, size: size)
}

func describe(_ e: AXUIElement) -> String {
    var parts = [str(e, kAXRoleAttribute) ?? "?"]
    if let s = str(e, kAXSubroleAttribute) { parts.append("(\(s))") }
    if let t = str(e, kAXTitleAttribute) { parts.append("title=“\(t)”") }
    if let d = str(e, kAXDescriptionAttribute) { parts.append("desc=“\(d)”") }
    if let v = str(e, kAXValueAttribute) { parts.append("value=“\(v.prefix(160))”") }
    if let h = str(e, kAXHelpAttribute) { parts.append("help=“\(h.prefix(80))”") }
    if let i = str(e, kAXIdentifierAttribute) { parts.append("id=\(i)") }
    if attr(e, kAXEnabledAttribute) as? Bool == false { parts.append("DISABLED") }
    if let f = frame(e) { parts.append("@\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))") }
    return parts.joined(separator: " ")
}

func windows() -> [AXUIElement] { (attr(app, kAXWindowsAttribute) as? [CFTypeRef] ?? []).compactMap(element) }

/// A file panel lists the user's own folders and files: never read.
func isFilePanel(_ e: AXUIElement) -> Bool {
    ["open-panel", "save-panel"].contains(str(e, kAXIdentifierAttribute) ?? "")
}

/// Whether a file panel is open: as a window of its own, or as a sheet on one.
func filePanelOpen() -> Bool {
    windows().contains { window in isFilePanel(window) || children(window).contains(where: isFilePanel) }
}

/// Where elements are looked for: an open pop-up or context menu, the focused window, the other windows, and the menu
/// bar when asked for.
func roots(menus: Bool) -> [AXUIElement] {
    var found = children(app).filter { str($0, kAXRoleAttribute) == "AXMenu" }
    if let focused = element(attr(app, kAXFocusedWindowAttribute)) { found.append(focused) }
    for w in windows() where !found.contains(where: { CFEqual($0, w) }) { found.append(w) }
    if menus, let bar = element(attr(app, kAXMenuBarAttribute)) { found.append(bar) }
    return found.filter { !isFilePanel($0) }
}

func walk(_ e: AXUIElement, depth: Int, max: Int, visit: (AXUIElement, Int) -> Void) {
    // The system's Apple menu lists the user's own recent documents.
    if str(e, kAXRoleAttribute) == "AXMenuBarItem", str(e, kAXTitleAttribute) == "Apple" { return }
    visit(e, depth)
    guard depth < max else { return }
    for c in children(e) { walk(c, depth: depth + 1, max: max, visit: visit) }
}

let searched = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute, kAXIdentifierAttribute]

/// Elements whose text has `text` in it, or is it when it starts with `=`, of `role` when given: exact ones first.
func matches(_ text: String, role: String?) -> [AXUIElement] {
    let exact = text.hasPrefix("=")
    let needle = (exact ? String(text.dropFirst()) : text).lowercased()
    var found: [AXUIElement] = []
    for root in roots(menus: true) {
        walk(root, depth: 0, max: 60) { e, _ in
            if let role, str(e, kAXRoleAttribute) != role { return }
            let hay = searched.compactMap { str(e, $0)?.lowercased() }
            if hay.contains(needle) || (!exact && hay.contains { $0.contains(needle) }) { found.append(e) }
        }
    }
    let isExact = { (e: AXUIElement) in searched.contains { str(e, $0)?.lowercased() == needle } }
    return found.filter(isExact) + found.filter { !isExact($0) }
}

func pick(_ text: String, role: String?, n: Int) -> AXUIElement {
    let found = matches(text, role: role)
    guard n < found.count else { fail("not found: \(text) role=\(role ?? "any") (\(found.count) matches)") }
    return found[n]
}

// MARK: Acting

func activate() {
    NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    usleep(250_000)
}

/// The process whose window is frontmost on screen at `p`, which the pointer's events there reach.
func owner(at p: CGPoint) -> pid_t? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in list {
        guard (window[kCGWindowAlpha as String] as? Double ?? 0) > 0,
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(p) else { continue }
        return window[kCGWindowOwnerPID as String] as? pid_t
    }
    return nil
}

/// Refuses a pointer event at `p` that would reach another process's window, or none.
func ensureOwnWindow(at p: CGPoint) {
    guard owner(at: p) == pid else {
        fail("refused: \(Int(p.x)),\(Int(p.y)) is not on a window of \(pid), so nothing was sent there")
    }
}

func mouse(_ p: CGPoint, button: CGMouseButton = .left, clicks: Int = 1) {
    ensureOwnWindow(at: p)
    let (down, up): (CGEventType, CGEventType) = button == .left ? (.leftMouseDown, .leftMouseUp) : (.rightMouseDown, .rightMouseUp)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: button)?.post(tap: .cghidEventTap)
    usleep(80_000)
    for i in 1...max(1, clicks) {
        for type in [down, up] {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            event?.post(tap: .cghidEventTap)
            usleep(40_000)
        }
    }
}

/// Virtual key codes of a US keyboard (Carbon's `kVK_*`).
let keyCodes: [String: CGKeyCode] = [
    "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126,
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
    "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ",": 43, ".": 47,
]
let modifiers: [String: CGEventFlags] = ["cmd": .maskCommand, "shift": .maskShift, "opt": .maskAlternate, "ctrl": .maskControl]

func key(_ name: String, mods: [String]) {
    guard let code = keyCodes[name] else { fail("no key \(name)", code: 2) }
    let flags = mods.reduce(into: CGEventFlags()) { $0.insert(modifiers[$1] ?? []) }
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        event?.flags = flags
        event?.postToPid(pid)
        usleep(30_000)
    }
}

func type(_ text: String) {
    for unit in text.utf16 {
        var character = unit
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
            event?.postToPid(pid)
            usleep(8_000)
        }
    }
}

func center(_ e: AXUIElement) -> CGPoint {
    guard let f = frame(e) else { fail("no frame: " + describe(e)) }
    return CGPoint(x: f.midX, y: f.midY)
}

func point(_ x: String, _ y: String) -> CGPoint { CGPoint(x: Double(x) ?? 0, y: Double(y) ?? 0) }

func optional(_ index: Int) -> String? { rest.count > index && !rest[index].isEmpty ? rest[index] : nil }

func windowNumber(title: String?) -> Int? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
    let window = title.map { t in mine.first { ($0[kCGWindowName as String] as? String) == t } } ?? mine.first
    return window?[kCGWindowNumber as String] as? Int
}

// MARK: Commands

switch command {
case "tree":
    let depth = optional(0).flatMap(Int.init) ?? 40
    for root in roots(menus: optional(1) == "menus") {
        walk(root, depth: 0, max: depth) { e, d in print(String(repeating: "  ", count: d) + describe(e)) }
    }
case "windows":
    for w in windows() { print(describe(w)) }
case "find":
    for e in matches(rest.first ?? "", role: optional(1)) { print(describe(e)) }
case "press", "click", "dclick", "rclick":
    let e = pick(rest.first ?? "", role: optional(1), n: optional(2).flatMap(Int.init) ?? 0)
    activate()
    if command == "press", AXUIElementPerformAction(e, kAXPressAction as CFString) == .success {
        print("pressed " + describe(e))
        break
    }
    // An element outside the window's visible part is scrolled into view first, as a user scrolls to it.
    AXUIElementPerformAction(e, "AXScrollToVisible" as CFString)
    usleep(300_000)
    mouse(center(e), button: command == "rclick" ? .right : .left, clicks: command == "dclick" ? 2 : 1)
    print("clicked " + describe(e))
case "clickat":
    guard rest.count >= 2 else { fail(usage, code: 2) }
    activate()
    mouse(point(rest[0], rest[1]), clicks: optional(2).flatMap(Int.init) ?? 1)
case "hover":
    guard rest.count >= 2 else { fail(usage, code: 2) }
    activate()
    ensureOwnWindow(at: point(rest[0], rest[1]))
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point(rest[0], rest[1]), mouseButton: .left)?
        .post(tap: .cghidEventTap)
case "set":
    guard rest.count >= 2 else { fail(usage, code: 2) }
    let e = pick(rest[0], role: optional(2), n: optional(3).flatMap(Int.init) ?? 0)
    activate()
    mouse(center(e))
    AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    usleep(150_000)
    key("a", mods: ["cmd"])
    key("delete", mods: [])
    type(rest[1])
    print("set " + describe(e))
case "type":
    activate()
    type(rest.first ?? "")
case "key":
    activate()
    key(rest.first ?? "", mods: optional(1)?.split(separator: ",").map(String.init) ?? [])
case "focused":
    print(element(attr(app, kAXFocusedUIElementAttribute)).map(describe) ?? "nothing focused")
case "scroll":
    guard rest.count >= 2 else { fail(usage, code: 2) }
    let target = center(pick(rest[0], role: nil, n: 0))
    activate()
    ensureOwnWindow(at: target)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(100_000)
    let steps = Int32(rest[1]) ?? -5
    for _ in 0..<abs(steps) {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: steps < 0 ? -40 : 40, wheel2: 0, wheel3: 0)
        event?.location = target
        event?.post(tap: .cghidEventTap)
        usleep(20_000)
    }
case "resize":
    guard rest.count >= 2, let window = windows().first else { fail(usage, code: 2) }
    var size = CGSize(width: Double(rest[0]) ?? 800, height: Double(rest[1]) ?? 600)
    if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) }
    print("resized " + describe(window))
case "shot":
    // A file panel lists the user's own folders and files, and a screenshot would keep them.
    guard !filePanelOpen() else { fail("refused: a file panel is open; close it before taking a screenshot") }
    guard let file = rest.first, let number = windowNumber(title: optional(1)) else { fail("no window to capture") }
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l", String(number), file]
    try capture.run()
    capture.waitUntilExit()
    print("shot \(file)")
default:
    fail(usage, code: 2)
}
