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
    // Scaled by the "Pet Size" preference; pad/corner stay fixed so the
    // panel's chrome doesn't get chunky at Large or cramped at Small.
    static var scale: CGFloat { PetSize.current.scale }
    static var width: CGFloat { 216 * scale }       // expanded window width
    static var collapsed: CGFloat { 68 * scale }    // collapsed = compact pet square
    static var heroH: CGFloat { 58 * scale }        // hero (pet) header height when expanded
    static var heroCat: CGFloat { 46 * scale }      // the one animated hero cat
    static var tabH: CGFloat { 31 * scale }         // per-session tab row
    static let pad: CGFloat = 8
    static let corner: CGFloat = 13
}

// MARK: - Peek bubble (self-drawn, since native NSView tooltips don't fire
// for Rocky's window — see the note by `PetView.peekPanel`)

final class PeekBubbleView: NSView {
    var text: String = "" { didSet { needsDisplay = true } }

    static let maxWidth: CGFloat = 260
    static let padding: CGFloat = 10
    private static var attrs: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byWordWrapping
        return [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.white, .paragraphStyle: p]
    }

    /// Panel size needed to show `text` wrapped at `maxWidth`.
    static func size(for text: String) -> NSSize {
        let bound = NSSize(width: maxWidth - padding * 2, height: .greatestFiniteMagnitude)
        let rect = (text as NSString).boundingRect(with: bound,
                     options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs)
        return NSSize(width: ceil(rect.width) + padding * 2, height: ceil(rect.height) + padding * 2)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        NSColor(white: 0.08, alpha: 0.97).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        NSColor(white: 1, alpha: 0.12).setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).stroke()
        let r = bounds.insetBy(dx: Self.padding, dy: Self.padding)
        (text as NSString).draw(in: r, withAttributes: Self.attrs)
    }
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
    private var firstPoll = true
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

    // Richer peek: native NSView tooltips never fire for this window (a
    // borderless, non-activating, .statusBar-level panel in an .accessory
    // app) — confirmed empirically: mouseMoved reliably tracks real hover,
    // but stringForToolTip is never called. So the full-text peek on hover is
    // a small self-drawn auxiliary panel instead; see `updatePeek`.
    private var peekPanel: NSPanel?
    private var peekView: PeekBubbleView?

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
        guard let primary = store.primary else { peekPanel?.orderOut(nil); return }

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
        updatePeek(primary)
    }

    /// The "richer peek": while hovering the hero or a tab that currently
    /// wants attention, shows its full pending question in a small
    /// self-drawn auxiliary panel next to Rocky (native tooltips don't fire
    /// for this window — see the note on `peekPanel` above).
    private func updatePeek(_ primary: SessionState) {
        var target: (text: String, rect: NSRect)?
        if heroHot, primary.status == "needs_permission" || primary.isHot {
            target = (primary.fullPeek, heroRect)
        } else if tabRects.indices.contains(hoverTab) {
            let s = tabRects[hoverTab].session
            if s.status == "needs_permission" || s.isHot {
                target = (s.fullPeek, tabRects[hoverTab].rect)
            }
        }
        guard let target, !target.text.isEmpty, let win = window else {
            peekPanel?.orderOut(nil)
            return
        }
        showPeek(text: target.text, anchor: target.rect, in: win)
    }

    private func showPeek(text: String, anchor: NSRect, in win: NSWindow) {
        let panel: NSPanel
        let view: PeekBubbleView
        if let p = peekPanel, let v = peekView {
            panel = p; view = v
        } else {
            let v = PeekBubbleView(frame: .zero)
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .popUpMenu
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.becomesKeyOnlyIfNeeded = true
            p.hidesOnDeactivate = false   // NSPanel defaults this to true, which
            // hides it whenever the app isn't frontmost — and this .accessory,
            // nonactivating-panel app never truly becomes frontmost, so the
            // peek would otherwise never actually be visible.
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.contentView = v
            panel = p; peekPanel = p; peekView = v
            view = v
        }
        view.text = text
        let size = PeekBubbleView.size(for: text)

        // Anchor beside Rocky, vertically centred on the hovered row —
        // prefer the left side (Rocky usually sits top-right), fall back to
        // the right if that would run off-screen, and clamp vertically.
        let screenAnchor = win.convertToScreen(convert(anchor, to: nil))
        let vf = NSScreen.screens.first(where: { $0.frame.intersects(win.frame) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? win.frame
        let gap: CGFloat = 8
        var x = win.frame.minX - gap - size.width
        if x < vf.minX { x = win.frame.maxX + gap }
        let y = max(vf.minY, min(screenAnchor.midY - size.height / 2, vf.maxY - size.height))
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        // orderFront(_:) is unreliable for this .accessory, nonactivating-panel
        // app (confirmed empirically: the panel reported isVisible but never
        // actually drew) — orderFrontRegardless() is Apple's documented way to
        // show a window without requiring the owning app to be active.
        panel.orderFrontRegardless()
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
        } else if let esc = Escalation.seconds, s.waitingSeconds > esc {
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
        let name = MutedSessions.isMuted(s.session_id) ? "🔕 \(s.displayName)" : s.displayName
        NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white, .paragraphStyle: pn,
        ]).draw(in: NSRect(x: tx, y: rect.minY + 4, width: nameW, height: 14))
        // Second line: when a session wants you, show the transcript "story"
        // (what it's asking); otherwise the tool/status line. On hover, if the
        // click can't land on the exact tab, say so instead of overpromising.
        let attention = s.status == "needs_permission" || s.isHot
        var line2 = (attention ? (s.story ?? s.statusLine) : s.statusLine)
        if hover && !s.deepFocus { line2 = s.focusHint }
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
        let now = Date().timeIntervalSince1970
        if firstPoll {
            // SessionStore.refresh() already suppresses `notifications` for
            // anything seen on this very first call, but the escalation timer
            // below counts from `lastNotified`, not from a transition — seed
            // it too, or anything already stuck past the threshold at launch
            // would immediately re-nudge as if it had just newly gone stuck.
            for s in store.sessions { lastNotified[s.session_id] = now }
            firstPoll = false
        } else {
            for s in notifications { alert(s) }
        }
        // Stuck escalation: re-nudge a session that has needed permission for
        // a while (tunable via the right-click menu) so a long-blocked
        // session doesn't get forgotten.
        if let esc = Escalation.seconds {
            for s in store.sessions where s.status == "needs_permission" && s.waitingSeconds > esc {
                if now - (lastNotified[s.session_id] ?? 0) > esc { alert(s) }
            }
        }
        resizeWindow()
        needsDisplay = true
    }

    /// In-app attention only: pulse + sound. No macOS banner/toast.
    private func alert(_ s: SessionState) {
        let now = Date().timeIntervalSince1970
        if let last = lastNotified[s.session_id], now - last < 8 { return }
        // Debounce state updates regardless of mute/quiet — otherwise a muted
        // stuck session would hammer this every poll instead of settling.
        lastNotified[s.session_id] = now
        guard !MutedSessions.isMuted(s.session_id), !QuietGate.isActive else { return }
        flashUntil[s.session_id] = now + flashDuration
        rippleStart = tick
        rippleColor = statusColor(s.status)
        if AlertStyle.current.playsSound {
            NSSound(named: s.status == "needs_permission" ? "Funk" : "Glass")?.play()
        }
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
        let p = convert(e.locationInWindow, from: nil)
        // Right-clicking a specific session row gets its own tiny menu
        // (currently just per-session mute) instead of the app-wide one.
        if let entry = tabRects.first(where: { $0.rect.contains(p) }) {
            showTabMenu(for: entry.session, at: e)
            return
        }
        showAppMenu(at: e)
    }

    private func showTabMenu(for s: SessionState, at e: NSEvent) {
        let menu = NSMenu()
        let muted = MutedSessions.isMuted(s.session_id)
        let item = NSMenuItem(title: muted ? "Unmute \(s.displayName)" : "Mute \(s.displayName)",
                               action: #selector(toggleSessionMute(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = s.session_id
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: e, for: self)
    }

    private func showAppMenu(at e: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: expanded ? "Collapse" : "Expand",
                     action: #selector(toggleExpanded), keyEquivalent: "").target = self
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        // Alert style — the "sound on/off" knob, framed as a single choice so
        // it can't disagree with itself.
        let alertSub = NSMenu()
        for style: AlertStyle in [.rippleAndSound, .rippleOnly] {
            let item = NSMenuItem(title: style.label, action: #selector(setAlertStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = (AlertStyle.current == style) ? .on : .off
            alertSub.addItem(item)
        }
        menu.addItem(submenu(alertSub, title: "Alert Style"))

        // Pet size.
        let sizeSub = NSMenu()
        for size: PetSize in [.small, .medium, .large] {
            let item = NSMenuItem(title: size.label, action: #selector(setPetSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size.rawValue
            item.state = (PetSize.current == size) ? .on : .off
            sizeSub.addItem(item)
        }
        menu.addItem(submenu(sizeSub, title: "Pet Size"))

        // Re-nudge interval.
        let escSub = NSMenu()
        for (label, secs) in Escalation.presets {
            let item = NSMenuItem(title: label, action: #selector(setEscalation(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = secs
            item.state = (Escalation.seconds == secs) ? .on : .off
            escSub.addItem(item)
        }
        menu.addItem(submenu(escSub, title: "Re-nudge Interval"))

        // Quiet hours.
        let quietSub = NSMenu()
        for (i, preset) in QuietHours.presets.enumerated() {
            let item = NSMenuItem(title: preset.label, action: #selector(setQuietHours(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = i
            item.state = QuietHours.sameWindow(QuietHours.window, preset.window) ? .on : .off
            quietSub.addItem(item)
        }
        menu.addItem(submenu(quietSub, title: "Quiet Hours"))

        // Respect macOS Focus — a screen-sharing engineer's instant mute.
        let focus = NSMenuItem(title: "Respect macOS Focus", action: #selector(toggleFocusSync), keyEquivalent: "")
        focus.target = self
        focus.state = FocusSync.enabled ? .on : .off
        menu.addItem(focus)

        // Health rows (no action → shown greyed, informational only).
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: SelfCheck.hooksLabel, action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: store.registryHealth.label, action: nil, keyEquivalent: ""))
        if FocusSync.enabled {
            menu.addItem(NSMenuItem(title: FocusSync.state().menuLabel, action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Rocky", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        NSMenu.popUpContextMenu(menu, with: e, for: self)
    }

    private func submenu(_ sub: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    @objc private func toggleExpanded() { expanded.toggle(); resizeWindow(animated: true); needsDisplay = true }
    @objc private func toggleLogin() { LoginItem.toggle() }
    @objc private func toggleSessionMute(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        MutedSessions.toggle(id)
        needsDisplay = true
    }
    @objc private func setAlertStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int, let style = AlertStyle(rawValue: raw) else { return }
        AlertStyle.current = style
    }
    @objc private func setPetSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int, let size = PetSize(rawValue: raw) else { return }
        PetSize.current = size
        resizeWindow(animated: true)
        needsDisplay = true
    }
    @objc private func setEscalation(_ sender: NSMenuItem) {
        Escalation.seconds = sender.representedObject as? Double
    }
    @objc private func setQuietHours(_ sender: NSMenuItem) {
        guard let idx = sender.representedObject as? Int, QuietHours.presets.indices.contains(idx) else { return }
        QuietHours.window = QuietHours.presets[idx].window
    }
    @objc private func toggleFocusSync() { FocusSync.enabled.toggle() }
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

/// How far a click can take the user for a given session — used both to act
/// (Terminal.focus) and to be honest about it in the UI (the hover hint).
extension SessionState {
    /// Can a click land on the exact tab/window/pane, or only raise the app?
    var deepFocus: Bool {
        if tmux != nil && tmux_pane != nil { return true }
        if warp_url != nil { return true }
        if kitty_socket != nil && kitty_window != nil { return true }
        switch term_app {
        case "Warp": return true                    // ps-env deep link at click time
        case "iTerm2", "Terminal": return tty != nil
        case "Code", "Cursor": return !(cwd ?? "").isEmpty
        default: return false
        }
    }

    /// Honest hover hint when the click can only raise the app.
    var focusHint: String {
        guard let app = term_app else { return "terminal unknown — click may not focus" }
        return "click focuses \(app) only"
    }
}

enum Terminal {
    static func focus(_ s: SessionState) {
        // Inside tmux: reveal the exact window/pane first, then raise the
        // hosting terminal like any other session.
        if s.tmux != nil { focusTmux(s) }
        // Warp deep link (warp://session/<uuid>): hook-captured env, with a
        // live `ps eww` fallback for sessions that never fired a hook.
        if let url = s.warp_url ?? s.pid.flatMap(warpFocusURL) {
            openURL(url)
            return
        }
        if let sock = s.kitty_socket, let win = s.kitty_window {
            focusKitty(socket: sock, window: win)
            return
        }
        switch s.term_app {
        case "iTerm2": focusITerm(tty: s.tty)
        case "Terminal": focusTerminalApp(tty: s.tty)
        case "Code": openWorkspace(app: "Visual Studio Code", cwd: s.cwd)
        case "Cursor": openWorkspace(app: "Cursor", cwd: s.cwd)
        case let app?:
            // Ghostty, Alacritty, kitty-without-remote-control…: no scripting
            // surface for tab focus — raise the app (the tab hint says so).
            Notify.run("tell application \"\(app)\" to activate")
        default: break
        }
    }

    /// First existing executable among candidate install locations (GUI apps
    /// don't inherit a shell PATH).
    private static func firstExecutable(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Select the session's tmux window + pane, and point a client showing a
    /// different session at ours. Best-effort; the host app is raised after.
    private static func focusTmux(_ s: SessionState) {
        guard let env = s.tmux, let pane = s.tmux_pane,
              let sock = env.split(separator: ",").first.map(String.init),
              let tmux = firstExecutable(["/opt/homebrew/bin/tmux",
                                          "/usr/local/bin/tmux", "/usr/bin/tmux"])
        else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = capture(tmux, ["-S", sock, "select-window", "-t", pane])
            _ = capture(tmux, ["-S", sock, "select-pane", "-t", pane])
            let sess = capture(tmux, ["-S", sock, "display-message", "-p", "-t", pane,
                                      "#{session_name}"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sess.isEmpty else { return }
            for line in capture(tmux, ["-S", sock, "list-clients",
                                       "-F", "#{client_tty} #{session_name}"])
                .split(separator: "\n") {
                let p = line.split(separator: " ", maxSplits: 1)
                guard p.count == 2, String(p[1]) != sess else { continue }
                _ = capture(tmux, ["-S", sock, "switch-client", "-c", String(p[0]), "-t", sess])
            }
        }
    }

    /// kitty remote control: focus the exact window over the session's socket,
    /// then raise the app (the socket call alone doesn't activate kitty).
    private static func focusKitty(socket: String, window: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            if let kitten = firstExecutable(["/Applications/kitty.app/Contents/MacOS/kitten",
                                             "/opt/homebrew/bin/kitten", "/usr/local/bin/kitten"]) {
                _ = capture(kitten, ["@", "--to", socket, "focus-window", "--match", "id:\(window)"])
            }
            Notify.run("tell application \"kitty\" to activate")
        }
    }

    /// VS Code / Cursor: `open -a <app> <folder>` focuses the existing window
    /// showing that folder (the apps are single-instance and route the open
    /// event to the matching workspace window).
    private static func openWorkspace(app: String, cwd: String?) {
        guard let cwd = cwd, !cwd.isEmpty else {
            Notify.run("tell application \"\(app)\" to activate")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.launchPath = "/usr/bin/open"
            p.arguments = ["-a", app, cwd]
            try? p.run()
        }
    }

    // Terminal.app is scriptable like iTerm2 — select the exact tab by tty.
    private static func focusTerminalApp(tty: String?) {
        guard let tty = tty else {
            Notify.run("tell application \"Terminal\" to activate"); return
        }
        Notify.run("""
        tell application "Terminal"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(tty)" then
                set selected of t to true
                set index of w to 1
                return
              end if
            end repeat
          end repeat
        end tell
        """)
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

// MARK: - Startup self-check

enum SelfCheck {
    /// Is rocky-hook.py wired into Claude Code's hook config? Checks the file
    /// rocky-setup writes (~/.claude/settings.json) plus settings.local.json
    /// for hand-wired setups. Cheap enough to re-run every menu open.
    static var hooksWired: Bool {
        for file in ["settings.json", "settings.local.json"] {
            let path = rockyHome + "/.claude/" + file
            guard let d = FileManager.default.contents(atPath: path),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let hooks = obj["hooks"] as? [String: Any] else { continue }
            for groups in hooks.values {
                for g in (groups as? [[String: Any]]) ?? [] {
                    for h in (g["hooks"] as? [[String: Any]]) ?? []
                    where (h["command"] as? String)?.contains("rocky-hook.py") == true {
                        return true
                    }
                }
            }
        }
        return false
    }

    static var hooksLabel: String {
        hooksWired ? "✓ Hooks wired" : "⚠ Hooks not wired — run rocky-setup"
    }
}

// MARK: - Escalation (tunable re-nudge interval)

/// How long a `needs_permission` session waits before Rocky re-nudges (sound
/// + ripple) and the tab starts a persistent stuck-pulse. `nil` = never
/// re-nudge (the roadmap's "make escalation tunable"); default matches the
/// original hardcoded 120s so upgrading changes nothing until you touch it.
enum Escalation {
    private static let key = "rocky.escalationSeconds"
    static var seconds: Double? {
        get {
            guard let v = UserDefaults.standard.object(forKey: key) as? Double else { return 120 }
            return v < 0 ? nil : v
        }
        set { UserDefaults.standard.set(newValue ?? -1, forKey: key) }
    }
    static let presets: [(label: String, seconds: Double?)] = [
        ("Re-nudge every 1 min", 60), ("Re-nudge every 2 min", 120),
        ("Re-nudge every 5 min", 300), ("Re-nudge every 10 min", 600),
        ("Never re-nudge", nil),
    ]
}

// MARK: - Preferences (minimal layer — no config file, no settings window;
// every knob lives in the right-click menu and persists in UserDefaults,
// exactly like the window position already does)

/// Sound on/off, reframed as one choice instead of a toggle that could
/// disagree with a separate "alert style" setting.
enum AlertStyle: Int {
    case rippleAndSound = 0
    case rippleOnly = 1

    var label: String {
        switch self {
        case .rippleAndSound: return "Ripple + Sound"
        case .rippleOnly: return "Ripple Only (no sound)"
        }
    }
    var playsSound: Bool { self == .rippleAndSound }

    private static let key = "rocky.alertStyle"
    static var current: AlertStyle {
        get { AlertStyle(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .rippleAndSound }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// Scales the whole floating panel (window + cat + tabs); see `L.scale`.
enum PetSize: Int {
    case small = 0, medium = 1, large = 2

    var scale: CGFloat {
        switch self {
        case .small: return 0.8
        case .medium: return 1.0
        case .large: return 1.25
        }
    }
    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    private static let key = "rocky.petSize"
    static var current: PetSize {
        get { PetSize(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// Per-session "stop pinging me about this one" — the session stays visible
/// (tab, status dot, stuck-pulse) but never triggers sound/ripple/window-raise.
enum MutedSessions {
    private static let key = "rocky.mutedSessions"
    private static var ids: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: key) }
    }
    static func isMuted(_ id: String) -> Bool { ids.contains(id) }
    static func toggle(_ id: String) {
        var s = ids
        if !s.insert(id).inserted { s.remove(id) }
        ids = s
    }
}

/// A daily quiet window (presets only — no time picker, matching the
/// "no settings window" constraint). Wraps past midnight when start > end.
enum QuietHours {
    private static let startKey = "rocky.quietStartHour"
    private static let endKey = "rocky.quietEndHour"

    static var window: (start: Int, end: Int)? {
        get {
            let s = UserDefaults.standard.integer(forKey: startKey)
            let e = UserDefaults.standard.integer(forKey: endKey)
            return s == e ? nil : (s, e)   // start==end (incl. unset 0,0) means off
        }
        set {
            UserDefaults.standard.set(newValue?.start ?? 0, forKey: startKey)
            UserDefaults.standard.set(newValue?.end ?? 0, forKey: endKey)
        }
    }

    static var isActiveNow: Bool {
        guard let w = window else { return false }
        let hour = Calendar.current.component(.hour, from: Date())
        return w.start < w.end
            ? (hour >= w.start && hour < w.end)
            : (hour >= w.start || hour < w.end)   // wraps past midnight
    }

    static func sameWindow(_ a: (start: Int, end: Int)?, _ b: (start: Int, end: Int)?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return x.start == y.start && x.end == y.end
        default: return false
        }
    }

    static let presets: [(label: String, window: (start: Int, end: Int)?)] = [
        ("Off", nil),
        ("10 PM – 8 AM", (22, 8)),
        ("11 PM – 7 AM", (23, 7)),
        ("9 PM – 9 AM", (21, 9)),
    ]
}

/// Best-effort sync with macOS Focus/Do Not Disturb — "a screen-sharing
/// engineer must be able to mute the cat instantly" without touching Rocky.
/// The assertions store this reads is an undocumented, unstable Apple format
/// gated behind Full Disk Access; this never blocks alerts on failure (an
/// unreadable or reshaped file degrades to `.unavailable`, treated the same
/// as "Focus is off"), and the menu says so plainly instead of pretending it
/// works when it can't.
enum FocusSync {
    private static let key = "rocky.respectFocus"
    static var enabled: Bool {
        get { (UserDefaults.standard.object(forKey: key) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    enum State {
        case active, inactive, unavailable

        var menuLabel: String {
            switch self {
            case .active: return "🌙 macOS Focus is on — alerts silenced"
            case .inactive: return "🌙 Focus sync active (Focus is currently off)"
            case .unavailable: return "⚠ Focus sync needs Full Disk Access for Rocky"
            }
        }
    }

    static func state() -> State {
        let path = rockyHome + "/Library/DoNotDisturb/DB/Assertions.json"
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return .unavailable }
        // The assertions schema has shifted across macOS releases and isn't
        // documented, so this walks generously for anything that looks like
        // an open-ended (no end date) assertion record, rather than binding
        // to one exact shape the way RegistryAdapter can for Claude's format.
        func hasOpenAssertion(_ any: Any) -> Bool {
            if let dict = any as? [String: Any] {
                let hasStart = dict.keys.contains { $0.lowercased().contains("startdate") }
                let hasEnd = dict.keys.contains { $0.lowercased().contains("enddate") }
                if hasStart && !hasEnd { return true }
                return dict.values.contains(where: hasOpenAssertion)
            }
            if let arr = any as? [Any] { return arr.contains(where: hasOpenAssertion) }
            return false
        }
        return hasOpenAssertion(obj) ? .active : .inactive
    }
}

/// Combines every "go quiet" preference into the one gate `alert()` checks.
enum QuietGate {
    static var isActive: Bool {
        if QuietHours.isActiveNow { return true }
        if FocusSync.enabled && FocusSync.state() == .active { return true }
        return false
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
        // startTimers ran the first poll synchronously, so registry health is
        // fresh; one startup line answers "is the plumbing connected?".
        NSLog("Rocky self-check: %@ · %@", SelfCheck.hooksLabel, pet.store.registryHealth.label)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
