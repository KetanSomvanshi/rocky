// Regression tests for SessionStore's registry⨯hook merge and alert logic —
// the "signal accuracy" surface described in ROADMAP.md. This repo has no
// test framework, so assertions just print ok/FAIL and exit nonzero on any
// failure (wireable into CI as a build step later).
//
// Run: swiftc ../RockyCore.swift test-session-store.swift -o /tmp/rocky-tests && /tmp/rocky-tests
import Foundation

var failures = 0

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok {
        print("  ok   - \(name)")
    } else {
        failures += 1
        print("  FAIL - \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }
}

func writeJSON(_ path: String, _ obj: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: obj)
    try! data.write(to: URL(fileURLWithPath: path))
}

func writeRegistry(_ sid: String, pid: Int, status: String, updatedAtMs: Double,
                    kind: String = "interactive", cwd: String = "/tmp/proj") {
    writeJSON(registryDir + "/\(pid).json", [
        "sessionId": sid, "pid": pid, "status": status,
        "updatedAt": updatedAtMs, "kind": kind, "cwd": cwd,
    ])
}

func writeHook(_ sid: String, status: String, ts: Double, pid: Int) {
    writeJSON(sessionsDir + "/\(sid).json",
              ["session_id": sid, "status": status, "ts": ts, "pid": pid])
}

/// A pid guaranteed to be dead right now (spawn + wait, so no PID-reuse risk).
func deadPid() -> Int {
    let p = Process()
    p.launchPath = "/bin/echo"
    p.arguments = ["hi"]
    p.standardOutput = FileHandle.nullDevice
    try! p.run()
    p.waitUntilExit()
    return Int(p.processIdentifier)
}

func reset() {
    for f in (try? FileManager.default.contentsOfDirectory(atPath: sessionsDir)) ?? [] {
        try? FileManager.default.removeItem(atPath: sessionsDir + "/" + f)
    }
    for f in (try? FileManager.default.contentsOfDirectory(atPath: registryDir)) ?? [] {
        try? FileManager.default.removeItem(atPath: registryDir + "/" + f)
    }
}

@main
struct TestSessionStore {
    static func main() {
        // Isolate from any real ~/.claude data — set before anything touches
        // the rockyHome/sessionsDir/registryDir globals (lazily computed once).
        let tmp = NSTemporaryDirectory() + "rocky-test-\(UUID().uuidString)"
        setenv("ROCKY_HOME", tmp, 1)
        try? FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: registryDir, withIntermediateDirectories: true)

        let myPid = Int(ProcessInfo.processInfo.processIdentifier)   // alive for the test's duration
        let now = Date().timeIntervalSince1970

        // 1. Freshness — hook newer than registry wins.
        reset()
        writeRegistry("s1", pid: myPid, status: "idle", updatedAtMs: (now - 30) * 1000)
        writeHook("s1", status: "needs_permission", ts: now, pid: myPid)
        var store = SessionStore()
        _ = store.refresh()
        check("fresh hook data overrides a stale registry idle/busy",
              store.sessions.first?.status == "needs_permission")

        // 2. Freshness — registry newer than a stale hook wins (no stuck alert).
        reset()
        writeHook("s2", status: "needs_permission", ts: now - 40, pid: myPid)
        writeRegistry("s2", pid: myPid, status: "busy", updatedAtMs: now * 1000)
        store = SessionStore()
        _ = store.refresh()
        check("live registry supersedes a stale needs_permission hook",
              store.sessions.first?.status == "processing",
              "got \(store.sessions.first?.status ?? "nil")")

        // 3. Freshness boundary — hook exactly at the 2s clock-skew tolerance still wins.
        reset()
        writeRegistry("s3", pid: myPid, status: "idle", updatedAtMs: now * 1000)
        writeHook("s3", status: "needs_permission", ts: now - 2, pid: myPid)
        store = SessionStore()
        _ = store.refresh()
        check("hook within the 2s clock-skew tolerance is trusted",
              store.sessions.first?.status == "needs_permission")

        // 4. Launch seeding — pre-existing "your turn" doesn't ding on startup.
        reset()
        writeRegistry("s4", pid: myPid, status: "idle", updatedAtMs: now * 1000)
        writeHook("s4", status: "waiting_for_input", ts: now, pid: myPid)
        store = SessionStore()
        let firstNotify = store.refresh()
        check("first refresh() never alerts for state that already existed",
              firstNotify.isEmpty, "got \(firstNotify.map { $0.session_id })")
        check("...but the session itself is still visible", store.sessions.count == 1)

        // A real transition afterward still alerts normally.
        writeHook("s4", status: "running_tool", ts: now + 1, pid: myPid)
        _ = store.refresh()
        writeHook("s4", status: "waiting_for_input", ts: now + 2, pid: myPid)
        let secondNotify = store.refresh()
        check("a genuine transition after launch still notifies",
              secondNotify.contains { $0.session_id == "s4" })

        // 5. Permission resolved at the terminal (not via Rocky) → still flags
        //    the very next "your turn", even with no intermediate poll.
        reset()
        writeHook("s5", status: "processing", ts: now, pid: myPid)
        store = SessionStore()
        _ = store.refresh()                                           // seed
        writeHook("s5", status: "needs_permission", ts: now + 1, pid: myPid)
        _ = store.refresh()
        writeHook("s5", status: "waiting_for_input", ts: now + 2, pid: myPid)
        let deniedNotify = store.refresh()
        check("needs_permission -> waiting_for_input (no intermediate poll) still notifies",
              deniedNotify.contains { $0.session_id == "s5" })

        // 6. Dead hook session is tidied up, not shown as a phantom alert.
        reset()
        let dead = deadPid()
        writeHook("s6", status: "needs_permission", ts: now, pid: dead)
        store = SessionStore()
        _ = store.refresh()
        check("a hook file for an exited process is removed, not surfaced",
              store.sessions.isEmpty)
        check("...and the file itself is deleted",
              !FileManager.default.fileExists(atPath: sessionsDir + "/s6.json"))

        // 7. Registry adapter tolerates a drifted schema.
        reset()
        writeJSON(registryDir + "/\(myPid).json", [
            "session_id": "s7", "process_id": "\(myPid)", "state": "busy",
            "updated_at": now, "type": "interactive", "working_dir": "/tmp/drift",
        ])
        store = SessionStore()
        _ = store.refresh()
        check("tolerant decode recovers a snake_case/renamed schema",
              store.sessions.first?.session_id == "s7")

        try? FileManager.default.removeItem(atPath: tmp)

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
