// Rocky core — types shared by the widget app (main.swift) and the screen
// saver (screensaver/RockySaverView.swift): the session model, the
// registry⨯hook session store, the pixel-cat sprite, and shared colours.
// No app/bootstrap code lives here; it is compiled into both targets.

import AppKit
import Foundation
import Darwin

/// The user's real home directory, read from the password database rather than
/// `$HOME`/tilde expansion. Both resolve identically for the widget app, but
/// inside the sandboxed screen saver `$HOME` is redirected to the saver's
/// container — so tilde expansion points at an empty directory while the real
/// `~/.claude` paths (which the sandbox still permits reading) are missed.
let rockyHome: String = {
    if let override = ProcessInfo.processInfo.environment["ROCKY_HOME"], !override.isEmpty {
        return override                                   // testing / non-standard setups
    }
    if let pw = getpwuid(getuid()) { return String(cString: pw.pointee.pw_dir) }
    return NSHomeDirectory()
}()

// Rocky's own hook-written state (rich, real-time), and Claude Code's live
// session registry (authoritative list of every running session).
let sessionsDir = rockyHome + "/.claude/rocky/sessions"
let registryDir = rockyHome + "/.claude/sessions"

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
    // Deep-focus handles the hook captures from the session's environment.
    var tmux: String?         // TMUX (socket,server-pid,session) when inside tmux
    var tmux_pane: String?    // TMUX_PANE (%N)
    var warp_url: String?     // WARP_FOCUS_URL deep link
    var kitty_socket: String? // KITTY_LISTEN_ON (remote control socket)
    var kitty_window: String? // KITTY_WINDOW_ID
    var message: String?
    var ts: Double
    var attended_at: Double?
    var title: String?   // resolved from the transcript, not from disk
    var summary: String? // last assistant line from the transcript ("the story")
    var recent: [Double]?// recent event timestamps, for the activity sparkline
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

    /// The transcript "story" — what the session last said — if we have one.
    var story: String? {
        guard let s = summary, !s.isEmpty else { return nil }
        return s
    }

    /// Compact "time in current state" label, e.g. "8s", "4m", "2h".
    func elapsedLabel(_ now: Double = Date().timeIntervalSince1970) -> String {
        let dt = max(0, now - ts)
        if dt < 60 { return "\(Int(dt))s" }
        if dt < 3600 { return "\(Int(dt / 60))m" }
        return "\(Int(dt / 3600))h"
    }

    /// How long the session has been waiting on the user (0 if it isn't).
    var waitingSeconds: Double {
        guard status == "needs_permission" || isHot else { return 0 }
        return max(0, Date().timeIntervalSince1970 - ts)
    }

    /// Recent activity bucketed into `bins` counts over the last `window`
    /// seconds (newest on the right) — drives the sparkline.
    func activityBuckets(bins: Int = 14, window: Double = 150) -> [Int] {
        var b = [Int](repeating: 0, count: bins)
        guard let r = recent, !r.isEmpty else { return b }
        let now = Date().timeIntervalSince1970
        for t in r {
            let age = now - t
            if age < 0 || age > window { continue }
            let idx = bins - 1 - Int((age / window) * Double(bins))
            if idx >= 0 && idx < bins { b[idx] += 1 }
        }
        return b
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
        tmux = nil; tmux_pane = nil; warp_url = nil
        kitty_socket = nil; kitty_window = nil
        ts = (r.updatedAt ?? 0) / 1000.0
        attended_at = nil
        title = r.name
        summary = nil
        recent = nil
    }
}

func pidAlive(_ pid: Int) -> Bool {
    guard pid > 0 else { return false }
    return kill(pid_t(pid), 0) == 0 || errno == EPERM
}

// MARK: - Registry adapter (versioned decode)

/// The registry format is an undocumented Claude Code internal, so decoding
/// goes through a versioned adapter rather than a bare Codable call: the
/// strict current schema (v1) first, then a tolerant decode that survives key
/// renames and number/string type drift. When upstream ships a schema that
/// needs real translation, it gets its own numbered step here — the rest of
/// the app never sees anything but `RegistryEntry`.
enum RegistryAdapter {
    static func decode(_ data: Data) -> RegistryEntry? {
        // v1 — the schema Claude Code writes today.
        if let r = try? JSONDecoder().decode(RegistryEntry.self, from: data) { return r }
        return tolerant(data)
    }

    /// Best-effort decode of any JSON object that still smells like a session
    /// entry: accepts snake_case/renamed keys and numbers-as-strings. Returns
    /// nil only when no session id or pid can be found at all.
    private static func tolerant(_ data: Data) -> RegistryEntry? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        func str(_ keys: [String]) -> String? {
            for k in keys { if let v = obj[k] as? String, !v.isEmpty { return v } }
            return nil
        }
        func num(_ keys: [String]) -> Double? {
            for k in keys {
                if let v = obj[k] as? NSNumber { return v.doubleValue }
                if let v = obj[k] as? String, let d = Double(v) { return d }
            }
            return nil
        }
        guard let sid = str(["sessionId", "session_id", "id", "uuid"]),
              let pid = num(["pid", "processId", "process_id"]) else { return nil }
        var updated = num(["updatedAt", "updated_at", "statusUpdatedAt", "ts", "timestamp"])
        if let u = updated, u < 1e12 { updated = u * 1000 }   // epoch-seconds → ms
        return RegistryEntry(pid: Int(pid), sessionId: sid,
                             cwd: str(["cwd", "workingDirectory", "working_dir"]),
                             name: str(["name", "title"]),
                             status: str(["status", "state"]),
                             kind: str(["kind", "type"]),
                             updatedAt: updated)
    }
}

/// Outcome of the last registry read — the self-check surfaced in the
/// right-click menu, and the trigger for log-and-degrade when the
/// (undocumented) schema shifts underneath us.
enum RegistryHealth {
    case ok(sessions: Int)
    case empty                                // readable, just no sessions
    case unreadable                           // directory missing or unlistable
    case degraded(decoded: Int, failed: Int)  // some entries no longer parse

    var label: String {
        switch self {
        case .ok(let n): return "✓ Registry OK · \(n) session\(n == 1 ? "" : "s")"
        case .empty: return "✓ Registry OK · no sessions"
        case .unreadable: return "⚠ Registry unreadable — hooks-only mode"
        case .degraded(let d, let f):
            return "⚠ Registry format changed (\(f) of \(d + f) entries) — hooks fill the gap"
        }
    }

    /// Coarse bucket so health is logged on transitions, not every poll.
    var logKey: String {
        switch self {
        case .ok: return "ok"
        case .empty: return "empty"
        case .unreadable: return "unreadable"
        case .degraded: return "degraded"
        }
    }
}

// MARK: - Session store

final class SessionStore {
    private(set) var sessions: [SessionState] = []
    private(set) var registryHealth: RegistryHealth = .empty
    private var lastStatus: [String: String] = [:]
    private var lastHealthKey = ""
    private var seeded = false

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
        var decoded = 0, failed = 0
        let registryFiles = try? fm.contentsOfDirectory(atPath: registryDir)
        for f in registryFiles ?? [] where f.hasSuffix(".json") {
            let p = (registryDir as NSString).appendingPathComponent(f)
            guard let d = fm.contents(atPath: p) else { continue }   // raced with removal
            guard let r = RegistryAdapter.decode(d) else { failed += 1; continue }
            decoded += 1
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

        // Registry self-check: when the schema shifts or the directory goes
        // away, log once and degrade — the hook safety net below keeps every
        // hook-reporting session visible (hooks-only mode, not an empty pet).
        let health: RegistryHealth =
            registryFiles == nil ? .unreadable
            : failed > 0 ? .degraded(decoded: decoded, failed: failed)
            : decoded == 0 ? .empty
            : .ok(sessions: decoded)
        if health.logKey != lastHealthKey {
            NSLog("Rocky registry self-check: %@", health.label)
            lastHealthKey = health.logKey
        }
        registryHealth = health

        // 3. Safety net: alive hook sessions missing from the registry.
        for (id, s) in hookData where !seen.contains(id) { loaded.append(s) }

        // Detect transitions worth an alert. On the very first refresh (Rocky
        // just launched or relaunched), every session's status is "new" to
        // us — silently learn it instead of dinging for old news the user
        // may already have seen or handled before Rocky was watching again.
        var toNotify: [SessionState] = []
        if seeded {
            for s in loaded {
                let prev = lastStatus[s.session_id]
                if s.status != prev {
                    // "The ball is in your court": arriving from active work,
                    // or from a permission prompt that just got resolved one
                    // way or another (approved/denied at the terminal, not
                    // through Rocky) — either way, a fresh question counts.
                    let cameFromBusy = prev == "running_tool" || prev == "processing"
                        || prev == "compacting" || prev == "needs_permission"
                    if s.status == "needs_permission" ||
                       (s.status == "waiting_for_input" && (cameFromBusy || prev == nil)) {
                        toNotify.append(s)
                    }
                }
                lastStatus[s.session_id] = s.status
            }
        } else {
            for s in loaded { lastStatus[s.session_id] = s.status }
            seeded = true
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

    static func draw(in rect: NSRect, tint: NSColor, expr: Expr, tick: Int, wake: Double = 0, scale: Double = 1) {
        let gw = map.map { $0.count }.max() ?? 13
        let gh = map.count
        // `scale` briefly bumps the sprite (a pop on mood change); it recentres
        // because ox/oy are derived from `cell` below.
        let cell = min(rect.width, rect.height) / CGFloat(max(gw, gh) + 1) * CGFloat(scale)

        // Whole-cat motion by mood.
        var xOff: CGFloat = 0, yOff: CGFloat = 0
        switch expr {
        case .happy:   yOff = -abs(sin(Double(tick) * 0.35)) * 2.5   // bounce up (flipped view)
        case .alert:   xOff = (tick % 2 == 0) ? -1.5 : 1.5           // shake
        case .working: yOff = sin(Double(tick) * 0.5) * 1.0          // gentle bob, synced to steps
        case .sleeping: yOff = sin(Double(tick) * 0.06) * 0.6        // slow breathing rise/fall
        default: break
        }
        // A fresh wake: a quick upward stretch that settles back down.
        if wake > 0 { yOff -= CGFloat(wake) * 3.2 }

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

        // Springy multi-segment tail: a wave travels up the segments so the tip
        // trails the base. Energy/curl vary by mood.
        let (tAmp, tSpd, tLift): (Double, Double, Double)
        switch expr {
        case .working:  (tAmp, tSpd, tLift) = (1.6, 0.50, 0)
        case .alert:    (tAmp, tSpd, tLift) = (2.7, 0.95, 0)      // agitated whip
        case .happy:    (tAmp, tSpd, tLift) = (1.2, 0.60, -2.4)   // tail held high
        case .sleeping: (tAmp, tSpd, tLift) = (0.25, 0.05, 0.6)   // barely stirs, drapes down
        default:        (tAmp, tSpd, tLift) = (0.8, 0.14, 0)      // idle slow sway
        }
        let segN = 6
        for i in 0..<segN {
            let t = Double(i) / Double(segN - 1)                 // 0 base → 1 tip
            let phase = Double(tick) * tSpd - Double(i) * 0.7    // wave lags up the tail
            let sway = sin(phase) * tAmp * (0.3 + t)             // more sway toward the tip
            let x = 11.2 + t * 0.6 + sway
            let y = 10.0 + tLift * t - Double(i) * 0.85
            fill(x, y, i == 0 ? outline : tint)
        }

        // Body from the sprite map — but skip the front-paw row (12); it's drawn
        // separately so it can step.
        var eyeCells: [(Int, Int)] = []
        for (ry, row) in map.enumerated() where ry != 12 {
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

        // Front paws (row 12): alternate a small lift while working = a walk.
        let step = Double(tick) * 0.5
        let liftL = expr == .working ? min(0, sin(step)) * 1.4 : 0
        let liftR = expr == .working ? min(0, -sin(step)) * 1.4 : 0
        func paw(_ x0: Int, _ lift: Double) {
            fill(Double(x0),     12 + lift, outline)
            fill(Double(x0) + 1, 12 + lift, pink)
            fill(Double(x0) + 2, 12 + lift, pink)
            fill(Double(x0) + 3, 12 + lift, outline)
        }
        paw(2, liftL)
        paw(7, liftR)

        // Eyes per expression (drawn over the eye slots).
        // Blink rhythm has variety: a lone blink, then a quick double-blink, on
        // a ~12s loop — reads far more alive than a fixed metronome. A fresh
        // wake forces the eyes wide.
        let bc = tick % 132
        let blinking = wake <= 0 && ((expr == .sleeping)
            || (bc >= 24 && bc < 27)
            || (bc >= 92 && bc < 95) || (bc >= 100 && bc < 103))
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

        // Mood props — a small accessory that reinforces the current state.
        switch expr {
        case .working:
            // Mini keyboard below the paws; one key lights in sequence = typing.
            let kbW = 8.0 * cell, kbH = 2.6 * cell
            let kbX = ox + (13.0 * cell - kbW) / 2, kbY = oy + 12.9 * cell
            NSColor(white: 0.20, alpha: 0.95).setFill()
            NSBezierPath(roundedRect: NSRect(x: kbX, y: kbY, width: kbW, height: kbH),
                         xRadius: cell * 0.5, yRadius: cell * 0.5).fill()
            let lit = (tick / 3) % 8
            let keyW = cell * 1.4, keyH = cell * 0.8
            var idx = 0
            for r in 0..<2 {
                for cc in 0..<4 {
                    (idx == lit ? tint : NSColor(white: 0.45, alpha: 1)).setFill()
                    let kx = kbX + cell * 0.6 + Double(cc) * (keyW + cell * 0.35)
                    let ky = kbY + cell * 0.5 + Double(r) * (keyH + cell * 0.35)
                    NSBezierPath(roundedRect: NSRect(x: kx, y: ky, width: keyW, height: keyH),
                                 xRadius: cell * 0.2, yRadius: cell * 0.2).fill()
                    idx += 1
                }
            }
        case .alert:
            // Padlock accessory (top-left) with a periodic glint.
            let lw = 3.0 * cell, lh = 2.6 * cell
            let lx = ox + 0.2 * cell, ly = oy - 0.3 * cell
            let sT = cell * 0.55
            NSColor(white: 0.78, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: lx + cell * 0.5, y: ly, width: lw - cell, height: sT)).fill()
            NSBezierPath(rect: NSRect(x: lx + cell * 0.5, y: ly, width: sT, height: cell * 1.4)).fill()
            NSBezierPath(rect: NSRect(x: lx + lw - cell * 0.5 - sT, y: ly, width: sT, height: cell * 1.4)).fill()
            NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.30, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: lx, y: ly + cell * 1.1, width: lw, height: lh),
                         xRadius: cell * 0.4, yRadius: cell * 0.4).fill()
            NSColor(white: 0.15, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: lx + lw / 2 - cell * 0.35, y: ly + cell * 1.1 + lh * 0.32,
                                        width: cell * 0.7, height: cell * 0.7)).fill()
            if tick % 20 < 5 {
                NSColor.white.withAlphaComponent(1 - CGFloat(tick % 20) / 5).setStroke()
                let gx = lx + lw * 0.12, gy = ly + cell * 1.4
                let g = NSBezierPath(); g.lineWidth = cell * 0.3
                g.move(to: NSPoint(x: gx - cell * 0.5, y: gy)); g.line(to: NSPoint(x: gx + cell * 0.5, y: gy))
                g.move(to: NSPoint(x: gx, y: gy - cell * 0.5)); g.line(to: NSPoint(x: gx, y: gy + cell * 0.5))
                g.stroke()
            }
        default: break
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
