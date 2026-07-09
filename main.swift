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
import Foundation

// MARK: - Paths & layout constants

// Rocky's own hook-written state (rich, real-time), and Claude Code's live
// session registry (authoritative list of every running session).
let sessionsDir = ("~/.claude/rocky/sessions" as NSString).expandingTildeInPath
let registryDir = ("~/.claude/sessions" as NSString).expandingTildeInPath

enum L {
    static let width: CGFloat = 216       // expanded window width
    static let collapsed: CGFloat = 68    // collapsed = compact pet square
    static let heroH: CGFloat = 58        // hero (pet) header height when expanded
    static let heroCat: CGFloat = 46      // the one animated hero cat
    static let tabH: CGFloat = 31         // per-session tab row
    static let pad: CGFloat = 8
    static let corner: CGFloat = 13
}

/// Rocky's signature colour — a consistent ginger cat, so it reads as one
/// character rather than changing per session.
let rockyTint = NSColor(calibratedRed: 0.96, green: 0.62, blue: 0.33, alpha: 1)

/// Colour coding for a session's state (status dots, glows).
func statusColor(_ status: String) -> NSColor {
    switch status {
    case "needs_permission": return NSColor(calibratedRed: 0.97, green: 0.40, blue: 0.40, alpha: 1)
    case "waiting_for_input": return NSColor(calibratedRed: 0.40, green: 0.86, blue: 0.52, alpha: 1)
    case "running_tool", "processing", "compacting":
        return NSColor(calibratedRed: 0.40, green: 0.68, blue: 0.98, alpha: 1)
    default: return NSColor(white: 0.55, alpha: 1)
    }
}

// MARK: - Session model

struct SessionState: Codable {
    var session_id: String
    var status: String
    var event: String?
    var tool: String?
    var detail: String?
    var cwd: String?
    var transcript: String?
    var pid: Int?
    var tty: String?
    var term_app: String?
    var message: String?
    var ts: Double
    var attended_at: Double?
    var title: String?   // resolved from the transcript, not from disk
}

enum Expr { case idle, working, happy, alert, sleeping, compacting }

extension SessionState {
    var project: String {
        guard let c = cwd, !c.isEmpty else { return "session" }
        return (c as NSString).lastPathComponent
    }

    /// Human label for the UI: Claude's session title, falling back to folder.
    var displayName: String {
        if let t = title, !t.isEmpty { return t }
        return project
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

// MARK: - Claude Code live session registry (~/.claude/sessions/<pid>.json)

struct RegistryEntry: Codable {
    var pid: Int
    var sessionId: String
    var cwd: String?
    var name: String?       // Claude's own friendly session name
    var status: String?     // "idle" | "busy"
    var kind: String?       // "interactive" for real terminal sessions
    var updatedAt: Double?  // ms since epoch
}

extension SessionState {
    /// Minimal state for a registry session that hasn't fired a hook yet.
    init(registry r: RegistryEntry) {
        session_id = r.sessionId
        status = (r.status == "busy") ? "processing" : "idle"
        event = nil; tool = nil; detail = nil
        cwd = r.cwd
        transcript = nil
        pid = r.pid
        tty = nil; term_app = nil; message = nil
        ts = (r.updatedAt ?? 0) / 1000.0
        attended_at = nil
        title = r.name
    }
}

func pidAlive(_ pid: Int) -> Bool {
    guard pid > 0 else { return false }
    return kill(pid_t(pid), 0) == 0 || errno == EPERM
}

// MARK: - Session store

final class SessionStore {
    private(set) var sessions: [SessionState] = []
    private var lastStatus: [String: String] = [:]

    /// Merge Claude's live registry (authoritative list of running sessions)
    /// with Rocky's hook data (rich real-time status). The registry guarantees
    /// every session shows up even before it fires a hook. Returns sessions
    /// that just transitioned into a notify-worthy state.
    func refresh() -> [SessionState] {
        let fm = FileManager.default

        // 1. Hook data indexed by sessionId (tools, permission, your-turn…).
        var hookData: [String: SessionState] = [:]
        for f in (try? fm.contentsOfDirectory(atPath: sessionsDir)) ?? [] where f.hasSuffix(".json") {
            let p = (sessionsDir as NSString).appendingPathComponent(f)
            guard let d = fm.contents(atPath: p),
                  let s = try? JSONDecoder().decode(SessionState.self, from: d) else { continue }
            if !s.alive { try? fm.removeItem(atPath: p); continue }   // tidy dead
            hookData[s.session_id] = s
        }

        // 2. Registry = every live interactive session (hooks not required).
        var loaded: [SessionState] = []
        var seen = Set<String>()
        for f in (try? fm.contentsOfDirectory(atPath: registryDir)) ?? [] where f.hasSuffix(".json") {
            let p = (registryDir as NSString).appendingPathComponent(f)
            guard let d = fm.contents(atPath: p),
                  let r = try? JSONDecoder().decode(RegistryEntry.self, from: d) else { continue }
            if (r.kind ?? "interactive") != "interactive" { continue }
            if !pidAlive(r.pid) { continue }
            // Trust hook data only when it's at least as fresh as the registry.
            // Otherwise the registry is more current (the session has moved on,
            // e.g. a permission prompt was answered) — use its live idle/busy
            // so stale statuses like needs_permission don't linger.
            let regTs = (r.updatedAt ?? 0) / 1000.0
            var s: SessionState
            if let h = hookData[r.sessionId], h.ts >= regTs - 2 {
                s = h
            } else {
                s = SessionState(registry: r)
            }
            s.title = r.name ?? s.title       // prefer Claude's friendly name
            s.cwd = r.cwd ?? s.cwd
            s.pid = r.pid
            loaded.append(s)
            seen.insert(r.sessionId)
        }

        // 3. Safety net: alive hook sessions missing from the registry.
        for (id, s) in hookData where !seen.contains(id) { loaded.append(s) }

        // Detect transitions worth an alert.
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

    /// The session that drives the hero pet's mood — priority order:
    /// needs-permission › your-turn › most-recently-active.
    var primary: SessionState? {
        if let perm = sessions.first(where: { $0.status == "needs_permission" }) { return perm }
        if let done = sessions.first(where: { $0.isHot }) { return done }
        return sessions.max { $0.ts < $1.ts }
    }

    var attentionCount: Int {
        sessions.filter { $0.status == "needs_permission" || $0.isHot }.count
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
        var eyes: [(Int, Int)] = []
        var ci = 0
        while ci + 1 < cols.count {
            eyes.append((cols[ci], cols[ci + 1]))
            ci += 2
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
    var expanded = false
    private var tick = 0

    // Hit-test rects, rebuilt each draw.
    private var heroRect = NSRect.zero
    private var tabRects: [(rect: NSRect, session: SessionState)] = []

    // Hover state.
    private var heroHot = false
    private var hoverTab = -1

    // Drag vs click tracking.
    private var mouseDownScreen = NSPoint.zero
    private var winOriginAtDown = NSPoint.zero
    private var dragged = false

    // Attention: debounce + per-session flash timer (in-app, no OS toast).
    private var lastNotified: [String: Double] = [:]
    private var flashUntil: [String: Double] = [:]
    private let flashDuration = 1.4

    override var isFlipped: Bool { true }

    // MARK: Draw

    override func draw(_ dirty: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: L.corner, yRadius: L.corner)
        NSColor(white: 0.11, alpha: 0.92).setFill(); bg.fill()
        NSColor(white: 1, alpha: 0.08).setStroke(); bg.lineWidth = 1; bg.stroke()

        tabRects.removeAll()
        guard let primary = store.primary else { return }
        if expanded { drawExpanded(primary) } else { drawCollapsed(primary) }
    }

    /// Collapsed: just the hero pet + a small count/alert badge.
    private func drawCollapsed(_ primary: SessionState) {
        heroRect = bounds
        drawGlow(in: bounds.insetBy(dx: 3, dy: 3), radius: L.corner - 2)
        let c = NSRect(x: (bounds.width - L.heroCat) / 2,
                       y: (bounds.height - L.heroCat) / 2,
                       width: L.heroCat, height: L.heroCat)
        Cat.draw(in: c, tint: rockyTint, expr: primary.expr, tick: tick)
        drawBadge(center: NSPoint(x: bounds.width - 11, y: 11))
    }

    /// Expanded: hero header (pet + summary + collapse chevron), then one
    /// clickable text tab per session.
    private func drawExpanded(_ primary: SessionState) {
        heroRect = NSRect(x: 0, y: 0, width: bounds.width, height: L.heroH)
        if heroHot {
            NSColor(white: 1, alpha: 0.05).setFill()
            NSBezierPath(roundedRect: heroRect.insetBy(dx: 3, dy: 3), xRadius: 8, yRadius: 8).fill()
        }
        drawGlow(in: heroRect.insetBy(dx: 3, dy: 3), radius: 8)

        let c = NSRect(x: L.pad, y: (L.heroH - L.heroCat) / 2,
                       width: L.heroCat, height: L.heroCat)
        Cat.draw(in: c, tint: rockyTint, expr: primary.expr, tick: tick)

        let tx = c.maxX + L.pad
        let tw = bounds.width - tx - 20
        let pn = NSMutableParagraphStyle(); pn.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: primary.displayName, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.white, .paragraphStyle: pn,
        ]).draw(in: NSRect(x: tx, y: 11, width: tw, height: 16))
        NSAttributedString(string: primary.statusLine, attributes: [
            .font: NSFont.systemFont(ofSize: 9.5),
            .foregroundColor: statusColor(primary.status), .paragraphStyle: pn,
        ]).draw(in: NSRect(x: tx, y: 28, width: tw, height: 13))

        NSAttributedString(string: "▴", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor(white: 0.7, alpha: 1),
        ]).draw(at: NSPoint(x: bounds.width - 17, y: 6))

        NSColor(white: 1, alpha: 0.07).setFill()
        NSBezierPath(rect: NSRect(x: L.pad, y: L.heroH - 0.5,
                                  width: bounds.width - 2 * L.pad, height: 1)).fill()

        var y = L.heroH
        for (i, s) in store.sessions.enumerated() {
            let r = NSRect(x: 0, y: y, width: bounds.width, height: L.tabH)
            drawTab(s, in: r, hover: i == hoverTab)
            tabRects.append((r, s))
            y += L.tabH
        }
    }

    private func drawTab(_ s: SessionState, in rect: NSRect, hover: Bool) {
        let now = Date().timeIntervalSince1970
        if let until = flashUntil[s.session_id], until > now {
            let fade = CGFloat((until - now) / flashDuration)
            let breathe = 0.55 + 0.45 * abs(sin(Double(tick) * 0.55))
            statusColor(s.status).withAlphaComponent(fade * 0.4 * CGFloat(breathe)).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 1.5), xRadius: 6, yRadius: 6).fill()
        }
        if hover {
            NSColor(white: 1, alpha: 0.06).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 1.5), xRadius: 6, yRadius: 6).fill()
        }
        let dot = NSRect(x: L.pad + 3, y: rect.midY - 4, width: 8, height: 8)
        statusColor(s.status).setFill(); NSBezierPath(ovalIn: dot).fill()

        let tx = dot.maxX + 8
        let tw = bounds.width - tx - L.pad
        let pn = NSMutableParagraphStyle(); pn.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: s.displayName, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white, .paragraphStyle: pn,
        ]).draw(in: NSRect(x: tx, y: rect.minY + 4, width: tw, height: 14))
        NSAttributedString(string: s.statusLine, attributes: [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor(white: 0.62, alpha: 1), .paragraphStyle: pn,
        ]).draw(in: NSRect(x: tx, y: rect.minY + 16, width: tw, height: 12))
    }

    /// Count/alert badge: red when a session needs you, green when one's
    /// waiting, neutral otherwise. Hidden for a single calm session.
    private func drawBadge(center: NSPoint) {
        let perm = store.sessions.contains { $0.status == "needs_permission" }
        let waiting = store.sessions.contains { $0.isHot }
        let count = store.sessions.count
        if count <= 1 && !perm && !waiting { return }
        let d: CGFloat = 16
        let r = NSRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
        let col = perm ? statusColor("needs_permission")
                : (waiting ? statusColor("waiting_for_input") : NSColor(white: 0.32, alpha: 0.95))
        col.setFill(); NSBezierPath(ovalIn: r).fill()
        let label = NSAttributedString(string: "\(count)", attributes: [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        let sz = label.size()
        label.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
    }

    /// Strongest active attention pulse, coloured by that session's state.
    private func drawGlow(in rect: NSRect, radius: CGFloat) {
        let now = Date().timeIntervalSince1970
        var best: (remaining: Double, status: String)?
        for (id, until) in flashUntil where until > now {
            let st = store.sessions.first { $0.session_id == id }?.status ?? "waiting_for_input"
            if best == nil || (until - now) > best!.remaining { best = (until - now, st) }
        }
        guard let hit = best else { return }
        let fade = CGFloat(hit.remaining / flashDuration)
        let breathe = 0.55 + 0.45 * abs(sin(Double(tick) * 0.55))
        statusColor(hit.status).withAlphaComponent(fade * 0.5 * CGFloat(breathe)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    // MARK: Sizing

    func resizeWindow(animated: Bool = false) {
        guard let win = window else { return }
        if store.sessions.isEmpty { win.orderOut(nil); return }
        if !win.isVisible { win.orderFront(nil) }
        let w: CGFloat = expanded ? L.width : L.collapsed
        let h: CGFloat = expanded
            ? L.heroH + CGFloat(store.sessions.count) * L.tabH + L.pad
            : L.collapsed
        var f = win.frame
        f.origin.y = f.maxY - h        // pin top edge
        f.origin.x = f.minX            // pin left edge (grows rightward)
        f.size = NSSize(width: w, height: h)
        if let vf = NSScreen.screens.first(where: { $0.frame.intersects(win.frame) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame {
            if f.maxX > vf.maxX { f.origin.x = vf.maxX - w }   // keep on-screen
            if f.minX < vf.minX { f.origin.x = vf.minX }
        }
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
        for s in notifications { alert(s) }
        resizeWindow()
        needsDisplay = true
    }

    /// In-app attention only: pulse + sound. No macOS banner/toast.
    private func alert(_ s: SessionState) {
        let now = Date().timeIntervalSince1970
        if let last = lastNotified[s.session_id], now - last < 8 { return }
        lastNotified[s.session_id] = now
        flashUntil[s.session_id] = now + flashDuration
        NSSound(named: s.status == "needs_permission" ? "Funk" : "Glass")?.play()
        window?.orderFront(nil)
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
        // Clicking the pet toggles the session tabs.
        if heroRect.contains(p) {
            expanded.toggle()
            resizeWindow(animated: true)
            needsDisplay = true
            return
        }
        // Clicking a tab jumps to that session's terminal.
        for entry in tabRects where entry.rect.contains(p) {
            store.markAttended(entry.session.session_id)
            Terminal.focus(entry.session)
            _ = store.refresh()
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
        let newHero = heroRect.contains(p)
        var newTab = -1
        for (i, entry) in tabRects.enumerated() where entry.rect.contains(p) { newTab = i }
        if newHero != heroHot || newTab != hoverTab {
            heroHot = newHero; hoverTab = newTab; needsDisplay = true
        }
    }

    override func mouseExited(with e: NSEvent) {
        if heroHot || hoverTab != -1 { heroHot = false; hoverTab = -1; needsDisplay = true }
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(heroRect, cursor: .pointingHand)
        for entry in tabRects { addCursorRect(entry.rect, cursor: .pointingHand) }
    }

    override func rightMouseDown(with e: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: expanded ? "Collapse" : "Expand",
                     action: #selector(toggleExpanded), keyEquivalent: "").target = self
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Rocky", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        NSMenu.popUpContextMenu(menu, with: e, for: self)
    }

    @objc private func toggleExpanded() { expanded.toggle(); resizeWindow(animated: true); needsDisplay = true }
    @objc private func toggleLogin() { LoginItem.toggle() }
}

// MARK: - Notifications & terminal focus (osascript)

enum Notify {
    /// Runs an AppleScript (used only to activate/raise terminals — not for
    /// user-facing notifications; Rocky's alerts are in-app + sound).
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
        // Warp exports WARP_FOCUS_URL (warp://session/<uuid>) in each session's
        // environment — opening it focuses that exact tab. Read it live from
        // the Claude process's env; works for every session, no permissions.
        if let pid = s.pid, let url = warpFocusURL(pid: pid) {
            openURL(url)
            return
        }
        // Non-Warp terminals.
        if s.term_app == "iTerm2" { focusITerm(tty: s.tty); return }
        if let app = s.term_app { Notify.run("tell application \"\(app)\" to activate") }
    }

    /// Read WARP_FOCUS_URL from a running process's environment via `ps eww`.
    private static func warpFocusURL(pid: Int) -> String? {
        let out = capture("/bin/ps", ["eww", "-p", "\(pid)"])
        for tok in out.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            if tok.hasPrefix("WARP_FOCUS_URL=") {
                let url = String(tok.dropFirst("WARP_FOCUS_URL=".count))
                return url.isEmpty ? nil : url
            }
        }
        return nil
    }

    private static func openURL(_ url: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.launchPath = "/usr/bin/open"
            p.arguments = [url]
            try? p.run()
        }
    }

    private static func capture(_ path: String, _ args: [String]) -> String {
        let p = Process(); p.launchPath = path; p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
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
        let start = NSRect(x: 0, y: 0, width: L.collapsed, height: L.collapsed)
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

        // Restore saved position, else top-right — but never off-screen.
        if let saved = UserDefaults.standard.string(forKey: "rocky.origin") {
            window.setFrameOrigin(NSPointFromString(saved))
        }
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) }
        if !onScreen, let vf = NSScreen.main?.visibleFrame {
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
