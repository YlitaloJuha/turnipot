import Foundation
import NotchCore

// Owned by the Usage implementer. Use check(_:_:) / expectEqual(_:_:_:) from main.swift.
func registerUsageTests() {
    // Real output captured from `claude -p "/usage"` on this machine (2026-11-18), trimmed.
    let sample = """
    You are currently using your subscription to power your Claude Code usage

    Current session: 5% used · resets Nov 19 at 12:30am (America/Los_Angeles)
    Current week (all models): 43% used · resets Nov 20 at 9pm (America/Los_Angeles)
    Current week (Fable): 21% used · resets Nov 20 at 9pm (America/Los_Angeles)

    What's contributing to your usage?
    Approximate · sessions on this machine only · shares overlap

    Last 24h · 1799 requests · 8 sessions
      58%  Save workflows for big tasks · 61 agents ran
      Top skills: /plugin-authoring 1%, /workflow-authoring 1%
    """
    let w = UsageMonitor.parse(sample)
    expectEqual(w.count, 3, "usage: 3 windows")
    expectEqual(w.map(\.label), ["session", "week (all models)", "week (Fable)"], "usage: labels in order")
    expectEqual(w.map(\.percent), [5, 43, 21], "usage: percents")
    expectEqual(w.first?.resetsText ?? "", "Nov 19 at 12:30am (America/Los_Angeles)", "usage: resets text")

    // Variants: ANSI colors, "-" separator, no resets part, CRLF, decimal percent.
    let variants = "\u{1B}[1mCurrent session:\u{1B}[0m 87% used - resets 3pm\r\nCurrent week (Opus): 12.6% used\r\n"
    let v = UsageMonitor.parse(variants)
    expectEqual(v.map(\.label), ["session", "week (Opus)"], "usage: variant labels")
    expectEqual(v.map(\.percent), [87, 13], "usage: variant percents")
    expectEqual(v.map(\.resetsText), ["3pm", ""], "usage: variant resets")
    check("usage: near limit", v.first?.isNearLimit == true)

    expectEqual(UsageMonitor.parse("Error: not logged in").count, 0, "usage: garbage -> empty")

    // Process plumbing with stand-in binaries: output, non-zero exit, unlaunchable binary.
    func runCommand(_ bin: String, timeout: TimeInterval = 5) -> (out: String?, error: Error?) {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out: String?
        nonisolated(unsafe) var err: Error?
        Task.detached {
            do { out = try await UsageMonitor.runUsageCommand(binary: bin, timeout: timeout) } catch { err = error }
            sem.signal()
        }
        return sem.wait(timeout: .now() + 10) == .timedOut ? (nil, nil) : (out, err)
    }
    expectEqual(runCommand("/bin/echo").out, "-p /usage\n", "usage cmd: stdout returned")
    check("usage cmd: non-zero exit throws", runCommand("/usr/bin/false").error != nil)
    check("usage cmd: unlaunchable binary throws", runCommand("/nonexistent/claude").error != nil)
    let slowScript = FileManager.default.temporaryDirectory.appendingPathComponent("turnipot-slow-\(getpid()).sh")
    try? "#!/bin/sh\nsleep 5\n".write(to: slowScript, atomically: true, encoding: .utf8)
    chmod(slowScript.path, 0o755)
    if let e = runCommand(slowScript.path, timeout: 0.5).error, case UsageMonitor.UsageError.timedOut = e {
        check("usage cmd: timeout", true)
    } else {
        check("usage cmd: timeout", false)
    }
    try? FileManager.default.removeItem(at: slowScript)

    // Opt-in live check: TURNIPOT_LIVE=1 swift run turnipot-selftest
    if ProcessInfo.processInfo.environment["TURNIPOT_LIVE"] == "1" {
        let bin = UsageMonitor.locateClaudeBinary()
        check("usage live: binary found", bin != nil)
        if let bin {
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var out: String?
            Task.detached { out = try? await UsageMonitor.runUsageCommand(binary: bin); sem.signal() }
            sem.wait()
            let live = UsageMonitor.parse(out ?? "")
            print("usage live: \(bin) ->", live.map { "\($0.label)=\($0.percent)% [\($0.resetsText)]" })
            check("usage live: parsed windows", !live.isEmpty)
        }
    }
}
