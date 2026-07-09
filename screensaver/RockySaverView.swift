// Rocky screen saver — a full-screen view of your Claude Code sessions while
// the Mac is idle. Reuses the sprite and session store from RockyCore.swift.
//
// Built as a loadable bundle (Rocky.saver); NSPrincipalClass in Info.plist
// points at RockySaverView (kept stable via @objc).
import ScreenSaver
import AppKit

@objc(RockySaverView)
final class RockySaverView: ScreenSaverView {
    private let store = SessionStore()
    private var tick = 0

    override var isFlipped: Bool { true }   // top-left origin, matching Cat.draw

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
        if tick % 4 == 0 { _ = store.refresh() }   // ~0.33s, matching the app
        setNeedsDisplay(bounds)
    }

    // MARK: Draw

    override func draw(_ rect: NSRect) {
        let s = max(0.45, bounds.height / 1000)     // scale to the display
        drawBackground()

        let sessions = store.sessions
        let primary = store.primary
        let expr: Expr = primary?.expr ?? .sleeping

        // Vertically centre the whole composition.
        let catSize = 168 * s
        let titleGap = 18 * s
        let rowH = 46 * s
        let listH = CGFloat(sessions.count) * rowH
        let blockH = catSize + titleGap + 74 * s + (sessions.isEmpty ? 0 : 26 * s + listH)
        var y = (bounds.height - blockH) / 2

        // Hero cat.
        let catRect = NSRect(x: bounds.midX - catSize / 2, y: y, width: catSize, height: catSize)
        Cat.draw(in: catRect, tint: rockyTint, expr: expr, tick: tick)
        y += catSize + titleGap

        // Wordmark + summary line.
        centeredText("Rocky", y: y, size: 40 * s, weight: .heavy, color: .white)
        y += 48 * s
        let summary: String
        if sessions.isEmpty {
            summary = "no active Claude Code sessions — all quiet"
        } else {
            let n = sessions.count
            summary = "watching \(n) Claude Code session\(n == 1 ? "" : "s")"
        }
        centeredText(summary, y: y, size: 17 * s, weight: .medium, color: NSColor(white: 0.62, alpha: 1))
        y += 26 * s + 26 * s

        // Session rows, centred as a column.
        let colW = min(bounds.width * 0.6, 620 * s)
        let colX = bounds.midX - colW / 2
        for session in sessions {
            drawRow(session, x: colX, y: y, width: colW, scale: s)
            y += rowH
        }
    }

    // MARK: Pieces

    private func drawBackground() {
        let grad = NSGradient(colors: [
            NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.10, alpha: 1),
            NSColor(calibratedRed: 0.09, green: 0.08, blue: 0.16, alpha: 1),
            NSColor(calibratedRed: 0.13, green: 0.09, blue: 0.18, alpha: 1),
        ])
        grad?.draw(in: bounds, angle: -90)
    }

    private func drawRow(_ s: SessionState, x: CGFloat, y: CGFloat, width: CGFloat, scale: CGFloat) {
        let dotD = 11 * scale
        let dot = NSRect(x: x, y: y + 8 * scale, width: dotD, height: dotD)
        statusColor(s.status).setFill()
        NSBezierPath(ovalIn: dot).fill()

        let tx = dot.maxX + 12 * scale
        let tw = width - (tx - x)
        text(s.displayName, x: tx, y: y, width: tw, size: 16 * scale, weight: .semibold, color: .white)
        text(s.statusLine, x: tx, y: y + 20 * scale, width: tw, size: 13 * scale, weight: .regular,
             color: NSColor(white: 0.58, alpha: 1))
    }

    private func centeredText(_ str: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
        ]
        let a = NSAttributedString(string: str, attributes: attrs)
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
