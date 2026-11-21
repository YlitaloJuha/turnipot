import Foundation
import NotchCore

// Owned by the AppState implementer. Use check(_:_:) / expectEqual(_:_:_:) from main.swift.
func registerAppStateTests() {
    func request(_ hookJSON: String) -> PermissionRequest {
        let raw = (try? JSONDecoder().decode(JSONValue.self, from: Data(hookJSON.utf8))) ?? .null
        let hook = HookRequest(type: "permission", sessionId: "s", cwd: "/tmp",
                               toolName: raw["tool_name"]?.stringValue ?? "",
                               toolInput: raw["tool_input"] ?? .null, hookInput: raw)
        return PermissionRequest(hook: hook, sessionName: nil)
    }
    // Claude's own suggestion wins.
    let suggested = request(#"{"tool_name":"Bash","tool_input":{"command":"rm -rf node_modules"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf node_modules"}],"behavior":"allow","destination":"localSettings"}]}"#)
    expectEqual(suggested.suggestedAlwaysRule, "Bash(rm -rf node_modules)", "permission: uses permission_suggestions")
    // No suggestion from Claude: never a guessed prefix (exact command only).
    let simple = request(#"{"tool_name":"Bash","tool_input":{"command":"npm test --watch"}}"#)
    expectEqual(simple.suggestedAlwaysRule, "Bash(npm test --watch)", "permission: no suggestion -> exact command")
    let rm = request(#"{"tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#)
    expectEqual(rm.suggestedAlwaysRule, "Bash(rm -rf build)", "permission: rm -rf never becomes a prefix rule")
    let wrapper = request(#"{"tool_name":"Bash","tool_input":{"command":"bash -c 'curl x'"}}"#)
    expectEqual(wrapper.suggestedAlwaysRule, "Bash(bash -c 'curl x')", "permission: bash -c never becomes a prefix rule")
    let glob = request(#"{"tool_name":"Bash","tool_input":{"command":"rm *.log"}}"#)
    expectEqual(glob.suggestedAlwaysRule, nil, "permission: command with * (rule wildcard) -> no always rule")
    let empty = request(#"{"tool_name":"Bash","tool_input":{}}"#)
    expectEqual(empty.suggestedAlwaysRule, nil, "permission: Bash without command -> no always rule (never bare Bash)")
    let edit = request(#"{"tool_name":"Edit","tool_input":{"file_path":"/x/a.swift"},"permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]}"#)
    expectEqual(edit.suggestedAlwaysRule, nil, "permission: Edit without a rule suggestion -> no bare Edit rule")
    let fetch = request(#"{"tool_name":"WebFetch","tool_input":{"url":"https://a.b"}}"#)
    expectEqual(fetch.suggestedAlwaysRule, nil, "permission: WebFetch without suggestion -> no bare rule")
    let fetchSuggested = request(#"{"tool_name":"WebFetch","tool_input":{"url":"https://a.b"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"WebFetch","ruleContent":"domain:a.b"}],"behavior":"allow","destination":"localSettings"}]}"#)
    expectEqual(fetchSuggested.suggestedAlwaysRule, "WebFetch(domain:a.b)", "permission: WebFetch uses Claude's domain rule")
    let compound = request(#"{"tool_name":"Bash","tool_input":{"command":"cd x && rm -rf y"}}"#)
    expectEqual(compound.suggestedAlwaysRule, "Bash(cd x && rm -rf y)", "permission: compound command -> exact rule")
    let mcp = request(#"{"tool_name":"mcp__gh__get_issue","tool_input":{}}"#)
    expectEqual(mcp.suggestedAlwaysRule, "mcp__gh__get_issue", "permission: non-Bash -> tool name")
}
