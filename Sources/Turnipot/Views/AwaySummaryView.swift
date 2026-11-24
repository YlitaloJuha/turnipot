import SwiftUI
import NotchCore

/// "While you were away" drop-down (missed-sessions mockup idea 3): happy mascot + "away 20m"
/// in the strip, then one row per session that finished / asked something while the user was
/// away (dot, title, "finished 12m ago" / "asked you something", ≡ read, "open ↗"; clicking a row
/// focuses its terminal, ≡ or scrolling down over it opens its reply reader), at most 4 + "+N more"
/// (opens the panel). It never auto-dismisses: it closes when hovered-then-left, on a click
/// elsewhere, esc (while hovered) or ✕ (NotchWindowController handles the first three).
struct AwaySummaryView: View {
    @ObservedObject var appState: AppState
    let summary: AwaySummary
    @EnvironmentObject private var ui: NotchUIState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NotchStrip(height: ui.geometry.notchHeight) {
                // A usage window reset while away: the turnip gets watered as the summary opens.
                MascotView(mood: .hop, pixelSize: MascotView.pixelSize(forStrip: ui.geometry.notchHeight),
                           watering: summary.items.contains(where: \.isUsageReset))
            } trailing: {
                Text("away \(Fmt.duration(seconds: summary.awayDuration))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                CloseButton { close() }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("While you were away")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(height: AwaySummaryMetrics.title, alignment: .topLeading)
                ForEach(summary.visibleItems) { item in
                    if let r = item.reset {
                        AwayResetRow(item: item, reset: r) { open(item) }
                    } else {
                        AwayItemRow(appState: appState, item: item, onOpen: { open(item) }, onRead: { read(item) })
                    }
                }
                if summary.moreCount > 0 {
                    Button {
                        appState.dismissAwaySummary()
                        appState.expand()
                    } label: {
                        Text("+\(summary.moreCount) more")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .padding(.leading, 6)
                            .frame(height: AwaySummaryMetrics.more, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show all sessions")
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, AwaySummaryMetrics.topPad)
            .padding(.bottom, AwaySummaryMetrics.bottomPad)
            Spacer(minLength: 0)
        }
    }

    /// ≡ / scroll: the session's reply reader (marks it seen, removing its item; the summary comes
    /// back when the reader closes if other items are left).
    private func read(_ item: AwaySummary.Item) {
        appState.openReader(sessionId: item.sessionId)
    }

    private func open(_ item: AwaySummary.Item) {
        appState.openAwayItem(sessionId: item.sessionId)
        if appState.awaySummary == nil { close() }
    }

    /// Like the panel's ✕: don't hover-expand again until the pointer has left the island.
    private func close() {
        ui.suppressHoverUntilExit = true
        ui.awaySummaryHovered = false
        appState.dismissAwaySummary()
        appState.setHovering(false)
    }
}

struct AwayItemRow: View {
    @ObservedObject var appState: AppState
    let item: AwaySummary.Item
    let onOpen: () -> Void
    let onRead: () -> Void
    @EnvironmentObject private var ui: NotchUIState
    @StateObject private var hovering = LocalState(false)

    var body: some View {
        let s = appState.session(id: item.sessionId)
        HStack(spacing: 9) {
            StatusDot(color: item.kind == .done ? Theme.accent : Theme.amber, pulse: false)
                .frame(width: 10)
            HStack(spacing: 6) {
                Text(s?.displayTitle ?? item.sessionId)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .truncationMode(.tail)
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(detail(now: ctx.date))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.muted)
                        .fixedSize()
                }
            }
            .lineLimit(1)
            Spacer(minLength: 6)
            Button(action: onRead) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering.value ? Theme.accent : Theme.muted)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Read reply (or scroll)")
            Text("open ↗")
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
                .fixedSize()
        }
        .padding(.horizontal, 6)
        .frame(height: AwaySummaryMetrics.row)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(hovering.value ? Theme.rowHover : .clear))
        .contentShape(Rectangle())
        .onHover { inside in
            hovering.value = inside
            // Scrolling down over a row opens that session's reader.
            ui.setReadTarget(.init(sessionId: item.sessionId, snippet: true), hovering: inside)
        }
        .onTapGesture(perform: onOpen)
        .help((s.map { ($0.isClaudeDesktop ? "Claude Desktop · " : "") + "\($0.name) · \(Fmt.abbreviatePath($0.cwd))\n" } ?? "")
              + (s?.isClaudeDesktop == true ? "Click: show in Claude Desktop" : "Click: open the terminal")
              + " · ≡ or scroll down: read the reply")
    }

    private func detail(now: Date) -> String {
        switch item.kind {
        case .asked: return "asked you something"
        case .waiting: return "asked you something · \(Fmt.duration(since: item.at, now: now)) ago"
        case .done: return "finished \(Fmt.duration(since: item.at, now: now)) ago"
        case .usageReset: return "reset \(Fmt.duration(since: item.at, now: now)) ago"
        }
    }
}

/// "While you were away" row for a usage window that reset meanwhile: green dot, "Session (5h)
/// usage reset", "was 97% · reset 9m ago"; click opens the panel (usage bars).
struct AwayResetRow: View {
    let item: AwaySummary.Item
    let reset: UsageReset
    let onOpen: () -> Void
    @StateObject private var hovering = LocalState(false)

    var body: some View {
        HStack(spacing: 9) {
            StatusDot(color: Theme.green, pulse: false)
                .frame(width: 10)
            HStack(spacing: 6) {
                Text("\(Fmt.usageLabel(reset.window.label)) usage reset")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text("was \(reset.previousPercent)% · \(Fmt.duration(since: item.at, now: ctx.date)) ago")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.muted)
                        .fixedSize()
                }
            }
            .lineLimit(1)
            Spacer(minLength: 6)
            Text("now \(reset.window.percent)%")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.green)
                .fixedSize()
        }
        .padding(.horizontal, 6)
        .frame(height: AwaySummaryMetrics.row)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(hovering.value ? Theme.rowHover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering.value = $0 }
        .onTapGesture(perform: onOpen)
        .help("Click: show usage in the panel")
    }
}
