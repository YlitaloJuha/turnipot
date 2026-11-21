import Foundation

/// Pure mapping between Claude Code's `PermissionRequest` hook and the app.sock protocol, shared
/// by `turnipot-hook` (Foundation only, no NotchCore) and the self-tests.
///
/// Verified against https://code.claude.com/docs/en/hooks (2026-11-19):
///  - "PermissionRequest decision control": `hookSpecificOutput.decision` = `{behavior: "allow"|"deny",
///    updatedInput? (allow only; replaces the whole input), updatedPermissions? (allow only),
///    message? (deny only), interrupt? (deny only)}`.
///  - "Tools that require user interaction" (#allow-with-updatedinput): for `AskUserQuestion` and
///    `ExitPlanMode`, "allow" alone is not sufficient; return "allow" with `updatedInput` holding the
///    answer. AskUserQuestion: echo the original `questions` array and add `answers` mapping each
///    question's text to the chosen label ("Multi-select answers join labels with commas").
///  - "Permission update entries": `{type: "setMode", mode, destination}`; modes `default`, `auto`,
///    `acceptEdits`, `dontAsk`, `bypassPermissions`, `plan`; destination `session` = in memory only.
public enum HookOutput {
    /// Tools whose "allow" needs an `updatedInput` carrying the user's answer.
    public static let interactiveTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// app.sock request type for a tool: "question" (AskUserQuestion), "plan" (ExitPlanMode),
    /// otherwise "permission".
    public static func requestType(toolName: String) -> String {
        switch toolName {
        case "AskUserQuestion": return "question"
        case "ExitPlanMode": return "plan"
        default: return "permission"
        }
    }

    /// Seconds the hook waits for the app's answer. Permission prompts: 60 s (the app gives up
    /// at 55 s). Questions / plans take longer to read: 570 s (the app gives up at 565 s), which
    /// stays under the 600 s hook `timeout` that scripts/install-hook.sh registers.
    public static func waitSeconds(requestType: String, environment: [String: String]) -> Int {
        if requestType == "permission" {
            return Int(environment["TURNIPOT_HOOK_TIMEOUT"] ?? "") ?? 60
        }
        return Int(environment["TURNIPOT_QUESTION_TIMEOUT"] ?? "") ?? 570
    }

    /// The hook's stdout object for an app response, or nil = print nothing (Claude Code shows
    /// its normal prompt): "ask", unknown decisions, and an "allow" for an interactive tool
    /// without `updatedInput` (which the docs say is not sufficient).
    ///
    /// Response fields (from the app): `decision` "allow"|"deny"|"ask", `alwaysRule`
    /// ("Tool(content)"), `updatedInput` (object), `mode` (permission mode to switch to after
    /// approving a plan), `message` (deny reason shown to Claude).
    public static func output(response: [String: Any], toolName: String) -> [String: Any]? {
        guard let decision = response["decision"] as? String else { return nil }
        switch decision {
        case "allow":
            var d: [String: Any] = ["behavior": "allow"]
            let updated = response["updatedInput"] as? [String: Any]
            if interactiveTools.contains(toolName) && updated == nil { return nil }
            if let updated { d["updatedInput"] = updated }
            var perms: [[String: Any]] = []
            if let rule = response["alwaysRule"] as? String, let value = ruleValue(rule) {
                perms.append(["type": "addRules", "rules": [value], "behavior": "allow", "destination": "localSettings"])
            }
            if let mode = response["mode"] as? String, validModes.contains(mode) {
                perms.append(["type": "setMode", "mode": mode, "destination": "session"])
            }
            if !perms.isEmpty { d["updatedPermissions"] = perms }
            return ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": d]]
        case "deny":
            let msg = (response["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "The user denied this tool call from Turnipot."
            return ["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                           "decision": ["behavior": "deny", "message": msg]]]
        default:
            return nil
        }
    }

    /// Permission modes accepted for `setMode` (docs: "Permission update entries").
    public static let validModes: Set<String> = ["default", "auto", "acceptEdits", "dontAsk", "bypassPermissions", "plan"]

    /// "Bash(npm test:*)" -> {"toolName":"Bash","ruleContent":"npm test:*"}; "WebSearch" -> {"toolName":"WebSearch"}.
    public static func ruleValue(_ rule: String) -> [String: Any]? {
        let r = rule.trimmingCharacters(in: .whitespaces)
        guard !r.isEmpty else { return nil }
        if let open = r.firstIndex(of: "("), r.hasSuffix(")") {
            let tool = String(r[..<open])
            let content = String(r[r.index(after: open)..<r.index(before: r.endIndex)])
            guard !tool.isEmpty else { return nil }
            // MCP allow rules must not carry ruleContent; "*" / "" means the whole tool.
            if tool.hasPrefix("mcp__") || content.isEmpty || content == "*" { return ["toolName": tool] }
            return ["toolName": tool, "ruleContent": content]
        }
        return ["toolName": r]
    }

    /// Compact JSON with sorted keys (what the hook prints; also used by tests).
    public static func serialize(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
