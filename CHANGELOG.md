# Changelog

## 0.8.2

- Sessions that finish close together stack in the "finished" drop-down instead of the newer one replacing the older: up to 3 cards, oldest on top, each with its own **Read** and reply field ("✓ 2 done" in the notch). A new card is added at the bottom, so nothing moves under the pointer. While the pointer is on the drop-down nothing is added or times out; a session that finishes meanwhile shows as "+1 more" and gets its card when you move away. Buttons ignore clicks for 400 ms after a card is added or removed.
- The README pictures are re-rendered for 0.8.x (usage rings, the finished drop-down's buttons, ≡ opens the reader).

## 0.8.1

- Scrolling the session list never opens a chat: it only scrolls the list. Click ≡ on a row to read its reply. Scrolling down still opens the reply from the "finished" drop-down and the "While you were away" summary.
- The session panel has a big **Mark all read** button under the usage bars while any session is marked done or waiting, instead of the small "· mark all seen" link / ✓ icon in the top bar.

- The reply reader has a clear **Open session ↗** button on the right of its footer (above the reply field) that brings the session's terminal forward, besides the small ↗ in the top bar. Claude Desktop sessions keep **Reply in Claude ↗** for that.

- **Close** and **Mark all read** in the "finished" drop-down close the island instead of opening the session panel under the pointer. The panel's and reader's ✕ also no longer re-open it when the island shrinks out from under a still pointer: hover-to-open waits until the pointer actually moves away.

- The near-limit banner is much quieter: it shows once per usage window at 85%, again at 95% and at 100%, instead of at every 5% step and after every restart. It hides itself after 10 seconds, and **Got it** is remembered across restarts until the window resets. **Got it** also closes the island instead of opening the session panel under the pointer.

## 0.8.0

- The collapsed pill shows usage as activity-style rings in tones of the pot's orange instead of a percentage: session (outer), week · all, week per model (inner). Hover the rings for the numbers. The near-limit banner shows the same rings instead of "85% wk".
- The "finished" drop-down has **Mark all read** (clears every done / waiting mark and closes) and **Close** in its bottom row, next to **Read**; the × in the top right is gone.
- Prompts answered somewhere else go away by themselves: a permission, question or plan drop-down closes once the transcript shows Claude got its answer (in the terminal or Claude Desktop) or you typed a new prompt, even when the hook wasn't stopped. A "finished" drop-down closes when the session starts working again, even while the pointer holds it open.

## 0.7.4

- Scrolling the session list no longer opens the chat that ends up under the pointer. After the list scrolls, scrolling only opens a chat once you've moved the pointer onto it, and a row that slides under the pointer mid-scroll never opens. A row also doesn't expand to its full title just because the list scrolled it under the pointer.

## 0.7.3

- Turnipot has an app icon (the turnip in its pot) in Finder, Launchpad, the DMG and Login Items, instead of the generic one. The editor extension (Turnipot Bridge 0.2.1) shows it too in the editor's Extensions list.

## 0.7.2

- Near the limit, the collapsed pill's "91% 5h" no longer has its first digit cut off by the notch: the right wing keeps a little gap from the notch.

## 0.7.1

- Trackpad haptics are quieter: the hover tick now only comes on action buttons (Allow, Deny, question options, prompt buttons), not on session rows, links or the small icons. The open tap, needs-you taps and turn-end burst are unchanged.
- Clicking the "finished" drop-down to open the session now closes the notch, instead of leaving the session list open behind it. The separate "open ↗" label is gone: the whole drop-down is the button.
- The drop-down's **Read** button is bigger and sits at the bottom center with a down arrow, like a handle: it opens the whole reply right there.
- Claude Desktop sessions say why there's no reply field: quick reply works in terminal sessions only (Claude Desktop doesn't accept text from other apps), next to **Reply in Claude ↗**.
- The action buttons in the needs-you drop-downs moved to the right, with the main one last: **Deny · Always allow · Allow**, **Keep planning… · Approve**, **‹ Back · Submit**. **Open session ↗** / **Answer in terminal ↗** moved to the left.
- With no sessions, the idle pill drops the "0" and only sticks out on the turnip's side of the notch.

## 0.7.0

**Usage resets**
- When your 5-hour window or weekly limit resets, the notch drops down to say so ("Session (5h) usage reset"), the bar drains back down, and the turnip gets watered and perks up. It only does this for a window you had used at least half of, and goes away by itself after a few seconds (it stays while the pointer is on it).
- If the reset happened while you were away, it shows as a row in the **While you were away** summary instead, in time order with the sessions that finished.

## 0.6.1

- The near-limit banner stays put while you move the pointer to its **Got it** button, instead of opening the panel underneath. Click the banner itself to open the panel.
- At 100% usage the collapsed pill grows to fit "100% 5h" and its ring, instead of cutting them off at the screen's edge.

## 0.6.0

**Claude Desktop**
- Side sessions sit indented under the session that started them, as in Claude Desktop's sidebar, and Claude Desktop sessions show their sidebar title. Hover a side session to see which session it came from.

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
