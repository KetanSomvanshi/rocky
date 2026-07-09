// Rocky screen saver — a full-screen view of your Claude Code sessions while
// the Mac is idle. Reuses the sprite and session store from RockyCore.swift.
//
// Built as a loadable bundle (Rocky.saver); NSPrincipalClass in Info.plist
// points at RockySaverView (kept stable via @objc). Session files are read via
// RockyCore's real-home paths, which work inside the saver's sandbox.
import ScreenSaver
import AppKit

@objc(RockySaverView)
final class RockySaverView: ScreenSaverView {
    private let store = SessionStore()
    private var tick = 0

    // All-clear celebration when the last busy/attention session goes calm.
    private var wasActive = false
    private var celebrateStart = -1000
    private var celebrating: Bool { tick - celebrateStart < 24 }

    override var isFlipped: Bool { true }

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 12.0
        _ = store.refresh()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 12.0
        _ = store.refresh()
    }

    override func animateOneFrame() {
        tick += 1
        if tick % 4 == 0 {                       // ~0.33s, matching the app
            _ = store.refresh()
            let active = store.sessions.contains(where: isActive)
            if wasActive && !active { celebrateStart = tick }
            wasActive = active
        }
        setNeedsDisplay(bounds)
    }

    // MARK: Draw

    override func draw(_ rect: NSRect) {
        let s = max(0.45, bounds.height / 1000)
        drawBackground()

        let sessions = store.sessions
        let expr: Expr = celebrating ? .happy : (store.primary?.expr ?? .sleeping)

        // Card geometry (centred).
        let clockH = 66 * s, catSize = 148 * s, rowH = 46 * s
        let listH = sessions.isEmpty ? 30 * s : (18 * s + CGFloat(sessions.count) * rowH)
        let contentH = clockH + catSize + 14 * s + 42 * s + 24 * s + listH
        let cardW = min(bounds.width * 0.62, 700 * s)
        let cardH = contentH + 64 * s
        let card = NSRect(x: (bounds.width - cardW) / 2, y: (bounds.height - cardH) / 2,
                          width: cardW, height: cardH)

        drawAttentionGlow(around: card, radius: 26 * s)
        drawCard(card, corner: 26 * s)

        var y = card.minY + 34 * s
        centeredText(timeString(), y: y, size: 52 * s, weight: .thin, color: NSColor(white: 0.92, alpha: 0.95))
        y += clockH

        let catRect = NSRect(x: bounds.midX - catSize / 2, y: y, width: catSize, height: catSize)
        Cat.draw(in: catRect, tint: rockyTint, expr: expr, tick: tick)
        if celebrating {
            drawSparkles(center: NSPoint(x: catRect.midX, y: catRect.midY),
                         radius: catSize / 2, d: tick - celebrateStart, scale: s)
        }
        y += catSize + 14 * s

        centeredText("Rocky", y: y, size: 34 * s, weight: .heavy, color: .white)
        y += 42 * s
        centeredText(summaryLine(sessions), y: y, size: 16 * s, weight: .medium,
                     color: NSColor(white: 0.6, alpha: 1))
        y += 24 * s + (sessions.isEmpty ? 0 : 18 * s)

        let colW = cardW - 130 * s
        let colX = bounds.midX - colW / 2
        for session in sessions {
            drawRow(session, x: colX, y: y, width: colW, scale: s)
            y += rowH
        }
    }

    /// A session that is doing something or waiting on the user (kept as an
    /// explicitly-typed helper so swiftc doesn't choke on a long `||` chain).
    private func isActive(_ s: SessionState) -> Bool {
        let st = s.status
        return st == "running_tool" || st == "processing" || st == "needs_permission" || s.isHot
    }

    // MARK: Pieces

    private func drawBackground() {
        NSGradient(colors: [
            NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.10, alpha: 1),
            NSColor(calibratedRed: 0.09, green: 0.08, blue: 0.16, alpha: 1),
            NSColor(calibratedRed: 0.13, green: 0.09, blue: 0.18, alpha: 1),
        ])?.draw(in: bounds, angle: -90)
    }

    /// A soft breathing halo behind the card when a session wants attention.
    /// Rendered as a blurred coloured shadow (the card is drawn over the solid
    /// fill next, leaving only the soft glow).
    private func drawAttentionGlow(around card: NSRect, radius: CGFloat) {
        let perm = store.sessions.contains { $0.status == "needs_permission" }
        let hot = store.sessions.contains { $0.isHot }
        guard perm || hot else { return }
        let color = statusColor(perm ? "needs_permission" : "waiting_for_input")
        let breathe = CGFloat(0.4 + 0.35 * abs(sin(Double(tick) * 0.14)))
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = color.withAlphaComponent(breathe)
        glow.shadowBlurRadius = 55
        glow.shadowOffset = .zero
        glow.set()
        color.withAlphaComponent(breathe).setFill()
        NSBezierPath(roundedRect: card.insetBy(dx: 8, dy: 8), xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCard(_ card: NSRect, corner: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 40
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.set()
        let path = NSBezierPath(roundedRect: card, xRadius: corner, yRadius: corner)
        NSColor(white: 0.10, alpha: 0.72).setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 1, alpha: 0.10).setStroke(); path.lineWidth = 1; path.stroke()
    }

    private func drawSparkles(center: NSPoint, radius: CGFloat, d: Int, scale: CGFloat) {
        guard d >= 0 && d < 24 else { return }
        let fade = 1 - CGFloat(d) / 24
        let green = NSColor(calibratedRed: 0.40, green: 0.86, blue: 0.52, alpha: 1)
        let gold = NSColor(calibratedRed: 0.98, green: 0.82, blue: 0.35, alpha: 1)
        for i in 0..<6 {
            let ang = Double(i) * 1.05 + Double(d) * 0.1
            let rr = radius * (0.9 + 0.5 * sin(Double(d) * 0.25 + Double(i) * 1.7))
            let px = center.x + CGFloat(cos(ang)) * rr
            let py = center.y + CGFloat(sin(ang)) * rr
            let sp = (3 + 2 * abs(sin(Double(d) * 0.4 + Double(i)))) * scale
            (i % 2 == 0 ? green : gold).withAlphaComponent(fade).setStroke()
            let star = NSBezierPath(); star.lineWidth = 2 * scale
            star.move(to: NSPoint(x: px - sp, y: py)); star.line(to: NSPoint(x: px + sp, y: py))
            star.move(to: NSPoint(x: px, y: py - sp)); star.line(to: NSPoint(x: px, y: py + sp))
            star.stroke()
        }
    }

    private func drawRow(_ s: SessionState, x: CGFloat, y: CGFloat, width: CGFloat, scale: CGFloat) {
        let dotD = 11 * scale
        statusColor(s.status).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: y + 8 * scale, width: dotD, height: dotD)).fill()
        let tx = x + dotD + 12 * scale
        let tw = width - (tx - x)
        text(s.displayName, x: tx, y: y, width: tw, size: 16 * scale, weight: .semibold, color: .white)
        text(s.statusLine, x: tx, y: y + 20 * scale, width: tw, size: 13 * scale, weight: .regular,
             color: statusColor(s.status).blended(withFraction: 0.35, of: .white) ?? .gray)
    }

    private func timeString() -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm"
        return f.string(from: Date())
    }

    private func summaryLine(_ sessions: [SessionState]) -> String {
        if sessions.isEmpty { return "no active Claude Code sessions — all quiet" }
        let perm = sessions.filter { $0.status == "needs_permission" }.count
        if perm > 0 { return "\(perm) session\(perm == 1 ? "" : "s") need\(perm == 1 ? "s" : "") your permission" }
        let n = sessions.count
        return "watching \(n) Claude Code session\(n == 1 ? "" : "s")"
    }

    private func centeredText(_ str: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let a = NSAttributedString(string: str, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        a.draw(at: NSPoint(x: bounds.midX - a.size().width / 2, y: y))
    }

    private func text(_ str: String, x: CGFloat, y: CGFloat, width: CGFloat,
                      size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: str, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color, .paragraphStyle: p,
        ]).draw(in: NSRect(x: x, y: y, width: width, height: size + 6))
    }
}
