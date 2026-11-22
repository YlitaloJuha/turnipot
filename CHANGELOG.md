# Changelog

## 0.5.1

**Claude Desktop**
- Clicking a Claude Desktop session (or "Reply in Claude ↗" / "Answer in Claude ↗") now opens that exact session, not whichever one Claude Desktop last showed. Turnipot finds Claude Desktop's id for the session and opens its `claude://code/continue` link; if it can't, it just brings Claude Desktop forward as before.

## 0.5.0

**Terminal and iTerm2**
- Click a session running in Terminal or iTerm2 to bring its tab forward, and send quick replies into it. Nothing to install: macOS asks once per app whether Turnipot may control it (the app now has the Apple Events entitlement for this).
- Sessions in other apps (Ghostty, Warp, WezTerm, or an editor without the extension) bring that app to the front when clicked.

**Releases**
- The editor extension is attached to each release as `turnipot-bridge-<version>.vsix`, and the release notes start with the install steps.

## 0.4.0

**Signed and notarized**
- Releases are signed with a Developer ID and notarized by Apple, so Turnipot opens with a double-click: no more right-click → Open.
- The bundle id is now `com.juhaylitalo.turnipot` (was `com.local.turnipot`). Your settings (haptics, update check) carry over on the first launch. macOS keeps login items per app id, so turn **Launch at login** on again in ⚙.

**One mascot**
- The turnip is now Turnipot's only mascot: Sprout, the Peeker and the Mascot menu are gone. A saved mascot choice is cleared on the first launch.

**Reader**
- Tables in Claude's replies render as aligned columns when they fit the reader, and as one "Header: value" record per row when they don't.

## 0.3.0

The first packaged release of Turnipot, a Mac notch companion for Claude Code.

**Sessions at a glance**
- The pill around the notch shows busy sessions, your 5-hour usage and a badge for sessions that finished while you weren't looking ("2 done", "1 waiting").
- Hover to open the panel: every session with its status, current context size (drops after `/compact`), time since the last interaction, running subagents and workflows, and your 5-hour and weekly usage.
- Click a session to jump to its terminal in VSCodium, VS Code or Cursor; Claude Desktop sessions bring Claude Desktop forward.

**Answer Claude from the notch**
- Permission requests: Allow, Always allow (Claude's own suggested rule, never a guessed prefix), Deny, or Open session. ⌘↩ / esc while you hover it.
- Questions (`AskUserQuestion`): pick options with a click or 1-9, multi-select, type your own answer.
- Plans (`ExitPlanMode`): read the plan, approve it (optionally with auto-accept edits or auto mode), or send it back with feedback.
- Safety: buttons and hot keys ignore input for 400 ms after a drop-down appears or switches to the next request; hot keys arm only after the pointer moves onto it; quick reply is disabled for a session while Claude may be showing its own prompt in that terminal.

**Read and reply**
- Scroll down over a session to read its latest replies rendered from Markdown, page through the last ten turns, and send a quick reply.
- When a turn finishes the notch drops down with Claude's last sentence and a reply field; a "While you were away" summary waits for you after you lock the screen or step away.

**Mascots and haptics**
- Turnip (default), Sprout and Peeker, each with idle, working, finished, needs-you and near-limit moods.
- Trackpad haptics in time with the mascot (toggle in ⚙).

**Install and updates**
- ⚙ → Install Claude Code hook… and Install editor extension…: set up the integrations from the app, with a preview of what changes (settings.json is backed up first).
- ⚙ → Launch at login.
- ⚙ → Check for updates: one anonymous request to GitHub a day; a notice when a newer release exists.
- `scripts/install-app.sh` installs a source build into /Applications and repoints the hook; `scripts/release.sh` packages a release zip.
