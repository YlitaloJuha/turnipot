import Foundation
import Darwin

/// Sessions running in a stand-alone terminal app rather than an editor's integrated terminal.
/// Terminal and iTerm2 are scriptable and address their tabs by tty, so the app can select the
/// session's tab and type a reply into it with AppleScript (run through `/usr/bin/osascript`, so
/// NotchCore needs no AppKit / Carbon). Any other app found in the session's parent chain
/// (Ghostty, Warp, WezTerm, an editor without the bridge extension, …) is only brought forward.
public enum NativeTerminal: String, CaseIterable, Sendable {
    case appleTerminal
    case iTerm2

    public var bundleId: String {
        switch self {
        case .appleTerminal: return "com.apple.Terminal"
        case .iTerm2: return "com.googlecode.iterm2"
        }
    }

    public var displayName: String {
        switch self {
        case .appleTerminal: return "Terminal"
        case .iTerm2: return "iTerm2"
        }
    }

    public init?(bundleId: String?) {
        guard let id = bundleId?.lowercased(),
              let t = NativeTerminal.allCases.first(where: { $0.bundleId.lowercased() == id }) else { return nil }
        self = t
    }

    /// Where a session's terminal lives: the outermost app bundle in its parent chain and the
    /// tty of the claude process.
    public struct Location: Equatable, Sendable {
        public var appPath: String
        public var bundleId: String?
        public var tty: String?
        public init(appPath: String, bundleId: String?, tty: String?) {
            self.appPath = appPath; self.bundleId = bundleId; self.tty = tty
        }
        public var terminal: NativeTerminal? { NativeTerminal(bundleId: bundleId) }
    }

    /// `/Applications/X.app` for the nearest ancestor that runs from inside an app bundle (the
    /// outermost `.app` of that path, so an editor's `… Helper.app` resolves to the editor).
    /// Claude Desktop's bundled `claude.app` binary is the session itself, never an ancestor here.
    public static func hostAppPath(ancestorPaths: [String]) -> String? {
        for path in ancestorPaths {
            guard let r = path.range(of: ".app/") else { continue }
            return String(path[..<r.lowerBound]) + ".app"
        }
        return nil
    }

    /// Location of `pid`'s terminal (nil when no ancestor is an app, e.g. inside tmux or over ssh).
    public static func locate(pid: Int32, ancestorPaths: [String]? = nil) -> Location? {
        let paths = ancestorPaths ?? SessionMonitor.ancestorPaths(of: pid)
        guard let app = hostAppPath(ancestorPaths: paths) else { return nil }
        return Location(appPath: app, bundleId: Bundle(path: app)?.bundleIdentifier, tty: ttyPath(pid: pid))
    }

    /// `/dev/ttysNNN` of the process's controlling terminal (sysctl e_tdev + devname). nil if none.
    public static func ttyPath(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, 4, &info, &size, nil, 0) }
        guard rc == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let dev = info.kp_eproc.e_tdev
        guard dev != -1 /* NODEV */, let name = devname(dev, S_IFCHR) else { return nil }
        let s = String(cString: name)
        guard !s.isEmpty, s != "??" else { return nil }
        return "/dev/" + s
    }

    // MARK: Scripts

    /// The reply as typed: newlines become spaces (one prompt line) and other control characters
    /// are dropped, so the text can't end the bracketed paste early or send keys of its own.
    public static func sanitizedReply(_ text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return String(String.UnicodeScalarView(oneLine.unicodeScalars.filter {
            !($0.value < 0x20 || (0x7F...0x9F).contains($0.value))
        }))
    }

    /// The bytes a reply sends: the text as a bracketed paste, then Return. Claude Code's prompt
    /// takes a long burst of typed text as a paste and turns its Return into a newline; inside
    /// paste markers the Return after them is a key press of its own and submits.
    public static func replyPayload(_ text: String) -> String {
        "\u{1B}[200~" + sanitizedReply(text) + "\u{1B}[201~\r"
    }

    /// AppleScript (run as `osascript - <tty> [text]`) that selects the tab whose tty matches and
    /// raises its window. Prints "ok" or "missing". The app itself is activated with `open -b`.
    public func focusScript() -> String {
        switch self {
        case .appleTerminal:
            return """
            on run argv
              set ttyName to item 1 of argv
              tell application id "com.apple.Terminal"
                repeat with w in windows
                  repeat with t in tabs of w
                    if tty of t is ttyName then
                      if miniaturized of w then set miniaturized of w to false
                      set selected tab of w to t
                      set index of w to 1
                      return "ok"
                    end if
                  end repeat
                end repeat
              end tell
              return "missing"
            end run
            """
        case .iTerm2:
            return """
            on run argv
              set ttyName to item 1 of argv
              tell application id "com.googlecode.iterm2"
                repeat with w in windows
                  repeat with t in tabs of w
                    repeat with s in sessions of t
                      if tty of s is ttyName then
                        select w
                        select t
                        select s
                        return "ok"
                      end if
                    end repeat
                  end repeat
                end repeat
              end tell
              return "missing"
            end run
            """
        }
    }

    /// `text` as an AppleScript string literal (sanitized first, so only `\\` and `"` need escaping).
    public static func appleScriptLiteral(_ text: String) -> String {
        "\"" + sanitizedReply(text).replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// AppleScript (run as `osascript - <tty>`) that types `replyPayload(reply)` into the tab whose
    /// tty matches. The reply is embedded in the script, which reaches osascript on stdin as UTF-8:
    /// command line arguments would arrive decomposed (é as e + U+0301).
    public func sendScript(reply: String) -> String {
        let payload = "(character id 27) & \"[200~\" & \(NativeTerminal.appleScriptLiteral(reply)) & (character id 27) & \"[201~\""
        switch self {
        case .appleTerminal:
            // `do script … in <tab>` types the text and then Return itself.
            return """
            on run argv
              set ttyName to item 1 of argv
              set payload to \(payload)
              tell application id "com.apple.Terminal"
                repeat with w in windows
                  repeat with t in tabs of w
                    if tty of t is ttyName then
                      do script payload in t
                      return "ok"
                    end if
                  end repeat
                end repeat
              end tell
              return "missing"
            end run
            """
        case .iTerm2:
            // `newline no` + an explicit Return (character id 13): exactly the payload's bytes.
            return """
            on run argv
              set ttyName to item 1 of argv
              set payload to \(payload) & (character id 13)
              tell application id "com.googlecode.iterm2"
                repeat with w in windows
                  repeat with t in tabs of w
                    repeat with s in sessions of t
                      if tty of s is ttyName then
                        tell s to write text payload newline no
                        return "ok"
                      end if
                    end repeat
                  end repeat
                end repeat
              end tell
              return "missing"
            end run
            """
        }
    }

    // MARK: Running

    /// Outcome of an osascript run.
    public enum ScriptResult: Equatable, Sendable {
        case ok
        case missing            // the app has no tab with that tty
        case notAuthorized      // Automation permission denied (-1743)
        case failed(String)
    }

    /// Runs `script` with `/usr/bin/osascript - args…` (script on stdin). The first run per
    /// terminal app shows macOS's "Turnipot wants to control …" prompt, hence the long timeout.
    public static func runScript(_ script: String, arguments: [String], timeout: TimeInterval = 60) -> ScriptResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-"] + arguments
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return .failed("osascript: \(error.localizedDescription)") }
        input.fileHandleForWriting.write(Data(script.utf8))
        try? input.fileHandleForWriting.close()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return .failed("osascript timed out")
        }
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return parseResult(status: p.terminationStatus, stdout: out, stderr: err)
    }

    public static func parseResult(status: Int32, stdout: String, stderr: String) -> ScriptResult {
        if status == 0 {
            switch stdout {
            case "ok": return .ok
            case "missing": return .missing
            default: return .failed("unexpected output: \(stdout)")
            }
        }
        if stderr.contains("-1743") || stderr.contains("-10004") { return .notAuthorized }
        return .failed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
