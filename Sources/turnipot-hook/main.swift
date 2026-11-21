import Foundation
import HookOutput

// turnipot-hook — Claude Code "PermissionRequest" hook. Foundation only (no NotchCore dependency).
//
// Verified against https://code.claude.com/docs/en/hooks (2026-11-19):
//  Input (stdin): {"session_id","transcript_path","cwd","permission_mode","hook_event_name":"PermissionRequest",
//                  "tool_name","tool_input":{...},"permission_suggestions":[...]?, "mcp_server"?, ...}
//  Output (stdout, exit 0):
//    {"hookSpecificOutput":{"hookEventName":"PermissionRequest",
//       "decision":{"behavior":"allow","updatedPermissions":[{"type":"addRules",
//                   "rules":[{"toolName":"Bash","ruleContent":"npm test:*"}],
//                   "behavior":"allow","destination":"localSettings"}]}}}
//    {"hookSpecificOutput":{"hookEventName":"PermissionRequest",
//       "decision":{"behavior":"deny","message":"..."}}}
//  Exit 0 with no output => no decision; Claude shows its normal permission prompt.
//  (Exit 2 is NOT honored for PermissionRequest; we never use it.)
//
// Flow:
//  1. Read hook input JSON from stdin.
//  2. Connect to ~/Library/Application Support/Turnipot/app.sock (override: $TURNIPOT_SOCKET).
//     Missing/unconnectable -> exit 0, no stdout.
//  3. Write one line: {"type":"permission"|"question"|"plan","sessionId","cwd","toolName","toolInput","hookInput"}.
//  4. Wait up to 60s ($TURNIPOT_HOOK_TIMEOUT; questions/plans 570s, $TURNIPOT_QUESTION_TIMEOUT)
//     for {"decision":"allow"|"deny"|"ask","alwaysRule"?,"updatedInput"?,"mode"?,"message"?}.
//     Timeout / error / malformed / "ask" -> exit 0, no output.
//  5. allow/deny -> print decision JSON (HookOutput.output). alwaysRule "Tool(content)" -> addRules
//     entry (destination localSettings, like Claude's own "don't ask again" option); updatedInput ->
//     decision.updatedInput; mode -> setMode entry (destination session); message -> deny message.
//
// AskUserQuestion / ExitPlanMode are forwarded as type "question" / "plan" and wait longer
// (TURNIPOT_QUESTION_TIMEOUT, default 570s). Their "allow" must carry `updatedInput` with the
// answer (docs: "Tools that require user interaction"); the mapping lives in HookOutput.

func silentExit() -> Never { exit(0) }

func emit(_ object: [String: Any]) -> Never {
    if let text = HookOutput.serialize(object) {
        FileHandle.standardOutput.write(Data(text.utf8))
        FileHandle.standardOutput.write(Data([0x0A]))
    }
    exit(0)
}

// MARK: 1. stdin

let inputData = FileHandle.standardInput.readDataToEndOfFile()
guard let input = (try? JSONSerialization.jsonObject(with: inputData)) as? [String: Any] else { silentExit() }
if let event = input["hook_event_name"] as? String, event != "PermissionRequest" { silentExit() }
let toolName = input["tool_name"] as? String ?? ""
if toolName.isEmpty { silentExit() }
let requestType = HookOutput.requestType(toolName: toolName)

// MARK: 2. connect

let env = ProcessInfo.processInfo.environment
let socketPath = env["TURNIPOT_SOCKET"]
    ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Turnipot/app.sock")
let waitSeconds = HookOutput.waitSeconds(requestType: requestType, environment: env)

guard FileManager.default.fileExists(atPath: socketPath) else { silentExit() }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { silentExit() }
withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    raw.copyBytes(from: pathBytes)
    raw[pathBytes.count] = 0
}
addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { silentExit() }
var one: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
var sendTV = timeval(tv_sec: 5, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTV, socklen_t(MemoryLayout<timeval>.size))
var recvTV = timeval(tv_sec: waitSeconds, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &recvTV, socklen_t(MemoryLayout<timeval>.size))

let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else { silentExit() }

// MARK: 3. request

var request: [String: Any] = [
    "type": requestType,
    "sessionId": input["session_id"] as? String ?? "",
    "toolName": toolName,
    "toolInput": input["tool_input"] ?? [String: Any](),
    "hookInput": input,
]
if let cwd = input["cwd"] as? String { request["cwd"] = cwd }
guard var payload = try? JSONSerialization.data(withJSONObject: request) else { silentExit() }
payload.append(0x0A)

let wroteAll: Bool = payload.withUnsafeBytes { buf in
    var off = 0
    while off < buf.count {
        let n = write(fd, buf.baseAddress! + off, buf.count - off)
        if n < 0 { if errno == EINTR { continue }; return false }
        off += n
    }
    return true
}
guard wroteAll else { silentExit() }
// NOTE: do not shutdown(SHUT_WR) — the app treats EOF from us as "hook went away".

// MARK: 4. response

let deadline = Date().addingTimeInterval(TimeInterval(waitSeconds))
var responseData = Data()
var chunk = [UInt8](repeating: 0, count: 4096)
readLoop: while Date() < deadline {
    let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
    if n < 0 { if errno == EINTR { continue }; silentExit() }   // timeout (EAGAIN) or error
    if n == 0 { break }
    if let nl = chunk[0..<n].firstIndex(of: 0x0A) {
        responseData.append(contentsOf: chunk[0..<nl])
        break readLoop
    }
    responseData.append(contentsOf: chunk[0..<n])
    if responseData.count > 1 << 20 { silentExit() }
}
close(fd)

guard let response = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any],
      let output = HookOutput.output(response: response, toolName: toolName) else { silentExit() }

// MARK: 5. output

emit(output)
