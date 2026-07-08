// Rocky — a floating pixel-cat desktop pet for Claude Code.
//
// One always-on-top window shows a stack of cats, one per active Claude Code
// session. Each cat's mood reflects that session's live state (driven by
// rocky-hook.py writing JSON into ~/.claude/rocky/sessions/). Click a cat to
// jump to its terminal; the stack collapses to just the session that wants
// attention. macOS notifications fire when a session finishes or needs
// permission.
//
// Single file, no dependencies. Build: swiftc -O main.swift -o Rocky

import AppKit
import ApplicationServices
import Foundation

// MARK: - Paths & layout constants

let sessionsDir = ("~/.claude/rocky/sessions" as NSString).expandingTildeInPath

enum L {
    static let width: CGFloat = 194
    static let headerH: CGFloat = 21
    static let rowH: CGFloat = 33
    static let catSize: CGFloat = 25
    static let pad: CGFloat = 7
    static let corner: CGFloat = 10
}

// MARK: - Session model

struct SessionState: Codable {
    var session_id: String
    var status: String
    var event: String?
    var tool: String?
    var detail: String?
    var cwd: String?
    var pid: Int?
    var tty: String?
    var term_app: String?
    var message: String?
    var ts: Double
    var attended_at: Double?
}

enum Expr { case idle, working, happy, alert, sleeping, compacting }

extension SessionState {
    var project: String {
        guard let c = cwd, !c.isEmpty else { return "session" }
        return (c as NSString).lastPathComponent
    }

    var expr: Expr {
        switch status {
        case "needs_permission": return .alert
        case "waiting_for_input": return .happy
        case "running_tool", "processing": return .working
        case "compacting": return .compacting
        default:
            if Date().timeIntervalSince1970 - ts > 300 { return .sleeping }
            return .idle
        }
    }

    var statusLine: String {
        switch status {
        case "running_tool":
            let t = tool ?? "tool"
            let d = (detail ?? "").isEmpty ? "" : ": \(detail!)"
            return "\(t)\(d)"
        case "processing": return "thinking…"
        case "waiting_for_input": return "✅ your turn"
        case "needs_permission": return "🔒 needs permission"
        case "compacting": return "compacting context…"
        default:
            return (Date().timeIntervalSince1970 - ts > 300) ? "asleep" : "idle"
        }
    }

    /// A session is "attended" if the user has looked at it since its last activity.
    var isHot: Bool {
        if status == "needs_permission" { return true }
        if status == "waiting_for_input" { return ts > (attended_at ?? 0) }
        return false
    }

    var alive: Bool {
        guard let p = pid, p > 0 else { return true }
        return kill(pid_t(p), 0) == 0 || errno == EPERM
    }
}

// MARK: - Session store (polls the sessions dir)

final class SessionStore {
    private(set) var sessions: [SessionState] = []
    private var lastStatus: [String: String] = [:]

    /// Returns sessions that transitioned into a notify-worthy state this refresh.
    func refresh() -> [SessionState] {
        let fm = FileManager.default
        var loaded: [SessionState] = []
        let files = (try? fm.contentsOfDirectory(atPath: sessionsDir)) ?? []
        let now = Date().timeIntervalSince1970
        for f in files where f.hasSuffix(".json") {
            let path = (sessionsDir as NSString).appendingPathComponent(f)
            guard let data = fm.contents(atPath: path),
                  let s = try? JSONDecoder().decode(SessionState.self, from: data)
            else { continue }
            // Prune dead or long-stale sessions and tidy their files.
            if !s.alive || now - s.ts > 900 {
                try? fm.removeItem(atPath: path)
                lastStatus[s.session_id] = nil
                continue
            }
            loaded.append(s)
        }

        // Detect transitions worth a banner.
        var toNotify: [SessionState] = []
        for s in loaded {
            let prev = lastStatus[s.session_id]
            if s.status != prev {
                let wasBusy = prev == "running_tool" || prev == "processing" || prev == "compacting"
                if s.status == "needs_permission" ||
                   (s.status == "waiting_for_input" && (wasBusy || prev == nil)) {
                    toNotify.append(s)
                }
            }
            lastStatus[s.session_id] = s.status
        }
        // Forget sessions that vanished.
        let live = Set(loaded.map { $0.session_id })
        lastStatus = lastStatus.filter { live.contains($0.key) }

        // Sort: permission first, then most recent activity.
        sessions = loaded.sorted { a, b in
            let ap = a.status == "needs_permission" ? 1 : 0
            let bp = b.status == "needs_permission" ? 1 : 0
            if ap != bp { return ap > bp }
            return a.ts > b.ts
        }
        return toNotify
    }

    /// The single session shown when collapsed.
    var hot: SessionState? {
        if let perm = sessions.first(where: { $0.status == "needs_permission" }) { return perm }
        if let done = sessions.first(where: { $0.isHot }) { return done }
        return sessions.max { $0.ts < $1.ts }
    }

    func markAttended(_ id: String) {
        let path = (sessionsDir as NSString).appendingPathComponent("\(id).json")
        guard let data = FileManager.default.contents(atPath: path),
              var s = try? JSONDecoder().decode(SessionState.self, from: data) else { return }
        s.attended_at = Date().timeIntervalSince1970
        if let out = try? JSONEncoder().encode(s) {
            try? out.write(to: URL(fileURLWithPath: path))
        }
    }
}

// MARK: - Pixel cat sprite

enum Cat {
    // '.' transparent · 'o' outline · 'b' body(tint) · 'l' belly · 'p' pink · 'e' eye slot
    static let map = [
        "...oo.....oo.",
        "..obbo...obbo",
        "..obbo...obbo",
        "..obbooooobbo",
        ".obbbbbbbbbbbo",
        ".obbbbbbbbbbbo",
        ".obeebbbbeebo",
        ".obeebbbbeebo",
        ".obbbbppbbbbo",
        ".obbbllllbbbo",
        "..obbbbbbbbo.",
        "..obllbbllbo.",
        "..oppo.oppo..",
    ]

    static func draw(in rect: NSRect, tint: NSColor, expr: Expr, tick: Int) {
        let gw = map.map { $0.count }.max() ?? 13
        let gh = map.count
        let cell = min(rect.width, rect.height) / CGFloat(max(gw, gh) + 1)

        // Whole-cat motion by mood.
        var xOff: CGFloat = 0, yOff: CGFloat = 0
        switch expr {
        case .happy:  yOff = -abs(sin(Double(tick) * 0.35)) * 2.5   // bounce up (flipped view)
        case .alert:  xOff = (tick % 2 == 0) ? -1.5 : 1.5           // shake
        case .working: yOff = sin(Double(tick) * 0.5) * 1.0         // gentle bob
        default: break
        }

        let ox = rect.minX + (rect.width - cell * CGFloat(gw)) / 2 + xOff
        let oy = rect.minY + (rect.height - cell * CGFloat(gh)) / 2 + yOff

        let outline = NSColor(white: 0.12, alpha: 1)
        let belly = tint.blended(withFraction: 0.55, of: .white) ?? tint
        let pink = NSColor(calibratedRed: 0.98, green: 0.6, blue: 0.66, alpha: 1)

        func fill(_ cx: Double, _ cy: Double, _ col: NSColor, _ w: Double = 1, _ h: Double = 1) {
            let r = NSRect(x: ox + CGFloat(cx) * cell, y: oy + CGFloat(cy) * cell,
                           width: cell * CGFloat(w) + 0.6, height: cell * CGFloat(h) + 0.6)
            col.setFill()
            NSBezierPath(rect: r).fill()
        }

        var eyeCells: [(Int, Int)] = []
        for (ry, row) in map.enumerated() {
            for (cx, ch) in row.enumerated() {
                switch ch {
                case "o": fill(Double(cx), Double(ry), outline)
                case "b": fill(Double(cx), Double(ry), tint)
                case "l": fill(Double(cx), Double(ry), belly)
                case "p": fill(Double(cx), Double(ry), pink)
                case "e": fill(Double(cx), Double(ry), tint); eyeCells.append((cx, ry))
                default: break
                }
            }
        }

        // Tail on the right, tip swishes when working/idle.
        let swish: Double
        switch expr {
        case .working: swish = sin(Double(tick) * 0.5) * 1.5
        case .idle, .sleeping: swish = sin(Double(tick) * 0.12) * 1.0
        default: swish = 0
        }
        fill(11.5, 10, tint)
        fill(12, 9, tint)
        fill(12, 8, outline, 1, 0.4)
        fill(12 + swish, 7, tint)
        fill(12 + swish, 6.3, tint)

        // Eyes per expression (drawn over the eye slots).
        let blinking = (expr == .sleeping) || (tick % 42 < 3)
        let eyeDark = NSColor(white: 0.1, alpha: 1)
        // Group the two 2x2 eye clusters by their left column.
        let cols = Set(eyeCells.map { $0.0 }).sorted()
        // cols like [3,4,8,9] → two eyes at (3,4) and (8,9)
        let eyes: [(Int, Int)] = stride(from: 0, to: cols.count, by: 2).compactMap {
            $0 + 1 < cols.count ? (cols[$0], cols[$0 + 1]) : nil
        }
        let rows = Set(eyeCells.map { $0.1 }).sorted()
        guard let topRow = rows.first, let botRow = rows.last else { return }
        for (lc, rc) in eyes {
            eyeDark.setFill()
            if blinking {
                fill(Double(lc), Double(botRow), eyeDark, 2, 1)   // closed line
            } else if expr == .happy {
                // upward ^ ^
                fill(Double(lc), Double(botRow), eyeDark)
                fill(Double(rc), Double(topRow), eyeDark)
            } else {
                fill(Double(lc), Double(topRow), eyeDark, 2, 2)   // open
                // glint
                NSColor(white: 0.95, alpha: 0.9).setFill()
                fill(Double(rc), Double(topRow), NSColor(white: 0.95, alpha: 0.9), 0.4, 0.4)
            }
        }

        // Sleeping z's rising.
        if expr == .sleeping {
            let z = NSAttributedString(string: "z", attributes: [
                .font: NSFont.boldSystemFont(ofSize: cell * 2),
                .foregroundColor: NSColor(white: 0.85, alpha: 0.8),
            ])
            let phase = CGFloat((tick / 6) % 3)
            z.draw(at: NSPoint(x: ox + cell * 12, y: oy - cell * 2 - phase * cell))
        }
    }

    /// Deterministic pastel fur colour from the project path.
    static func tint(for seed: String) -> NSColor {
        var h: UInt64 = 1469598103934665603
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let hue = CGFloat(h % 360) / 360.0
        return NSColor(calibratedHue: hue, saturation: 0.5, brightness: 0.92, alpha: 1)
    }
}

// MARK: - The pet view

final class PetView: NSView {
    let store = SessionStore()
    var collapsed = false
    private var tick = 0
    private var rowRects: [(rect: NSRect, session: SessionState)] = []
    private var chevronRect = NSRect.zero
    private var headerRect = NSRect.zero
    private var headerHot = false   // hover highlight on the header
    private var hoverRow = -1

    // Drag vs click tracking.
    private var mouseDownScreen = NSPoint.zero
    private var winOriginAtDown = NSPoint.zero
    private var dragged = false

    // Notification debounce.
    private var lastNotified: [String: Double] = [:]

    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        // Rounded translucent backdrop.
        let bg = NSBezierPath(roundedRect: bounds, xRadius: L.corner, yRadius: L.corner)
        NSColor(white: 0.11, alpha: 0.9).setFill()
        bg.fill()
        NSColor(white: 1, alpha: 0.08).setStroke()
        bg.lineWidth = 1
        bg.stroke()

        // Header (the whole bar toggles collapse — big, forgiving hit target).
        headerRect = NSRect(x: 0, y: 0, width: bounds.width, height: L.headerH)
        if headerHot {
            NSColor(white: 1, alpha: 0.06).setFill()
            NSBezierPath(roundedRect: headerRect.insetBy(dx: 2, dy: 2),
                         xRadius: 6, yRadius: 6).fill()
        }
        let count = store.sessions.count
        let title = NSAttributedString(string: "🐾 \(count)", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor(white: 0.82, alpha: 1),
        ])
        title.draw(at: NSPoint(x: L.pad, y: 4))

        // Chevron as a visibly clickable pill on the right.
        chevronRect = NSRect(x: bounds.width - 22, y: 2, width: 18, height: L.headerH - 4)
        NSColor(white: 1, alpha: headerHot ? 0.14 : 0.09).setFill()
        NSBezierPath(roundedRect: chevronRect, xRadius: 5, yRadius: 5).fill()
        let chev = NSAttributedString(string: collapsed ? "▸" : "▾", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor(white: 0.9, alpha: 1),
        ])
        let cs = chev.size()
        chev.draw(at: NSPoint(x: chevronRect.midX - cs.width / 2,
                              y: chevronRect.midY - cs.height / 2))

        // Rows.
        rowRects.removeAll()
        let shown = collapsed ? [store.hot].compactMap { $0 } : store.sessions
        var y = L.headerH
        for (i, s) in shown.enumerated() {
            let rowRect = NSRect(x: 0, y: y, width: bounds.width, height: L.rowH)
            drawRow(s, in: rowRect, hot: i == hoverRow)
            rowRects.append((rowRect, s))
            y += L.rowH
        }
    }

    private func drawRow(_ s: SessionState, in rect: NSRect, hot: Bool) {
        // Hover highlight for click affordance.
        if hot {
            NSColor(white: 1, alpha: 0.06).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 1.5), xRadius: 6, yRadius: 6).fill()
        }
        // Alert rows get a red wash + accent bar.
        if s.status == "needs_permission" {
            NSColor(calibratedRed: 0.8, green: 0.25, blue: 0.25, alpha: 0.18).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 1.5), xRadius: 6, yRadius: 6).fill()
            NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.35, alpha: 0.9).setFill()
            NSBezierPath(rect: NSRect(x: 3, y: rect.minY + 4, width: 3, height: rect.height - 8)).fill()
        }

        let catRect = NSRect(x: L.pad, y: rect.minY + (rect.height - L.catSize) / 2,
                             width: L.catSize, height: L.catSize)
        Cat.draw(in: catRect, tint: Cat.tint(for: s.cwd ?? s.session_id), expr: s.expr, tick: tick)

        let textX = catRect.maxX + L.pad
        let textW = bounds.width - textX - L.pad
        let pn = NSMutableParagraphStyle(); pn.lineBreakMode = .byTruncatingTail
        let name = NSAttributedString(string: s.project, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: pn,
        ])
        name.draw(in: NSRect(x: textX, y: rect.minY + 4, width: textW, height: 14))

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let sub = NSAttributedString(string: s.statusLine, attributes: [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor(white: 0.66, alpha: 1),
            .paragraphStyle: para,
        ])
        sub.draw(in: NSRect(x: textX, y: rect.minY + 17, width: textW, height: 12))
    }

    // MARK: Sizing

    func resizeWindow(animated: Bool = false) {
        let rows = collapsed ? min(store.sessions.count, 1) : store.sessions.count
        let h = L.headerH + CGFloat(max(rows, store.sessions.isEmpty ? 0 : 1)) * L.rowH + L.pad
        guard let win = window else { return }
        if store.sessions.isEmpty {
            win.orderOut(nil)
            return
        }
        if !win.isVisible { win.orderFront(nil) }
        var f = win.frame
        let top = f.maxY
        f.size = NSSize(width: L.width, height: h)
        f.origin.y = top - h   // keep top-left pinned as height changes
        if f == win.frame { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                win.animator().setFrame(f, display: true)
            }
        } else {
            win.setFrame(f, display: true)
        }
        setFrameSize(f.size)
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Timers

    func startTimers() {
        Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
            self?.tick += 1
            self?.needsDisplay = true
        }
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    private func poll() {
        let notifications = store.refresh()
        for s in notifications { maybeNotify(s) }
        resizeWindow()
        needsDisplay = true
    }

    private func maybeNotify(_ s: SessionState) {
        let now = Date().timeIntervalSince1970
        if let last = lastNotified[s.session_id], now - last < 8 { return }
        lastNotified[s.session_id] = now
        let (msg, sound): (String, String)
        if s.status == "needs_permission" {
            msg = "needs your permission"; sound = "Funk"
        } else {
            msg = "is waiting for you"; sound = "Glass"
        }
        Notify.send(title: "🐾 \(s.project)", text: "Rocky says: \(s.project) \(msg)", sound: sound)
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        mouseDownScreen = NSEvent.mouseLocation
        winOriginAtDown = window?.frame.origin ?? .zero
        dragged = false
    }

    override func mouseDragged(with e: NSEvent) {
        let cur = NSEvent.mouseLocation
        let dx = cur.x - mouseDownScreen.x
        let dy = cur.y - mouseDownScreen.y
        if abs(dx) + abs(dy) > 4 { dragged = true }
        if dragged {
            window?.setFrameOrigin(NSPoint(x: winOriginAtDown.x + dx, y: winOriginAtDown.y + dy))
        }
    }

    override func mouseUp(with e: NSEvent) {
        if dragged {
            if let o = window?.frame.origin {
                UserDefaults.standard.set(NSStringFromPoint(o), forKey: "rocky.origin")
            }
            return
        }
        let p = convert(e.locationInWindow, from: nil)
        // The entire header bar toggles collapse.
        if headerRect.contains(p) {
            collapsed.toggle()
            resizeWindow(animated: true)
            needsDisplay = true
            return
        }
        for entry in rowRects where entry.rect.contains(p) {
            store.markAttended(entry.session.session_id)
            Terminal.focus(entry.session)
            _ = store.refresh()
            resizeWindow()
            needsDisplay = true
            return
        }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil))
    }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let newHeader = headerRect.contains(p)
        var newRow = -1
        for (i, entry) in rowRects.enumerated() where entry.rect.contains(p) { newRow = i }
        if newHeader != headerHot || newRow != hoverRow {
            headerHot = newHeader
            hoverRow = newRow
            needsDisplay = true
        }
    }

    override func mouseExited(with e: NSEvent) {
        if headerHot || hoverRow != -1 {
            headerHot = false; hoverRow = -1; needsDisplay = true
        }
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(headerRect, cursor: .pointingHand)
        for entry in rowRects { addCursorRect(entry.rect, cursor: .pointingHand) }
    }

    override func rightMouseDown(with e: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: collapsed ? "Expand" : "Collapse",
                     action: #selector(toggleCollapse), keyEquivalent: "").target = self
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Rocky", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        NSMenu.popUpContextMenu(menu, with: e, for: self)
    }

    @objc private func toggleCollapse() { collapsed.toggle(); resizeWindow(); needsDisplay = true }
    @objc private func toggleLogin() { LoginItem.toggle() }
}

// MARK: - Notifications & terminal focus (osascript)

enum Notify {
    static func send(title: String, text: String, sound: String) {
        let script = "display notification \(q(text)) with title \(q(title)) sound name \(q(sound))"
        run(script)
    }
    private static func q(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    static func run(_ script: String) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.launchPath = "/usr/bin/osascript"
            p.arguments = ["-e", script]
            try? p.run()
        }
    }
}

enum Terminal {
    static func focus(_ s: SessionState) {
        guard let app = s.term_app else { return }
        switch app {
        case "Warp":
            focusWarp(project: s.project, cwd: s.cwd ?? "")
        case "iTerm2":
            focusITerm(tty: s.tty)
        default:
            Notify.run("tell application \"\(app)\" to activate")
        }
    }

    // iTerm2 is fully scriptable — select the exact tab by tty.
    private static func focusITerm(tty: String?) {
        guard let tty = tty else {
            Notify.run("tell application \"iTerm2\" to activate"); return
        }
        Notify.run("""
        tell application "iTerm2"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              repeat with se in sessions of t
                if tty of se is "\(tty)" then
                  select w
                  select t
                  return
                end if
              end repeat
            end repeat
          end repeat
        end tell
        """)
    }

    // Warp has no scripting API, so drive it through the Accessibility API:
    // find the tab whose title matches the project and press it. Requires the
    // user to grant Rocky Accessibility permission; otherwise we just activate
    // Warp (no worse than before).
    private static func focusWarp(project: String, cwd: String) {
        let warp = NSRunningApplication
            .runningApplications(withBundleIdentifier: "dev.warp.Warp-Stable").first
        func activateOnly() { warp?.activate() }

        guard ensureAXTrusted() else { activateOnly(); return }
        guard let warp = warp else { return }

        let appEl = AXUIElementCreateApplication(warp.processIdentifier)
        var best: (score: Int, tab: AXUIElement, window: AXUIElement)?

        for win in axChildren(appEl) where axRole(win) == kAXWindowRole {
            findTabs(in: win) { tab in
                let label = [axStr(tab, kAXTitleAttribute),
                             axStr(tab, kAXDescriptionAttribute),
                             axStr(tab, kAXValueAttribute)]
                    .compactMap { $0 }.joined(separator: " ").lowercased()
                let score = matchScore(label: label, project: project, cwd: cwd)
                if score > 0, best == nil || score > best!.score {
                    best = (score, tab, win)
                }
            }
        }

        warp.activate()
        if let hit = best {
            AXUIElementPerformAction(hit.window, kAXRaiseAction as CFString)
            AXUIElementPerformAction(hit.tab, kAXPressAction as CFString)
        }
    }

    private static func matchScore(label: String, project: String, cwd: String) -> Int {
        let p = project.lowercased()
        if !cwd.isEmpty, label.contains(cwd.lowercased()) { return 3 }
        if !p.isEmpty, label.contains(p) { return 2 }
        if label.contains("claude") { return 1 }
        return 0
    }

    /// Returns true if we already have (or just can't get) AX trust. Prompts once.
    private static func ensureAXTrusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
        return false
    }

    // AX helpers
    private static func axChildren(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v)
        return (v as? [AXUIElement]) ?? []
    }
    private static func axRole(_ el: AXUIElement) -> String {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v)
        return (v as? String) ?? ""
    }
    private static func axStr(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, attr as CFString, &v)
        return v as? String
    }
    /// Depth-first search for tab-like controls (radio buttons / role "tab").
    private static func findTabs(in el: AXUIElement, depth: Int = 0,
                                 _ found: (AXUIElement) -> Void) {
        if depth > 12 { return }
        for c in axChildren(el) {
            let role = axRole(c)
            let rdesc = (axStr(c, kAXRoleDescriptionAttribute) ?? "").lowercased()
            if role == kAXRadioButtonRole || rdesc.contains("tab") {
                found(c)
            }
            findTabs(in: c, depth: depth + 1, found)
        }
    }
}

// MARK: - Login item (LaunchAgent toggle)

enum LoginItem {
    static let plist = ("~/Library/LaunchAgents/com.ketan.rocky.plist" as NSString).expandingTildeInPath
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plist) }
    static func toggle() {
        let uid = getuid()
        if isEnabled {
            shell("/bin/launchctl", ["bootout", "gui/\(uid)/com.ketan.rocky"])
            try? FileManager.default.removeItem(atPath: plist)
        } else {
            shell("/bin/launchctl", ["bootstrap", "gui/\(uid)", plist])
        }
    }
    private static func shell(_ path: String, _ args: [String]) {
        let p = Process(); p.launchPath = path; p.arguments = args; try? p.run()
    }
}

// MARK: - App bootstrap

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var pet: PetView!

    func applicationDidFinishLaunching(_ n: Notification) {
        let start = NSRect(x: 0, y: 0, width: L.width, height: L.headerH + L.rowH + L.pad)
        // A non-activating panel receives clicks on the first try and never
        // steals keyboard focus from the terminal — key to fluent interaction.
        let panel = NSPanel(contentRect: start,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        window = panel
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true

        pet = PetView(frame: start)
        window.contentView = pet

        // Restore saved position, else top-right.
        if let saved = UserDefaults.standard.string(forKey: "rocky.origin") {
            window.setFrameOrigin(NSPointFromString(saved))
        } else if let vf = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: vf.maxX - L.width - 20, y: vf.maxY - 220))
        }

        pet.startTimers()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
