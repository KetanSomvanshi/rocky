// Rocky — a floating pixel-cat desktop pet for Claude Code.
//
// An always-on-top widget shows one animated cat per active Claude Code
// session (driven by rocky-hook.py writing JSON into ~/.claude/rocky/). Click a
// cat to jump to its terminal; the panel collapses to just the session that
// wants attention. Shared types (sprite, session store) live in RockyCore.swift.
//
// Build: swiftc -O RockyCore.swift main.swift -o Rocky

import AppKit
import Foundation

// MARK: - Layout constants

enum L {
    static let width: CGFloat = 216       // expanded window width
    static let collapsed: CGFloat = 68    // collapsed = compact pet square
    static let heroH: CGFloat = 58        // hero (pet) header height when expanded
    static let heroCat: CGFloat = 46      // the one animated hero cat
    static let tabH: CGFloat = 31         // per-session tab row
    static let pad: CGFloat = 8
    static let corner: CGFloat = 13
}

// MARK: - The pet view

final class PetView: NSView {
    let store = SessionStore()
    var expanded = ProcessInfo.processInfo.environment["ROCKY_EXPAND"] == "1" {
        didSet { if expanded && !oldValue { expandStart = tick } }
    }
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

    // Wake-stretch: when the hero pet leaves the sleeping state, play a brief
    // stretch that settles over ~1s.
    private var lastHeroExpr: Expr = .idle
    private var wakeStart = -1000
    private var wake: Double {
        let dt = tick - wakeStart
        return (dt >= 0 && dt < 11) ? (1 - Double(dt) / 11) : 0
    }

    // A small scale-pop whenever the hero's mood changes — the pet "reacts".
    private var exprChangeStart = -1000
    private var exprPop: Double {
        let dt = tick - exprChangeStart
        return (dt >= 0 && dt < 6) ? (1 - Double(dt) / 6) : 0
    }

    // Staggered reveal of session tabs when the panel expands.
    private var expandStart = -1000

    // Expanding ripple ring on a fresh alert (colour = that session's status).
    private var rippleStart = -1000
    private var rippleColor = NSColor.white

    // Badge pop when the session count changes.
    private var lastBadgeCount = -1
    private var badgePopStart = -1000

    // All-clear celebration: a brief happy bounce + sparkles when the last
    // busy/attention session goes calm.
    private var wasActive = false
    private var celebrateStart = -1000
    private var celebrating: Bool { tick - celebrateStart < 18 }

    override var isFlipped: Bool { true }

    // MARK: Draw

    override func draw(_ dirty: NSRect) {
        // A thin dark scrim over the vibrancy blur keeps text/sprite legible
        // while letting the blurred backdrop show through. A soft top-edge
        // highlight + hairline border give the panel a rounded, lit edge.
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                              xRadius: L.corner, yRadius: L.corner)
        NSColor(white: 0.10, alpha: 0.55).setFill(); bg.fill()
        NSColor(white: 1, alpha: 0.14).setStroke(); bg.lineWidth = 1; bg.stroke()

        tabRects.removeAll()
        guard let primary = store.primary else { return }

        // All-clear: everything just went calm after being busy → celebrate.
        let active = store.sessions.contains(where: isActive)
        if wasActive && !active { celebrateStart = tick }
        wasActive = active

        // Hero mood change: a small reaction pop, plus a wake-stretch on waking.
        // (The celebration bounce is driven separately, below.)
        let e = celebrating ? Expr.happy : primary.expr
        if e != lastHeroExpr {
            if lastHeroExpr == .sleeping && e != .sleeping { wakeStart = tick }
            exprChangeStart = tick
            lastHeroExpr = e
        }

        if expanded { drawExpanded(primary) } else { drawCollapsed(primary) }
    }

    /// Collapsed: just the hero pet + a small count/alert badge.
    private func drawCollapsed(_ primary: SessionState) {
        heroRect = bounds
        drawGlow(in: bounds.insetBy(dx: 3, dy: 3), radius: L.corner - 2)
        let c = NSRect(x: (bounds.width - L.heroCat) / 2,
                       y: (bounds.height - L.heroCat) / 2,
                       width: L.heroCat, height: L.heroCat)
        Cat.draw(in: c, tint: rockyTint, expr: celebrating ? .happy : primary.expr, tick: tick,
                 wake: wake, scale: 1 + exprPop * 0.12)
        drawRipple(center: NSPoint(x: bounds.midX, y: bounds.midY), baseRadius: L.heroCat / 2)
        if celebrating { drawSparkles(center: NSPoint(x: c.midX, y: c.midY), radius: L.heroCat / 2) }
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
        Cat.draw(in: c, tint: rockyTint, expr: celebrating ? .happy : primary.expr, tick: tick,
                 wake: wake, scale: 1 + exprPop * 0.12)
        drawRipple(center: NSPoint(x: c.midX, y: c.midY), baseRadius: L.heroCat / 2)
        if celebrating { drawSparkles(center: NSPoint(x: c.midX, y: c.midY), radius: L.heroCat / 2) }

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
            // Staggered reveal: each row eases in (fade + slide up) shortly after
            // the one above it when the panel first opens.
            let reveal = tabReveal(index: i)
            if reveal < 1, let cg = NSGraphicsContext.current?.cgContext {
                NSGraphicsContext.saveGraphicsState()
                cg.setAlpha(CGFloat(reveal))
                cg.translateBy(x: 0, y: CGFloat(1 - reveal) * 8)   // starts lower, rises (flipped)
                drawTab(s, in: r, hover: i == hoverTab)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                drawTab(s, in: r, hover: i == hoverTab)
            }
            tabRects.append((r, s))
            y += L.tabH
        }
    }

    /// 0→1 ease-out reveal for tab `index`, staggered after the panel opens.
    private func tabReveal(index: Int) -> Double {
        let elapsed = Double(tick - expandStart - index * 2)   // 2-tick stagger per row
        let p = max(0, min(1, elapsed / 7))                    // ~0.6s per row
        return 1 - (1 - p) * (1 - p)                           // ease-out
    }

    private func drawTab(_ s: SessionState, in rect: NSRect, hover: Bool) {
        let now = Date().timeIntervalSince1970
        let sc = statusColor(s.status)
        if let until = flashUntil[s.session_id], until > now {
            let fade = CGFloat((until - now) / flashDuration)
            let breathe = 0.55 + 0.45 * abs(sin(Double(tick) * 0.55))
            sc.withAlphaComponent(fade * 0.4 * CGFloat(breathe)).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 1.5), xRadius: 6, yRadius: 6).fill()
        } else if s.waitingSeconds > 120 {
            // Stuck: a persistent gentle pulse until it's attended to.
            let breathe = 0.4 + 0.35 * abs(sin(Double(tick) * 0.3))
            sc.withAlphaComponent(0.16 * CGFloat(breathe)).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 1.5), xRadius: 6, yRadius: 6).fill()
        }
        if hover {
            NSColor(white: 1, alpha: 0.06).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 1.5), xRadius: 6, yRadius: 6).fill()
        }
        let dot = NSRect(x: L.pad + 3, y: rect.midY - 4, width: 8, height: 8)
        sc.setFill(); NSBezierPath(ovalIn: dot).fill()

        var rightEdge = bounds.width - L.pad
        // Activity sparkline (right) when there's recent tool activity.
        let buckets = s.activityBuckets()
        if buckets.contains(where: { $0 > 0 }) {
            let sw: CGFloat = 30, sh: CGFloat = 13
            let sr = NSRect(x: rightEdge - sw, y: rect.midY - sh / 2, width: sw, height: sh)
            drawSparkline(buckets, in: sr, color: sc)
            rightEdge = sr.minX - 6
        }

        let tx = dot.maxX + 8
        let pn = NSMutableParagraphStyle(); pn.lineBreakMode = .byTruncatingTail
        // Elapsed chip (top-right) while a session waits on you.
        var nameW = rightEdge - tx
        if s.waitingSeconds > 0 {
            let chip = NSAttributedString(string: s.elapsedLabel(now), attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: sc])
            let cw = chip.size().width
            chip.draw(at: NSPoint(x: rightEdge - cw, y: rect.minY + 5))
            nameW -= cw + 6
        }
        NSAttributedString(string: s.displayName, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white, .paragraphStyle: pn,
        ]).draw(in: NSRect(x: tx, y: rect.minY + 4, width: nameW, height: 14))
        // Second line: when a session wants you, show the transcript "story"
        // (what it's asking); otherwise the tool/status line.
        let attention = s.status == "needs_permission" || s.isHot
        let line2 = (attention ? (s.story ?? s.statusLine) : s.statusLine)
        NSAttributedString(string: line2, attributes: [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor(white: 0.62, alpha: 1), .paragraphStyle: pn,
        ]).draw(in: NSRect(x: tx, y: rect.minY + 16, width: rightEdge - tx, height: 12))
    }

    /// Tiny bar sparkline of recent activity (newest on the right).
    private func drawSparkline(_ buckets: [Int], in rect: NSRect, color: NSColor) {
        let maxV = CGFloat(max(1, buckets.max() ?? 1))
        let bw = rect.width / CGFloat(buckets.count)
        for (i, v) in buckets.enumerated() {
            let h = v == 0 ? 1.5 : max(2, rect.height * CGFloat(v) / maxV)
            let bar = NSRect(x: rect.minX + CGFloat(i) * bw, y: rect.maxY - h,
                             width: max(1, bw - 1), height: h)
            color.withAlphaComponent(v > 0 ? 0.85 : 0.2).setFill()
            NSBezierPath(rect: bar).fill()
        }
    }

    /// Count/alert badge: red when a session needs you, green when one's
    /// waiting, neutral otherwise. Hidden for a single calm session.
    private func drawBadge(center: NSPoint) {
        let perm = store.sessions.contains { $0.status == "needs_permission" }
        let waiting = store.sessions.contains { $0.isHot }
        let count = store.sessions.count
        if count <= 1 && !perm && !waiting { return }
        // Pop the badge whenever the count changes (or it first appears).
        if count != lastBadgeCount { badgePopStart = tick; lastBadgeCount = count }
        let pd = tick - badgePopStart
        let pop = (pd >= 0 && pd < 8) ? (1 - Double(pd) / 8) : 0
        let d: CGFloat = 16 * (1 + CGFloat(pop) * 0.5)
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

    /// One-shot ring that expands outward from the pet the instant an alert
    /// fires — a sharper attention cue than the steady glow.
    private func drawRipple(center: NSPoint, baseRadius: CGFloat) {
        let d = tick - rippleStart
        guard d >= 0 && d < 12 else { return }
        let p = CGFloat(d) / 12
        let radius = baseRadius + p * 16
        rippleColor.withAlphaComponent((1 - p) * 0.7).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                               width: radius * 2, height: radius * 2))
        ring.lineWidth = 0.5 + (1 - p) * 2
        ring.stroke()
    }

    /// Twinkling sparkles orbiting the pet during the all-clear celebration.
    private func drawSparkles(center: NSPoint, radius: CGFloat) {
        let d = tick - celebrateStart
        guard d >= 0 && d < 18 else { return }
        let fade = 1 - CGFloat(d) / 18
        let green = NSColor(calibratedRed: 0.40, green: 0.86, blue: 0.52, alpha: 1)
        let gold = NSColor(calibratedRed: 0.98, green: 0.82, blue: 0.35, alpha: 1)
        for i in 0..<5 {
            let ang = Double(i) * 1.257 + Double(d) * 0.12
            let rr = radius * (0.85 + 0.45 * sin(Double(d) * 0.3 + Double(i) * 1.7))
            let px = center.x + CGFloat(cos(ang)) * rr
            let py = center.y + CGFloat(sin(ang)) * rr
            let s = CGFloat(2 + 1.6 * abs(sin(Double(d) * 0.45 + Double(i))))
            (i % 2 == 0 ? green : gold).withAlphaComponent(fade).setStroke()
            let star = NSBezierPath(); star.lineWidth = 1.4
            star.move(to: NSPoint(x: px - s, y: py)); star.line(to: NSPoint(x: px + s, y: py))
            star.move(to: NSPoint(x: px, y: py - s)); star.line(to: NSPoint(x: px, y: py + s))
            star.stroke()
        }
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

    /// Busy or waiting on the user (typed helper to keep swiftc fast).
    private func isActive(_ s: SessionState) -> Bool {
        let st = s.status
        return st == "running_tool" || st == "processing" || st == "needs_permission" || s.isHot
    }

    private func poll() {
        let notifications = store.refresh()
        for s in notifications { alert(s) }
        // Stuck escalation: re-nudge a session that has needed permission for a
        // while (every ~2 min) so a long-blocked session doesn't get forgotten.
        let now = Date().timeIntervalSince1970
        for s in store.sessions where s.status == "needs_permission" && s.waitingSeconds > 120 {
            if now - (lastNotified[s.session_id] ?? 0) > 120 { alert(s) }
        }
        resizeWindow()
        needsDisplay = true
    }

    /// In-app attention only: pulse + sound. No macOS banner/toast.
    private func alert(_ s: SessionState) {
        let now = Date().timeIntervalSince1970
        if let last = lastNotified[s.session_id], now - last < 8 { return }
        lastNotified[s.session_id] = now
        flashUntil[s.session_id] = now + flashDuration
        rippleStart = tick
        rippleColor = statusColor(s.status)
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

        // Container holds a genuine background-blur layer with the pet drawn on
        // top, so Rocky picks up the desktop/window behind it (native widget
        // look) instead of a flat dark rectangle.
        let container = NSView(frame: start)
        container.autoresizesSubviews = true

        let blur = NSVisualEffectView(frame: start)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = L.corner
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]
        container.addSubview(blur)

        pet = PetView(frame: start)
        pet.autoresizingMask = [.width, .height]
        container.addSubview(pet)

        window.contentView = container

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
