// Rocky screen saver — "Rocky in Space".
//
// While the Mac is idle, Rocky floats in a little glass helmet in deep space
// and your Claude Code sessions orbit him as planets, colour-coded by status:
// a blocked session becomes a pulsing red sun that bathes the scene in warning
// light. Reuses the sprite and session store from RockyCore.swift.
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
    // The widget mirrors its skin choice to ~/.claude/rocky/skin (the saver's
    // own UserDefaults live in the sandbox container); re-read on the same
    // cadence as the session refresh.
    private var skin = Skin.mirrored

    // All-clear celebration when the last busy/attention session goes calm.
    private var wasActive = false
    private var celebrateStart = -1000
    private var celebrating: Bool { tick - celebrateStart < 24 }

    // Precomputed parallax starfield (stable for the life of the view).
    private var stars: [Star] = []
    private let layerSpeed: [Double] = [0.00010, 0.00022, 0.00044]

    override var isFlipped: Bool { true }

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 12.0
        generateStars()
        _ = store.refresh()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 12.0
        generateStars()
        _ = store.refresh()
    }

    override func animateOneFrame() {
        tick += 1
        if tick % 4 == 0 {                       // ~0.33s, matching the app
            _ = store.refresh()
            skin = Skin.mirrored
            let active = store.sessions.contains(where: isActive)
            if wasActive && !active { celebrateStart = tick }
            wasActive = active
        }
        setNeedsDisplay(bounds)
    }

    // MARK: Scene

    override func draw(_ rect: NSRect) {
        let s = max(0.5, bounds.height / 1000)
        let sessions = store.sessions
        let center = NSPoint(x: bounds.midX, y: bounds.midY + 12 * s)

        drawSpace()
        drawStars()
        drawShootingStar()

        let layouts = planetLayouts(sessions: sessions, center: center, s: s)
        drawBlockedAmbient(layouts)                          // red warning wash
        for l in layouts { drawOrbitPath(center: center, l: l) }
        for l in layouts where !l.front { drawBody(l, center: center, s: s) }  // behind
        drawRocky(center: center, s: s, sessions: sessions)
        for l in layouts where l.front { drawBody(l, center: center, s: s) }   // in front
        for l in layouts { drawPlanetLabel(l, s: s) }

        if celebrating {
            drawSparkles(center: center, radius: 150 * s, d: tick - celebrateStart, scale: s)
        }
        drawVignette()
        drawHUD(sessions: sessions, s: s)
    }

    /// A session doing something or waiting on the user (explicitly typed so
    /// swiftc doesn't choke on a long `||` chain).
    private func isActive(_ s: SessionState) -> Bool {
        let st = s.status
        return st == "running_tool" || st == "processing" || st == "needs_permission" || s.isHot
    }

    // MARK: Starfield + backdrop

    private struct Star {
        let x: Double; let y: Double; let size: CGFloat
        let phase: Double; let tw: Double; let layer: Int; let warm: Bool
    }

    /// Deterministic star positions (SplitMix64) so the field is stable across
    /// frames and only drifts by the parallax offset.
    private func generateStars() {
        var rng = SplitMix(seed: 0x9E3779B97F4A7C15)
        let counts = [150, 62, 26]
        for (layer, count) in counts.enumerated() {
            for _ in 0..<count {
                let size = CGFloat(0.6 + Double(layer) * 0.8 + rng.d() * 1.2)
                stars.append(Star(x: rng.d(), y: rng.d(), size: size,
                                  phase: rng.d() * 6.283, tw: 0.03 + rng.d() * 0.13,
                                  layer: layer, warm: rng.d() > 0.86))
            }
        }
    }

    private func drawSpace() {
        NSGradient(colors: [
            NSColor(calibratedRed: 0.02, green: 0.03, blue: 0.07, alpha: 1),
            NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.11, alpha: 1),
            NSColor(calibratedRed: 0.07, green: 0.05, blue: 0.14, alpha: 1),
        ])?.draw(in: bounds, angle: -90)
        drawNebula()
    }

    /// A few large, slowly drifting soft colour clouds for depth.
    private func drawNebula() {
        let blobs: [(dx: CGFloat, dy: CGFloat, r: CGFloat, c: NSColor, sp: Double)] = [
            (0.26, 0.30, 0.60, NSColor(calibratedRed: 0.42, green: 0.16, blue: 0.66, alpha: 1), 0.006),
            (0.74, 0.64, 0.52, NSColor(calibratedRed: 0.09, green: 0.36, blue: 0.55, alpha: 1), 0.008),
            (0.58, 0.18, 0.44, NSColor(calibratedRed: 0.70, green: 0.18, blue: 0.44, alpha: 1), 0.005),
        ]
        let minDim = min(bounds.width, bounds.height)
        for b in blobs {
            let cx = b.dx * bounds.width + CGFloat(sin(Double(tick) * b.sp)) * 40
            let cy = b.dy * bounds.height + CGFloat(cos(Double(tick) * b.sp * 0.8)) * 30
            let c = NSPoint(x: cx, y: cy)
            let g = NSGradient(colors: [b.c.withAlphaComponent(0.15), b.c.withAlphaComponent(0)])!
            g.draw(fromCenter: c, radius: 0, toCenter: c, radius: b.r * minDim, options: [])
        }
    }

    private func drawStars() {
        for st in stars {
            var fx = (st.x + Double(tick) * layerSpeed[st.layer]).truncatingRemainder(dividingBy: 1.0)
            if fx < 0 { fx += 1 }
            let px = CGFloat(fx) * bounds.width
            let py = CGFloat(st.y) * bounds.height
            let a = 0.32 + 0.5 * (0.5 + 0.5 * sin(Double(tick) * st.tw + st.phase))
            let col = st.warm ? NSColor(calibratedRed: 1, green: 0.86, blue: 0.7, alpha: 1)
                              : NSColor(white: 1, alpha: 1)
            col.withAlphaComponent(CGFloat(a)).setFill()
            let r = st.size
            NSBezierPath(ovalIn: NSRect(x: px - r / 2, y: py - r / 2, width: r, height: r)).fill()
            // A tiny cross-glint on the brightest near stars.
            if st.layer == 2 && a > 0.78 {
                col.withAlphaComponent(CGFloat(a) * 0.6).setStroke()
                let g = NSBezierPath(); g.lineWidth = 0.7
                let arm = r * 1.9
                g.move(to: NSPoint(x: px - arm, y: py)); g.line(to: NSPoint(x: px + arm, y: py))
                g.move(to: NSPoint(x: px, y: py - arm)); g.line(to: NSPoint(x: px, y: py + arm))
                g.stroke()
            }
        }
    }

    /// An occasional meteor streaking across the field (deterministic per
    /// ~22-second window, with a fading gradient tail).
    private func drawShootingStar() {
        let period = 260
        let local = tick % period
        guard local < 13 else { return }
        var rng = SplitMix(seed: UInt64(tick / period) &* 2654435761 &+ 1013904223)
        let sx = CGFloat(0.08 + rng.d() * 0.5) * bounds.width
        let sy = CGFloat(0.04 + rng.d() * 0.35) * bounds.height
        let ang = CGFloat(0.35 + rng.d() * 0.5)
        let len: CGFloat = 190 * max(0.6, bounds.height / 1000)
        let prog = CGFloat(local) / 13
        let fade = 1 - abs(prog - 0.5) * 2
        let hx = sx + cos(ang) * len * 2 * prog
        let hy = sy + sin(ang) * len * 2 * prog
        // Fading trail via a few segments of decreasing alpha.
        for k in 0..<6 {
            let f0 = CGFloat(k) / 6, f1 = CGFloat(k + 1) / 6
            let a = (1 - f0) * 0.85 * fade
            NSColor.white.withAlphaComponent(a).setStroke()
            let p = NSBezierPath(); p.lineWidth = 2 * (1 - f0)
            p.move(to: NSPoint(x: hx - cos(ang) * len * f1, y: hy - sin(ang) * len * f1))
            p.line(to: NSPoint(x: hx - cos(ang) * len * f0, y: hy - sin(ang) * len * f0))
            p.stroke()
        }
        NSColor.white.withAlphaComponent(fade).setFill()
        NSBezierPath(ovalIn: NSRect(x: hx - 2.5, y: hy - 2.5, width: 5, height: 5)).fill()
    }

    // MARK: Planets / suns

    private struct PlanetLayout {
        let session: SessionState
        let center: NSPoint
        let radius: CGFloat
        let orbitR: CGFloat
        let flatten: CGFloat
        let front: Bool
        let depth: CGFloat        // 0 = far side, 1 = near side
        let color: NSColor
        let isSun: Bool
    }

    private func planetLayouts(sessions: [SessionState], center: NSPoint, s: CGFloat) -> [PlanetLayout] {
        let n = sessions.count
        guard n > 0 else { return [] }
        let minDim = min(bounds.width, bounds.height)
        let baseR = minDim * 0.17
        let maxR = minDim * 0.42
        let flatten: CGFloat = 0.52
        var out: [PlanetLayout] = []
        for (i, sess) in sessions.enumerated() {
            let t = n == 1 ? 0.5 : Double(i) / Double(n - 1)
            let orbitR = baseR + (maxR - baseR) * CGFloat(t)
            let speed = 0.011 * Double(baseR / orbitR)              // inner orbits faster
            let angle = Double(i) * 2.399963 + Double(tick) * speed // golden-angle spread
            let sinA = sin(angle)
            let px = center.x + orbitR * CGFloat(cos(angle))
            let py = center.y + orbitR * flatten * CGFloat(sinA)
            let depth = CGFloat(0.5 + 0.5 * sinA)
            let isSun = sess.status == "needs_permission"
            let base: CGFloat = isSun ? 28 * s : 17 * s
            let radius = base * (0.72 + 0.42 * depth)
            out.append(PlanetLayout(session: sess, center: NSPoint(x: px, y: py),
                                    radius: radius, orbitR: orbitR, flatten: flatten,
                                    front: sinA > 0, depth: depth,
                                    color: statusColor(sess.status), isSun: isSun))
        }
        return out
    }

    private func drawOrbitPath(center: NSPoint, l: PlanetLayout) {
        let rect = NSRect(x: center.x - l.orbitR, y: center.y - l.orbitR * l.flatten,
                          width: l.orbitR * 2, height: l.orbitR * 2 * l.flatten)
        l.color.withAlphaComponent(0.09).setStroke()
        let p = NSBezierPath(ovalIn: rect); p.lineWidth = 1; p.stroke()
    }

    private func drawBody(_ l: PlanetLayout, center: NSPoint, s: CGFloat) {
        if l.isSun { drawSun(l, s: s); return }
        let dir = unit(from: l.center, to: center)                 // light comes from Rocky
        drawSphere(center: l.center, radius: l.radius, color: l.color,
                   lit: NSPoint(x: l.center.x + dir.x * l.radius * 0.55,
                                y: l.center.y + dir.y * l.radius * 0.55),
                   depth: l.depth)
        if hash(l.session.session_id) % 3 == 0 { drawRing(l) }
        if l.session.status == "running_tool" || l.session.status == "processing" {
            drawMoon(l, s: s)
        }
    }

    /// A lit sphere: radial gradient (highlight → body → shadow) clipped to the
    /// disc, dimmed on the far side of the orbit, with a soft rim light.
    private func drawSphere(center: NSPoint, radius: CGFloat, color: NSColor, lit: NSPoint, depth: CGFloat) {
        let dim = 0.5 + 0.5 * depth
        let hi = (color.blended(withFraction: 0.55, of: .white) ?? color).withAlphaComponent(dim)
        let mid = color.withAlphaComponent(dim)
        let lo = (color.blended(withFraction: 0.62, of: .black) ?? color).withAlphaComponent(dim)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                    width: radius * 2, height: radius * 2)).addClip()
        let g = NSGradient(colors: [hi, mid, lo])!
        g.draw(fromCenter: lit, radius: 0, toCenter: center, radius: radius * 1.3, options: [])
        NSGraphicsContext.restoreGraphicsState()
        (color.blended(withFraction: 0.4, of: .white) ?? color).withAlphaComponent(0.35 * dim).setStroke()
        let rim = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                              width: radius * 2, height: radius * 2))
        rim.lineWidth = max(1, radius * 0.07); rim.stroke()
    }

    private func drawRing(_ l: PlanetLayout) {
        let rx = l.radius * 2.1, ry = l.radius * 0.62
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: l.center.x, yBy: l.center.y)
        t.rotate(byDegrees: 20)
        t.translateX(by: -l.center.x, yBy: -l.center.y)
        t.concat()
        (l.color.blended(withFraction: 0.45, of: .white) ?? l.color)
            .withAlphaComponent(0.5 * (0.5 + 0.5 * l.depth)).setStroke()
        let p = NSBezierPath(ovalIn: NSRect(x: l.center.x - rx, y: l.center.y - ry,
                                            width: rx * 2, height: ry * 2))
        p.lineWidth = max(1.5, l.radius * 0.16); p.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawMoon(_ l: PlanetLayout, s: CGFloat) {
        let a = Double(tick) * 0.085 + Double(hash(l.session.session_id) % 100)
        let mr = l.radius * 1.7
        let mx = l.center.x + CGFloat(cos(a)) * mr
        let my = l.center.y + CGFloat(sin(a)) * mr * 0.55
        NSColor(white: 0.85, alpha: 0.9).setFill()
        let d = 5 * s
        NSBezierPath(ovalIn: NSRect(x: mx - d / 2, y: my - d / 2, width: d, height: d)).fill()
    }

    /// A blocked session: a pulsing sun with a corona, rotating rays and a hot
    /// core — the "something needs you" beacon.
    private func drawSun(_ l: PlanetLayout, s: CGFloat) {
        let c = l.center
        let R = l.radius * CGFloat(1 + 0.12 * sin(Double(tick) * 0.18))
        let red = statusColor("needs_permission")
        let orange = NSColor(calibratedRed: 1, green: 0.55, blue: 0.25, alpha: 1)
        // corona
        let g = NSGradient(colors: [red.withAlphaComponent(0.85), orange.withAlphaComponent(0.5),
                                    red.withAlphaComponent(0)])!
        g.draw(fromCenter: c, radius: 0, toCenter: c, radius: R * 2.7, options: [])
        // rays
        red.withAlphaComponent(0.55).setStroke()
        let rays = 12
        for k in 0..<rays {
            let a = Double(k) / Double(rays) * 6.283 + Double(tick) * 0.02
            let inner = R * 1.2
            let outer = R * CGFloat(1.75 + 0.28 * sin(Double(tick) * 0.2 + Double(k)))
            let p = NSBezierPath(); p.lineWidth = 1.6 * s
            p.move(to: NSPoint(x: c.x + CGFloat(cos(a)) * inner, y: c.y + CGFloat(sin(a)) * inner))
            p.line(to: NSPoint(x: c.x + CGFloat(cos(a)) * outer, y: c.y + CGFloat(sin(a)) * outer))
            p.stroke()
        }
        // hot core
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: NSRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)).addClip()
        let core = NSGradient(colors: [NSColor(calibratedRed: 1, green: 0.96, blue: 0.82, alpha: 1),
                                       orange, red])!
        core.draw(fromCenter: NSPoint(x: c.x - R * 0.2, y: c.y - R * 0.2), radius: 0,
                  toCenter: c, radius: R * 1.2, options: [])
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A large soft red wash centred on each blocked sun — the scene itself
    /// glows with warning when a session is waiting on you.
    private func drawBlockedAmbient(_ layouts: [PlanetLayout]) {
        let breathe = CGFloat(0.10 + 0.06 * sin(Double(tick) * 0.14))
        let red = statusColor("needs_permission")
        let R = min(bounds.width, bounds.height) * 0.65
        for l in layouts where l.isSun {
            let g = NSGradient(colors: [red.withAlphaComponent(breathe), red.withAlphaComponent(0)])!
            g.draw(fromCenter: l.center, radius: 0, toCenter: l.center, radius: R, options: [])
        }
    }

    private func drawPlanetLabel(_ l: PlanetLayout, s: CGFloat) {
        let alpha = 0.55 + 0.45 * l.depth
        let y0 = l.center.y + l.radius + 7 * s
        centeredTextAt(oneLine(l.session.displayName, max: 22), cx: l.center.x, y: y0, size: 13 * s,
                       weight: .semibold, color: NSColor(white: 0.95, alpha: alpha))
        var sub = l.session.statusLine
        if l.session.waitingSeconds > 0 { sub += " · " + l.session.elapsedLabel() }
        centeredTextAt(oneLine(sub, max: 42), cx: l.center.x, y: y0 + 15 * s, size: 10.5 * s,
                       weight: .regular, color: l.color.withAlphaComponent(0.8 * alpha))
    }

    /// Collapse whitespace/newlines to a single line and truncate — a tool's
    /// `detail` (e.g. a full Bash command) can be long and multi-line, and this
    /// label must stay one tidy caption under the planet.
    private func oneLine(_ str: String, max: Int) -> String {
        let squeezed = str.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\t" || $0 == " " })
            .joined(separator: " ")
        return squeezed.count <= max ? squeezed : String(squeezed.prefix(max - 1)) + "…"
    }

    // MARK: Rocky the astronaut

    private func drawRocky(center: NSPoint, s: CGFloat, sessions: [SessionState]) {
        // Slow zero-g drift (a gentle Lissajous).
        let c = NSPoint(x: center.x + CGFloat(sin(Double(tick) * 0.028)) * 7 * s,
                        y: center.y + CGFloat(sin(Double(tick) * 0.02 + 1)) * 9 * s)
        let catSize = 150 * s
        let catRect = NSRect(x: c.x - catSize / 2, y: c.y - catSize / 2, width: catSize, height: catSize)
        let expr: Expr = celebrating ? .happy : (store.primary?.expr ?? .sleeping)
        let busy = sessions.contains { $0.status == "running_tool" || $0.status == "processing" }

        if busy { drawJet(at: NSPoint(x: c.x, y: c.y + catSize * 0.44), s: s) }   // jetpack flame
        Cat.draw(in: catRect, tint: rockyTint, expr: expr, tick: tick, skin: skin)
        drawChestPanel(at: NSPoint(x: c.x, y: c.y + catSize * 0.15), s: s, sessions: sessions)
        drawHelmet(center: c, radius: catSize * 0.6, s: s)
    }

    /// A flickering jetpack plume beneath Rocky while any session is working.
    private func drawJet(at p: NSPoint, s: CGFloat) {
        let flick = CGFloat(0.7 + 0.3 * sin(Double(tick) * 0.9))
        let h = 34 * s * flick, w = 14 * s
        let g = NSGradient(colors: [NSColor(calibratedRed: 0.7, green: 0.9, blue: 1, alpha: 0.9),
                                    NSColor(calibratedRed: 1, green: 0.7, blue: 0.3, alpha: 0.7),
                                    NSColor(calibratedRed: 1, green: 0.4, blue: 0.2, alpha: 0)])!
        NSGraphicsContext.saveGraphicsState()
        let flame = NSBezierPath()
        flame.move(to: NSPoint(x: p.x - w / 2, y: p.y))
        flame.line(to: NSPoint(x: p.x + w / 2, y: p.y))
        flame.line(to: NSPoint(x: p.x, y: p.y + h))
        flame.close()
        flame.addClip()
        g.draw(fromCenter: p, radius: 0, toCenter: NSPoint(x: p.x, y: p.y + h), radius: h, options: [])
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A little chest control panel with a status LED per session.
    private func drawChestPanel(at p: NSPoint, s: CGFloat, sessions: [SessionState]) {
        let leds = min(sessions.count, 4)
        guard leds > 0 else { return }
        let ledD = 4.5 * s, gap = 3 * s
        let panelW = CGFloat(leds) * ledD + CGFloat(leds - 1) * gap + 8 * s
        let panelH = ledD + 7 * s
        let panel = NSRect(x: p.x - panelW / 2, y: p.y - panelH / 2, width: panelW, height: panelH)
        NSColor(white: 0.12, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: panel, xRadius: 3 * s, yRadius: 3 * s).fill()
        NSColor(white: 1, alpha: 0.12).setStroke()
        NSBezierPath(roundedRect: panel, xRadius: 3 * s, yRadius: 3 * s).stroke()
        var lx = panel.minX + 4 * s
        for sess in sessions.prefix(4) {
            let blink = (sess.status == "needs_permission") ? CGFloat(0.4 + 0.6 * abs(sin(Double(tick) * 0.3))) : 1
            statusColor(sess.status).withAlphaComponent(blink).setFill()
            NSBezierPath(ovalIn: NSRect(x: lx, y: panel.midY - ledD / 2, width: ledD, height: ledD)).fill()
            lx += ledD + gap
        }
    }

    /// The glass helmet dome: faint glass fill, a bright cyan rim + outer glow,
    /// a specular arc, and a blinking antenna.
    private func drawHelmet(center c: NSPoint, radius r: CGFloat, s: CGFloat) {
        let rect = NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        let cyan = NSColor(calibratedRed: 0.55, green: 0.85, blue: 1.0, alpha: 1)
        // glass
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: rect).addClip()
        let glass = NSGradient(colors: [NSColor(white: 1, alpha: 0.12), NSColor(white: 0.6, alpha: 0.015)])!
        glass.draw(fromCenter: NSPoint(x: c.x - r * 0.4, y: c.y - r * 0.4), radius: 0,
                   toCenter: c, radius: r * 1.4, options: [])
        NSGraphicsContext.restoreGraphicsState()
        // outer glow + rim
        cyan.withAlphaComponent(0.14).setStroke()
        let glow = NSBezierPath(ovalIn: rect); glow.lineWidth = 7 * s; glow.stroke()
        cyan.withAlphaComponent(0.5).setStroke()
        let rim = NSBezierPath(ovalIn: rect); rim.lineWidth = 2.4 * s; rim.stroke()
        // specular highlight arc (upper-left)
        NSColor(white: 1, alpha: 0.55).setStroke()
        let hi = NSBezierPath()
        hi.appendArc(withCenter: c, radius: r * 0.82, startAngle: 118, endAngle: 168)
        hi.lineWidth = 2 * s; hi.stroke()
        // antenna with a blinking tip
        let topY = c.y - r
        cyan.withAlphaComponent(0.7).setStroke()
        let ant = NSBezierPath(); ant.lineWidth = 1.6 * s
        ant.move(to: NSPoint(x: c.x + r * 0.5, y: topY + r * 0.13))
        let tip = NSPoint(x: c.x + r * 0.62, y: topY - r * 0.16)
        ant.line(to: tip); ant.stroke()
        let on = (tick / 6) % 2 == 0
        (on ? NSColor(calibratedRed: 1, green: 0.4, blue: 0.4, alpha: 1)
            : NSColor(calibratedRed: 0.4, green: 0.9, blue: 0.5, alpha: 1)).setFill()
        let bd = 5 * s
        NSBezierPath(ovalIn: NSRect(x: tip.x - bd / 2, y: tip.y - bd / 2, width: bd, height: bd)).fill()
    }

    // MARK: HUD + effects

    private func drawVignette() {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let g = NSGradient(colors: [NSColor.clear, NSColor.black.withAlphaComponent(0.34)])!
        g.draw(fromCenter: c, radius: min(bounds.width, bounds.height) * 0.36,
               toCenter: c, radius: max(bounds.width, bounds.height) * 0.72, options: [])
    }

    private func drawHUD(sessions: [SessionState], s: CGFloat) {
        centeredTextAt(timeString(), cx: bounds.midX, y: 42 * s, size: 60 * s,
                       weight: .thin, color: NSColor(white: 0.95, alpha: 0.92))
        centeredTextAt("R O C K Y   ·   M I S S I O N   C O N T R O L", cx: bounds.midX, y: 42 * s + 70 * s,
                       size: 12 * s, weight: .semibold,
                       color: NSColor(calibratedRed: 0.55, green: 0.85, blue: 1, alpha: 0.5))
        centeredTextAt(summaryLine(sessions), cx: bounds.midX, y: bounds.height - 48 * s,
                       size: 15 * s, weight: .medium, color: NSColor(white: 0.62, alpha: 0.9))
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

    // MARK: Helpers

    private func timeString() -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm"
        return f.string(from: Date())
    }

    private func summaryLine(_ sessions: [SessionState]) -> String {
        if sessions.isEmpty { return "no active Claude Code sessions — all quiet in orbit" }
        let perm = sessions.filter { $0.status == "needs_permission" }.count
        if perm > 0 {
            return "\(perm) session\(perm == 1 ? "" : "s") need\(perm == 1 ? "s" : "") your permission"
        }
        let n = sessions.count
        return "\(n) session\(n == 1 ? "" : "s") in orbit"
    }

    private func centeredTextAt(_ str: String, cx: CGFloat, y: CGFloat,
                                size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let a = NSAttributedString(string: str, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        a.draw(at: NSPoint(x: cx - a.size().width / 2, y: y))
    }

    /// Unit vector from `a` toward `b` (zero-safe).
    private func unit(from a: NSPoint, to b: NSPoint) -> (x: CGFloat, y: CGFloat) {
        let dx = b.x - a.x, dy = b.y - a.y
        let m = max(0.0001, sqrt(dx * dx + dy * dy))
        return (dx / m, dy / m)
    }

    private func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return h
    }

    /// SplitMix64 — a tiny deterministic PRNG for stable star/meteor placement.
    private struct SplitMix {
        var s: UInt64
        init(seed: UInt64) { s = seed }
        mutating func next() -> UInt64 {
            s = s &+ 0x9E3779B97F4A7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func d() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
    }
}
