import SwiftUI
import NotchCore

/// "Needs you" drop-down (mockup state 4 + interactions A): shaking mascot and pulsing amber dot
/// in the notch strip; "<session> wants to run a command", the tool summary in a code block,
/// and Allow (⌘↩) / Always allow "<rule>" / Deny (esc) / Open session ↗.
/// The ⌘↩ / esc shortcuts are hot keys registered by NotchWindowController while a permission
/// is pending AND the pointer is over the island (see HotKeys.swift), so they work without
/// focusing the notch but never fire from keystrokes meant for another app.
struct PermissionView: View {
    @ObservedObject var appState: AppState
    let request: PermissionRequest
    @EnvironmentObject private var ui: NotchUIState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NeedsYouStrip(appState: appState)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text(sessionName).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    Text(Self.verb(for: request.toolName)).font(.system(size: 13)).foregroundStyle(Theme.muted)
                    Spacer(minLength: 0)
                }
                .lineLimit(1)

                Text(request.summary.isEmpty ? request.toolName : request.summary)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(hex: 0xe5e5e5))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.codeBackground)
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Theme.cardBorder, lineWidth: 1))
                    )
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .help(request.summary)

                HStack(spacing: 8) {
                    Button { decide(.allow) } label: {
                        HStack(spacing: 6) {
                            Text("Allow")
                            Text("⌘↩").font(.system(size: 10)).foregroundStyle(Theme.muted)
                        }
                    }
                    .buttonStyle(NotchButtonStyle(background: Color(hex: 0x1f6f3c)))

                    if let rule = request.suggestedAlwaysRule {
                        Button { decide(.allowAlways(rule: rule)) } label: {
                            Text(Self.alwaysLabel(rule))
                        }
                        .buttonStyle(NotchButtonStyle())
                        .help("Adds the allow rule \(rule)")
                    }

                    Button { decide(.deny) } label: {
                        HStack(spacing: 6) {
                            Text("Deny")
                            Text("esc").font(.system(size: 10)).foregroundStyle(Theme.muted)
                        }
                    }
                    .buttonStyle(NotchButtonStyle(background: Color(hex: 0x5b2323)))

                    Spacer(minLength: 8)

                    Button {
                        guard ui.needsYouActionAllowed(request.id) else { return }
                        appState.openPermissionInTerminal(id: request.id)
                        let desktop = appState.session(id: request.sessionId)?.isClaudeDesktop == true
                        ui.confirm(desktop ? "↗ Opened Claude Desktop" : "↗ Opened in VSCodium", tone: .neutral)
                    } label: {
                        Text("Open session ↗")
                    }
                    .buttonStyle(NotchButtonStyle())
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 2)
            .padding(.bottom, 16)
            Spacer(minLength: 0)
        }
    }

    private var sessionName: String {
        request.sessionName ?? appState.session(id: request.sessionId)?.name ?? "Claude"
    }

    private static func alwaysLabel(_ rule: String) -> String {
        if let open = rule.firstIndex(of: "("), rule.hasSuffix(")") {
            var inner = String(rule[rule.index(after: open)..<rule.index(before: rule.endIndex)])
            if inner.hasSuffix(":*") { inner.removeLast(2) }
            if inner.count > 18 { inner = String(inner.prefix(17)) + "…" }
            return "Always allow “\(inner)”"
        }
        return "Always allow \(rule)"
    }

    private func decide(_ decision: PermissionDecision) {
        Self.resolve(appState: appState, ui: ui, request: request, decision: decision)
    }

    /// Shared with the global hot keys.
    @MainActor
    static func resolve(appState: AppState, ui: NotchUIState, request: PermissionRequest, decision: PermissionDecision) {
        // A click / ⌘↩ that lands within 400 ms of the drop-down appearing was meant for something else.
        guard ui.needsYouActionAllowed(request.id) else { return }
        appState.resolvePermission(id: request.id, decision: decision)
        switch decision {
        case .allow: ui.confirm("✓ Allowed", tone: .ok)
        case .allowAlways(let rule): ui.confirm("✓ Always allowed", detail: rule, tone: .ok)
        case .deny: ui.confirm("✕ Denied", tone: .bad)
        case .ask, .answer, .approvePlan, .denyWithMessage: break
        }
    }

    static func verb(for tool: String) -> String {
        switch tool {
        case "Bash", "BashOutput": return "wants to run a command"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "wants to edit a file"
        case "Read": return "wants to read a file"
        case "WebFetch": return "wants to fetch a URL"
        case "WebSearch": return "wants to search the web"
        case "Glob", "Grep": return "wants to search files"
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
                return "wants to use \(parts.last.map(String.init) ?? tool)"
            }
            return "wants to use \(tool)"
        }
    }
}
