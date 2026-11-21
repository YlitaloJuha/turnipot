# Turnipot — development notes

The detailed reference for building, debugging and understanding Turnipot. The project overview is in the [README](../README.md); the architecture and IPC contracts are in [CONTRACTS.md](../CONTRACTS.md).

Turnipot is an `LSUIElement` app (no Dock icon, no menu bar) for macOS 14 or later. It builds with Swift Package Manager and the Command Line Tools; Xcode is not needed. Targets: `Turnipot` (app), `turnipot-hook` (hook binary), `turnipot-selftest` (tests), `NotchCore` (models, monitors, sockets — the module kept its original name) and `HookOutput` (hook stdout mapping).

## Build

```sh
scripts/build-app.sh          # swift build -c release, then assemble build/Turnipot.app (ad-hoc signed)
SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh   # signed for distribution (hardened runtime)
scripts/build-app.sh --open   # same, then launch the app
```

The bundle contains:

- `Contents/MacOS/Turnipot`: the app.
- `Contents/Helpers/turnipot-hook`: the Claude Code permission hook (Foundation only, starts in milliseconds).
- `Contents/Resources/turnipot-bridge.vsix`: the editor extension (`install-extension.sh --package`), installed by ⚙ → Install editor extension….

Bundle id: `com.juhaylitalo.turnipot` (the hook is signed as `com.juhaylitalo.turnipot.hook`). Before 0.4.0 it was `com.local.turnipot`: on the first launch under the new id Turnipot copies the old settings over once (`LegacyMigration.migrateBundleDomain`; the old domain is left alone). macOS keeps login items per bundle id, so **Launch at login** has to be turned on again after that update. The version comes from the `VERSION` file (CFBundleShortVersionString and CFBundleVersion).

## Install, versions and releases

```sh
scripts/install-app.sh [--no-hook] [--dest DIR]   # build/Turnipot.app -> /Applications (or ~/Applications), relaunch,
                                                  # install-hook.sh --hook <installed app's turnipot-hook>
scripts/release.sh                                # build with your Developer ID, notarize, staple, then
                                                  # build/Turnipot-<version>.dmg (app + Applications
                                                  # shortcut; signed, notarized, stapled) and .zip
                                                  # (ditto -c -k --keepParent), each + .sha256,
                                                  # + release notes from CHANGELOG.md
scripts/release.sh --publish                      # same, then gh release create v<version> (GH_TOKEN from
                                                  # gh auth token --user YlitaloJuha; clean tree, tag must not exist)
```

To release: bump `VERSION`, add a `## <version>` section to `CHANGELOG.md`, commit, run `scripts/release.sh --publish`.

**Signing and notarization.** Releases are signed with a Developer ID Application certificate and notarized by Apple, so they open with a double-click. One-time setup on the release Mac:

1. The Developer ID Application certificate and its private key in the login keychain (`security find-identity -v -p codesigning` lists it). With several, set `SIGN_IDENTITY`.
2. An app-specific password (account.apple.com → Sign-In and Security), then `xcrun notarytool store-credentials turnipot --apple-id <Apple ID> --team-id <team id>`. The password stays in the keychain; `NOTARY_PROFILE` picks another profile name.
3. The current Apple Developer Program License Agreement accepted at developer.apple.com (notarization stops until a new version is accepted).

`release.sh` checks both before building, signs the hook and the app with the hardened runtime and a secure timestamp (no entitlements: Turnipot sends no Apple Events and loads no plug-ins), uploads a zip with `notarytool submit --wait` (usually 1-5 minutes; on a rejection it prints Apple's log), staples the ticket so the app opens offline too, checks it with `spctl --assess`, and only then packages it: a zip, and a disk image (`hdiutil`, UDZO, with an Applications shortcut) that is signed, notarized and stapled too, so it opens without a warning. Two notarization runs, so a release takes a few minutes longer. Local builds stay ad-hoc signed.

**In-app setup (⚙ / right-click menu).**
- *Launch at login*: `SMAppService.mainApp` register / unregister for the bundle as it is now (so install it in /Applications first). `.requiresApproval` opens System Settings › Login Items and explains. The checkmark shows the status (refreshed whenever the pointer enters the island).
- *Install Claude Code hook…*: `HookSettings` (NotchCore) applies exactly the rules of `install-hook.sh` (same entry, replaced turnipot-hook / notch-hook entries, order-preserving JSON written like Python's `json.dumps(indent=2)`; the self-tests compare it byte for byte with `install-hook.sh --dry-run`). It first shows a prompt with what will change, backs up `settings.json` to `settings.json.bak-<date>-<pid>`, then replaces the real file atomically (symlinks kept). If the hook already points at this app it offers *Remove…*. A translocated app (launched from Downloads without moving it) is refused.
- *Install editor extension…*: `EditorExtensions` finds VSCodium / VS Code / Cursor CLIs (`/Applications` and `~/Applications`), removes the old `local.claude-notch-bridge`, runs `--install-extension <bundled vsix> --force`. Editors without a CLI are skipped (`install-extension.sh --copy`).
- *Check for updates* (default on, UserDefaults `checkForUpdates`): at launch and every 24 h one anonymous GET of `https://api.github.com/repos/YlitaloJuha/turnipot/releases/latest` (ephemeral URLSession, no cookies / cache, 10 s timeout, User-Agent `Turnipot/<version>`). `UpdateCheck` (NotchCore) compares semver with the bundle version; drafts, pre-releases and errors (a private repo answers 404) mean "no update". A newer release adds *Update available: vX — Download* (opens the release page; only github.com URLs) and shows a one-time "Turnipot vX is available" drop-down per version (`updateNotifiedVersion`; held back while you're away or something else is showing).

Prompts are confirmations with explanation lines and buttons (`NotchUIState.prompt`); their buttons ignore clicks for 400 ms, and a click elsewhere dismisses them. `--dump` has an `app` object: version, bundle path, inApplications, translocated, loginItem, hookCommands, hookPointsHere, checkForUpdates.

**Upgrading from "Claude Notch".** On its first launch Turnipot removes stale sockets from the old `~/Library/Application Support/ClaudeNotch/` dir. Re-run `scripts/install-hook.sh` (it replaces the old `notch-hook` entry) and `scripts/install-extension.sh` (it uninstalls the old `local.claude-notch-bridge`).

To start the app at login, install it (`scripts/install-app.sh`) and turn on ⚙ → **Launch at login**. To quit, right-click the island and choose **Quit Turnipot**.

## Optional integrations (you install these yourself)

| Script | What it does |
|---|---|
| `scripts/install-hook.sh [--dry-run] [--uninstall]` | Backs up `~/.claude/settings.json`, then adds `turnipot-hook` as a `PermissionRequest` hook (matcher `*`, timeout 600 s). When the app isn't running, the hook exits immediately and Claude shows its normal prompt. **Re-run it once** if you installed it before questions / plans were supported: older installs registered a 90 s timeout, after which Claude Code stops the hook and a question or plan drop-down disappears (you can still answer in the terminal). |
| `scripts/install-extension.sh [--editor codium\|code\|cursor] [--copy] [--uninstall]` | Packs `vscode-extension/` into a small `.vsix` and installs it into every installed VS Code-family editor — VSCodium, VS Code and Cursor (or just the one given with `--editor`). `--copy` copies the folder into the editor's extensions dir instead. The bridge lets the app focus a session's integrated terminal (bringing the right editor forward) and type a reply into it. Reload the editor's windows afterwards. |

Without the hook, sessions, tokens and usage still work, but permission prompts stay in the terminal. Without the extension, clicking a session only brings VSCodium to the front.

## How the hook and the extension work

**Permission hook.** Claude Code runs `turnipot-hook` for every `PermissionRequest`. The hook reads the event JSON from stdin, connects to `~/Library/Application Support/Turnipot/app.sock` and sends one line `{"type":"permission"|"question"|"plan",...}` (`question` = `AskUserQuestion`, `plan` = `ExitPlanMode`). The app shows the "needs you" drop-down and answers `allow`, `deny` or `ask` (optionally with an "Always" rule, an `updatedInput` carrying your answers, a permission mode, or a deny message). The hook prints the matching `hookSpecificOutput` (`behavior: allow/deny`; "Always" adds an allow rule to the project's `.claude/settings.local.json`). On `ask`, a timeout, a missing/stale socket, a malformed reply or any error the hook exits 0 with no output, so Claude simply shows its normal terminal prompt. Permission prompts wait about 55-60 s; questions and plans wait up to about 9½ minutes (565 s in the app, 570 s in the hook, under the installer's 600 s hook timeout). If you answer in the terminal first, the drop-down disappears. Only one app instance runs at a time; a second launch exits without touching the first one's socket. Already-running sessions pick up the hook after `/hooks` or a restart.

**Questions and plans.** Claude Code's docs say a hook may answer these two tools itself: return `allow` *with* `updatedInput` holding the answer ([Tools that require user interaction](https://code.claude.com/docs/en/hooks#allow-with-updatedinput)). For `AskUserQuestion` the hook echoes the original `questions` and adds `answers` (question text → chosen label; multi-select labels joined with ", "; a typed "Other…" answer is the text itself). For `ExitPlanMode`, **Approve** echoes the input (the `plan` and `planFilePath` that Claude Code injects) and adds a `setMode` permission update for this session (`default` = ask before edits; the ▾ menu offers auto-accept edits and auto mode, like the terminal's options); **Keep planning…** denies with your feedback as the message, so Claude stays in plan mode and revises. Exact I/O is in `CONTRACTS.md`.

**VSCodium bridge.** Each VSCodium window running the extension listens on `vscode-<pid>.sock`. The app maps a session to its terminal through the parent shell pid of the `claude` process (that is VS Code's `Terminal.processId`). `{"type":"focus","shellPid":N}` shows that terminal and raises the window (via `codium --reuse-window <folder>`, setting `turnipot.raiseWindowViaCli`); `{"type":"send","shellPid":N,"text":"..."}` types the text plus Enter. The app tries every socket and deletes stale ones.

**Claude Desktop sessions.** Claude Desktop's Code tab runs the same `claude` CLI (bundled under `~/Library/Application Support/Claude/claude-code/<version>/…/claude.app`, launched as `/Applications/Claude.app` → `Contents/Helpers/disclaimer` → `claude --output-format stream-json …`). It writes `~/.claude/sessions/<pid>.json` with `"entrypoint":"claude-desktop"`, so these sessions show up with their title, status, context, subagents and transcript like any other. Each session has a *host*: `terminal` (entrypoint `cli`) or `claudeDesktop` (entrypoint `claude-desktop`; when the entrypoint is missing or unknown, a parent chain that runs through `/Applications/Claude.app` also counts). For Claude Desktop sessions:

- Clicking the row, the finished drop-down, a "While you were away" row, a subagent row or the reader's ↗ runs `open -b com.anthropic.claudefordesktop`, which brings Claude Desktop to the front. No editor socket is contacted. The click marks the session seen. Claude Desktop has no documented deep link to a specific Code session, so you pick the session in its sidebar yourself.
- Quick reply isn't possible because nothing can type into Claude Desktop. The reply slot under the row (↩), the finished drop-down and the reader's footer show **Reply in Claude ↗** instead of the text field, and it activates Claude Desktop. Reading the reply in the notch (scroll down, ≡, Read ›) works normally because it only reads the transcript.
- The row tooltip starts with "Claude Desktop · ~/code/acme-api · context 69k · …", and ↗ says "Show in Claude Desktop".
- Desktop sessions load `~/.claude/settings.json` (`--setting-sources=user,project,local`), so the `PermissionRequest` hook is configured for them as well. They run with `--permission-prompt-tool=stdio` (Claude Desktop answers prompts itself) and, here, `--permission-mode=auto`. Whether the hook fires before Claude Desktop's own prompt hasn't been observed yet. If a request does arrive (permission, question or plan), it is answered from the notch the same way (the answer goes back through the hook), and "Open session ↗" / "Answer in Claude ↗" brings Claude Desktop forward.

## Uninstall

```sh
pkill -f Turnipot.app                   # or right-click the island -> Quit
scripts/install-hook.sh --uninstall        # removes only the turnipot-hook entries (backup is written first)
scripts/install-extension.sh --uninstall
rm -rf build "$HOME/Library/Application Support/Turnipot"
```

Also remove it from Login Items if you added it.

## Privacy

Everything stays on your Mac. The app reads `~/.claude/sessions/*.json` and the session transcripts under `~/.claude/projects/` (read-only), runs your own `claude -p "/usage"` every 2 minutes (no model call), and talks to the hook and the VSCodium extension over Unix sockets with mode 0600. Its only network request is the daily anonymous update check (⚙ → Check for updates turns it off; see above). It reads no keychain items or OAuth tokens, and calls no private endpoints. Note that each `/usage` poll briefly starts a headless Claude process; the app hides it from the session list.

## Using it

| Island state | What it shows |
|---|---|
| Idle | The turnip sinks into its pot and sleeps (only its leaves and closed eyes peek out). The pill is barely wider than the notch and shows the session count. |
| Working | The turnip peeks out of its pot and bobs, leaves swaying. A green dot shows the number of busy sessions, plus your 5-hour usage % and a ring. |
| Session finished | The turnip springs out of its pot with ^^ eyes. The island drops down for about 6 s with the last reply and a quick-reply field. Hovering keeps it open. |
| Needs you | The turnip pops up higher and shakes, with an amber "!". Drops down with **Allow ⌘↩ · Always allow · Deny esc · Open session ↗**. ⌘↩ and esc work while the pointer is over the drop-down — once it has moved onto it, so a drop-down appearing under a resting pointer doesn't arm them (they are never captured from other apps, so a stray ⌘↩ elsewhere can't approve anything). "Always allow" uses the rule Claude itself suggests for the request; without a suggestion it falls back to an exact-match rule for the command (never a guessed prefix), and is hidden for file / web tools whose only fallback would be a blanket rule. |
| Question (`AskUserQuestion`) | Same amber glow and "needs you" mascot. The session's title and "asks you" (or "asks you 3 questions" with a **1/3** step counter), the question's header (amber, "· pick any" for multi-select) and text, then one row per option: its number, a radio / checkbox, the label in bold and the description muted. The last row, **Other…**, opens a text field for your own answer. Several questions are steps: **‹ Back** / **Next › ⌘↩**, and **Submit ⌘↩** on the last one (enabled once every question has an answer). **Answer in terminal ↗ esc** hands the question back to Claude Code and opens the session (Claude Desktop sessions: "Answer in Claude ↗" brings Claude Desktop forward). While the pointer is over the drop-down, **1-9** pick options, ⌘↩ goes on / submits and esc answers in the terminal; while you type in "Other…" the keys go to the field (Return / ⌘↩ go on, esc stops typing). The drop-down is as tall as its content (up to the reader's maximum; the options scroll if needed). |
| Plan (`ExitPlanMode`) | The session's title, "has a plan for you to approve", and the plan rendered like the reply reader (headings, lists, code) in a scroll view up to min(560, 60% of the visible screen height). **Approve ⌘↩** (Claude then asks before edits) with a ▾ menu for *Approve, auto-accept edits* / *Approve, auto mode*; **Keep planning…** opens a field for what should change and sends it back (Claude stays in plan mode); **Open session ↗** (esc while hovering) hands it back to the terminal / Claude Desktop. |
| Near limit (85% or more) | The turnip sinks, its leaves wilt and it sweats, and the ring turns red. A dismissible banner appears. |
| Unseen (finished, not looked at yet) | After a session finishes it stays *unseen* until you click / focus it, quick-reply to it, hover its row in the panel for about a second, click **mark all seen**, or continue it from the terminal (it goes busy again). Sessions that end are dropped; nothing is persisted across restarts. The pill shows a badge after the mascot: a pulsing orange dot + "2 done", or amber "1 waiting" when Claude's last message ends with a question (both: "1 waiting · 1 done"; if that doesn't fit, "2 new" with an amber dot). The busy count stays next to it ("● 1  ● 2 done"); the pill grows to fit (at most 132pt per side). The mascot is happy (^^, the turnip pops a pixel) while something is unseen and nothing is busy or needs you. |
| Hover or click | Expands to show every session and your account usage bars. Click to pin it open. Click elsewhere or press esc to close. **Notch row:** left of the notch "SESSIONS N · mark all seen" and the mascot, which keeps exactly the size and spot it has in the pill, so it doesn't jump when the pill expands. When the pill is at its widest, "mark all seen" turns into a ✓ icon on the right. Right of the notch are only icon buttons: ⓘ (usage data is stale), ✓ (mark all seen, when it doesn't fit on the left), ⚙ (the right-click menu: Update available (when there is one), Keep panel open / Unpin, Trackpad haptics, Launch at login, Check for updates, Install Claude Code hook…, Install editor extension…, Quit), pin, ✕. **Rows:** status dot (green pulsing = working, grey = idle, amber = needs you; there are no status chips), the title (truncates last), agent sprouts, then the session's **current context size** ("84k": input + cache writes + cache reads of the latest main-thread message, so it drops after `/compact`; "—" before the first reply), ≡ read and ↩ quick reply (dimmed until you hover), and rightmost the time since the session's **last interaction**, muted ("now", "3m", "1h 6m", "2d"; the newest of the last assistant message, the last prompt and the session file's status / update time; ticks every 30 s). **Click a row to focus its terminal** (there is no separate ↗ on rows). Unseen sessions float to the top (waiting first, then done, newest first) with an orange / amber edge, a tinted background, the last sentence Claude wrote, and in the time column the time since it finished ("12m") in orange / amber instead of the muted time. **Hover-to-reveal:** rest the pointer on a row for 1.5 s (`ExpandedMetrics.revealDelay`) and its truncated title (and an unseen row's last sentence) wraps onto up to 3 lines; the row grows on the island's spring and shrinks back when the pointer leaves. Sweeping across rows never reveals anything (only the row the pointer rests on). The tooltip has the name, folder, context, cumulative tokens and model. While the panel is open, rows that you've just seen keep their place and size (no jumping under the pointer); they drop back into normal order next time. |
| Reply reader | Read Claude's full replies without leaving the notch. **Open it** by scrolling down over a session row (or ≡ on the row), over the finished drop-down's message (or its **Read ›** link), or over a "While you were away" row (or its ≡). Clicks keep going to the terminal. The island grows to the panel's width and up to 560pt tall (never more than 60% of the screen's visible height). Notch row: **‹ Sessions** and the mascot on the left; the title, ↗ (terminal), ⚙ and ✕ on the right. Under it: "You: <your prompt> · 12:04", then the whole reply rendered from Markdown (headings, **bold** / *italic* / `code` / links, bullet and numbered lists, quotes, fenced code blocks on a dark card, tables as aligned monospaced text) in a scroll view. Text is selectable (⌘C / ⌘A work). A "● working…" row shows while the session is busy. When a new reply lands it appears in place if you're on the newest turn; a new turn opens at its top. Footer: **‹ earlier · 3/7 · later ›** (or ←/→) over the last 10 turns, and the quick-reply field (sending shows "✓ Sent" inline and keeps the reader open so you can read the answer when it arrives). It is pinned, so moving the pointer away doesn't close it. **Close** it with ✕, esc, a click outside the island, or go **back** to the list with ‹ Sessions or by scrolling up past the top of the reply (a new upward scroll that starts at the top). Opening a session's reader marks it seen, and a session that finishes while you read it isn't flagged unseen. The reader takes keyboard focus only while the pointer is over it (or you're typing a reply), so typing elsewhere is never captured. |
| Subagents (expanded panel) | Under each session row, a compact list of its subagents: Agent-tool subagents and workflow runs (`⚙ name · phase · done/total`, with the workflow's running agents nested beneath). Each row shows a status glyph (pulsing orange = running, green ✓ = done, grey – = stalled), the description, the latest action (`Bash: swift build`, `Edit ExpandedView.swift`) and the elapsed time (total duration once done). Running agents and ones that finished or went quiet in the last 10 minutes are shown, at most 4 rows per session plus "+N more". Right after the session title, one tiny pixel sprout per *running* subagent (max 3, then an orange "+N") pulses in a gentle wave (static with Reduce motion). Clicking a subagent row focuses its session's terminal, like clicking the session row; scrolling down over it opens the session's reader. Subagent and workflow rows don't highlight (or tick) on hover. |
| While you were away | You're *away* while the screen is locked, the Mac or its displays are asleep, or there has been no keyboard / mouse input for 3 minutes (idle time is read with `CGEventSource`, no Accessibility permission). Finished drop-downs are held back while you're away (the sessions just stay unseen); permission prompts still drop down as usual. When you come back (unlock, wake, first input after idling), if anything finished, asked for permission, asked a question or presented a plan meanwhile, one **While you were away** drop-down lists it: dot, title, "finished 12m ago" / "asked you something", and **open ↗** (focuses the session and marks it seen). At most 4 rows, then "+N more" (opens the panel). The strip shows how long you were away. It never times out: it closes when you hover it and then move away, click elsewhere (after a 1.5 s grace period), press esc while hovering it, or click ✕. Permission prompts, questions and plans take priority over it. |
| × button (expanded panel) | Closes the panel even when it's pinned (like esc). Hovering won't re-open it until the pointer has left the island once. |

At launch the island springs sideways out of the physical notch and the turnip then rises out of its pot; on quit, or when the notch moves to another display, it sinks back in first and the island folds back into the notch. Drop-downs grow out of the notch and fold back up when dismissed. Mood changes slide the turnip up or down with a spring. With System Settings → Accessibility → Display → Reduce motion on, these become plain fades and the mascot does not bob or shake.

The island never takes keyboard focus, with two exceptions: when you click into a reply field, and while the pointer is over an open reply reader (for selection, ⌘C, ←/→ and esc).

**How scrolling chooses between the list and the reader.** In the expanded panel, scrolling down over a row opens that session's reader only when the session list can't scroll (everything fits), or when the scroll gesture *started* with the list already at its bottom. Over a row's reply snippet (the second line of an unseen row) or its ≡ button, scrolling always opens the reader. Any other scroll just scrolls the list, and a gesture that scrolled the list never turns into "open reader" partway through. A gesture needs about 24pt of travel. Inertial (momentum) scrolling never opens or closes anything. In the reader, only an upward gesture that *starts* with the reply already at its top and then pulls about 60pt further up (while still at the top) goes back to the list; "‹ Sessions" fades in at the top while you pull. A gesture that scrolled the reply (down, or up from further down) never goes back, even once it reaches the top, and gestures that start over the reply field are ignored. "At the top" is read from the reader's `NSScrollView` clip view (`contentView.bounds.origin.y`, flipped) when the gesture begins: a SwiftUI `GeometryReader` preference inside a macOS `ScrollView` is *not* updated by scrolling, which is why the old check always thought the reply was at its top (`OverscrollBackGesture` in NotchCore, self-tested). The list's "at its bottom" check reads its `NSScrollView` the same way.

**Safety guards.** (1) *No quick reply into a terminal dialog.* When a permission / question / plan goes back to the terminal (timeout, Open session, Answer in terminal, the hook disconnecting, or a question / plan the notch can't show), Claude's own dialog may be up there and a reply's Enter would pick its highlighted option. `TerminalDialogGuard` (NotchCore) flags the session until the transcript shows progress after the request (a main-chain assistant message or tool_result newer than it), the session goes idle → busy → idle, or 2 minutes after you focused its terminal; a session that ends drops its flag. While flagged, the row's ↩ is dimmed and opens nothing, the reply fields (finished drop-down, reader footer, row) are disabled with "Claude is showing a prompt in the terminal — answer it there", `AppState.sendReply` refuses and `TerminalBridge.send` refuses through the shared `TerminalSendGate`. (2) *No clicks on a drop-down that just appeared.* `FreshContentGate`: the action buttons of a permission / question / plan drop-down (and its hot keys) do nothing within 400 ms of it appearing or of the queue advancing to the next request; the hot keys additionally re-arm only after the pointer moves (`HotKeyGate`, keyed by the request).

**Quick-reply field.** The reply field (session row ↩, finished drop-down, reader footer) wraps: it grows from 1 to 5 lines and then scrolls inside, and the island grows with it. Return sends; ⇧↩ or ⌥↩ adds a line (the editor extension still sends the lines joined by spaces, since a newline would submit in Claude Code's prompt; the field's tooltip says so). The text area sits beside the fixed-width Send button, never under it. It is an `NSTextView` (`ReplyTextView`), so ⌘C / ⌘V / ⌘A / ⌘X / ⌘Z (routed by the key monitor) and undo work; its height is reported into `NotchUIState.replyFieldExtra[slot]`, which the reader / row / finished heights add.

## The mascot

The turnip in its little orange pot is Turnipot's only mascot.

| Island state | Turnip |
|---|---|
| Idle | Sunk into the pot: only the leaves and closed eyes peek out, slow breathing, a drifting "z" |
| Working | Peeks out of the pot, bobs, leaves sway, blinks |
| Session finished | ^^ eyes, smile, sparkles. In the drop-down it springs right out of the pot, twists in the air with flapping leaves and lands with a squash (shortly after the drop-down opens, then every 4 s); in the pill it pops up a pixel |
| Needs you | Pops up higher, shakes, tall eyes and an "o" mouth, twinkling amber "!" |
| Near limit | Sinks lower, leaves wilt yellow, sweat drop |

The turnip sits inside its pot: the pot's front covers the buried part, and mood changes slide it up or down relative to the rim with a spring. At launch the pot pops in and the turnip rises out of the soil; on quit it sinks back in and the pot fades. In the finished drop-down it has a taller stage at the bottom left (the text moves right of it), so the whole jump stays inside the island.

Its leaves shift very slightly from fresh green towards olive as your weekly usage rises (fresh up to 30%, olive at 85%). With Reduce motion on it doesn't loop and changes are plain fades.

Before 0.4.0 there were two more mascots (Sprout and the Peeker) and a Mascot menu; a stored `mascot` setting is removed at launch.

## Trackpad haptics

On a Force Touch trackpad Turnipot taps back (`NSHapticFeedbackManager.defaultPerformer`, patterns `.alignment` / `.levelChange` / `.generic`). The trackpad only plays a tap while a finger is resting on it, so you feel these mostly while your hand is on the trackpad. Toggle it with ⚙ or the right-click menu → **Trackpad haptics** (checkmark = on). It is on by default, saved in UserDefaults, and Reduce motion doesn't change it:

```sh
defaults write com.juhaylitalo.turnipot haptics -bool false   # off (relaunch); delete the key for the default (on)
```

| When | What you feel |
|---|---|
| The pointer moves onto a session row or any button in the island (pin, ✕, ⚙, ≡, ↩, ↗, Allow / Deny / Always, question options, Approve ▾, Send, …) | One light `.alignment` tick. Ticks are at least 60 ms apart, 150 ms apart while you sweep across targets (a new target less than 120 ms after the previous one), never twice in a row for the same target (until the pointer leaves the island), and paused while one of the sequences below plays. |
| The panel, the reader, "While you were away" or the near-limit banner springs open out of the pill | One soft `.levelChange`. Nothing on close. |
| A permission, question or plan drop-down appears | Two firm `.levelChange` taps 120 ms apart (once per request). |
| A turn ends: the finished drop-down plays (or, with the reader open, the strip mascot hops) | Three taps in time with the mascot's **first** jump only (not the repeats): `.generic` as it launches, `.alignment` at the top, `.levelChange` as it lands. Cancelled if the drop-down closes first. |

The burst timings are derived from the same keyframes the views animate (`HapticBursts` in `NotchCore/Haptics.swift`), so retiming an animation retimes its taps:

| Where | launch `.generic` | top `.alignment` | land `.levelChange` | from |
|---|---|---|---|---|
| Turnip, finished drop-down (stage spring) | 0.492 s | 1.116 s | 1.692 s | `springDelay` 0.3 + `springKeyframes` 0.08 / 0.34 / 0.58 × `springDuration` 2.4 |
| Turnip, strip (pill / panel / reader pop) | 0.192 s | 0.528 s | 1.392 s | `hopKeyframes` 0.08 / 0.22 / 0.58 × `hopDuration` 2.4 |

Launch = the crouch keyframe the mascot springs up from, top = the first keyframe at its highest point, land = the first keyframe back on the rim after that.

**Background app.** Turnipot is an `LSUIElement` app with a non-activating panel, so it is almost never the active app. AppKit's headers only say the system may suppress a request (for example when no finger is on the trackpad); they don't mention app activation. Observed on macOS 27 with a windowless, never-activated accessory process: `defaultPerformer` is an `NSTrackpadHapticFeedbackPerformer`, and each `perform(_:performanceTime: .now)` makes WindowServer set `AppKitActuateWithID` on the trackpad's HID services within about a millisecond, with no mouse interaction and another app frontmost. So the event-driven taps (finished, needs you) should play while you work in another app, as long as a finger is on the trackpad. You can't verify that by feel from the logs, though. If they turn out to be felt only while hovering the notch, that's the system's choice: Turnipot never activates itself or takes focus to get a tap through. Two more observations: `.drawCompleted` requests from that process never reached WindowServer (there was no drawing pass to wait for), so Turnipot always uses `.now`. And all three patterns logged the same actuation id (15) there, so on some trackpads they may feel alike; the bursts still differ in rhythm.

`TURNIPOT_HAPTICS_LOG=1 build/Turnipot.app/Contents/MacOS/Turnipot` logs every tap Turnipot performs (pattern + reason) with NSLog.

## Debugging and renders

```sh
.build/debug/Turnipot --dump [--no-usage]   # print live sessions, tokens and usage as JSON, then exit
                                               # (each session also gets lastSentence + unseenKind done|waiting,
                                               #  host terminal|claudeDesktop, entrypoint, focus, quickReply)
.build/debug/Turnipot --dump-replies=<sessionId>  # the reply reader's turns for a session (prompt, times,
                                               # length, first / last characters) + bytes scanned and timing
.build/debug/Turnipot --demo=<state>        # show the UI with fake data and no monitors or sockets
                                               # states: idle | working | finished | permission | nearlimit | expanded
                                               #   | unseen | unseen-working | unseen-mixed | expanded-unseen | away
                                               #   | reader | reader-working | finished-desktop | reader-desktop
                                               #   | question | question-single | plan
                                               # (expanded includes a Claude Desktop session; --render also writes
                                               #  expanded-desktop = its ↩ slot with "Reply in Claude ↗",
                                               #  question-multi = step 2/2 multi-select + "Other…",
                                               #  plan-feedback = "Keep planning…" open,
                                               #  reader-reply / expanded-reply / finished-reply = long multi-line
                                               #  reply drafts, expanded-reveal / expanded-unseen-reveal = a
                                               #  hover-revealed row, prompt-hook / update-notice = setup
                                               #  prompts, finished-dialog = quick reply paused because
                                               #  Claude may be showing a prompt in the terminal)
.build/debug/Turnipot --render=<dir>        # render every state to PNGs offscreen (no screen-recording permission)
                                               # plus <dir>/anim/<sequence>-<progress>.png animation frames
                                               # (launch, quit, expand, collapse, permission, permission-dismiss, finished, reader;
                                               #  Turnip adds spring = the finished spring-out, hop = the pill's pop)
.build/debug/Turnipot --export-media=docs/media   # marketing GIFs + PNG stills from the demo data (see below)
swift run turnipot-selftest                       # unit checks for NotchCore (`swift test` needs XCTest, which
                                               # Command Line Tools lack; TURNIPOT_LIVE=1 adds checks on real data)
```

Runtime files are kept in `~/Library/Application Support/Turnipot/`. `app.sock` is the hook socket. Each VSCodium window has its own `vscode-<pid>.sock`.

Subagents are read from `~/.claude/projects/<encoded-cwd>/<sessionId>/subagents/` (`agent-<id>.jsonl` + `.meta.json`, and `workflows/wf_<runId>/` with its `journal.jsonl`; the workflow name comes from `<sessionId>/workflows/scripts/<name>-wf_<runId>.js`). Only the last 48 KB of each agent transcript is parsed, and unchanged files are served from a cache. An agent is *done* when its meta has `"finished": true` (workflow agents: when the journal has their result), *running* when its transcript changed in the last 5 minutes, and *stalled* otherwise. `--dump` lists every subagent with its status and a `visible` flag, including the ones the panel hides.

The number on each session row is the session's **current context**: input + cache writes + cache reads of the newest main-thread assistant message, in file order. Subagent (sidechain) and synthetic messages are ignored. After a compaction, Claude Code keeps writing to the same transcript and session id: it appends a `{"type":"system","subtype":"compact_boundary","compactMetadata":{"postTokens":N}}` line and an `isCompactSummary` user message. The row drops to `postTokens` right away, then follows the next reply (on this machine a real auto-compaction went from 232k to 69k). The row tooltip still shows cumulative tokens (input + cache writes + output, without cache reads, which would dwarf everything else). `--dump` prints the full breakdown plus `contextDisplay`.

The reply reader reads transcripts **backwards** from the end in 256 KB chunks until it has 10 turns with text (lines split across chunks are carried over; it gives up after 32 MB). The result is cached by inode, size and mtime, and refreshed incrementally (only the appended bytes) while the reader is open, polling once a second. A *turn* runs from a real prompt to the next one. Tool results, `isMeta` lines, compact summaries, task notifications (`origin.kind != "human"`), slash-command output, `!` bash echoes, "[Request interrupted…]" and lines that are only `<system-reminder>` / `<ide_opened_file>` context are not prompts; such context is also stripped from real prompts. Thinking, tool use, subagent and `<synthetic>` messages add no text. Turns without text (e.g. `/rename`) are hidden, except an in-progress newest turn.

Offscreen renders (`--render`) can't draw AppKit-backed views, so the reader's scroll view, the reply text field and the ⚙ menu fall back to static stand-ins there. The panel is now 600pt tall (it was 480) to fit the reader; renders are 1352x1200.

## Brand assets

`docs/brand/` holds the README banner (`banner.svg` light, `banner-dark.svg` dark) and the mark (`mark.svg`, `mark-512.png`: the turnip in its pot on a black tile). `python3 scripts/brand-assets.py docs/brand` writes the SVGs; the pixel art copies `TurnipRig`'s grids and colours, so update both together. The panel and drop-down in the banner are drawn, not rendered, with demo data only.

## Exporting the README media

```sh
scripts/build-app.sh
build/Turnipot.app/Contents/MacOS/Turnipot --export-media=docs/media [--fps=25] [--only=hero,reader]
```

Renders offscreen (no window, no screen recording permission) from the made-up demo data in `DemoMode.swift` (`MediaExport.swift`). Every image is framed on a dark wallpaper strip with a menu bar and the physical notch, at 2x. The animations use the island's real springs and timings (`IslandMotion`), like `--render`'s anim/ frames; a drawn pointer shows hovering / scrolling / clicking. GIFs loop forever; identical consecutive frames are merged.

| File | What |
|---|---|
| `hero.gif` | launch out of the notch (the turnip rises out of its pot), hover-expand into the panel, collapse |
| `finished.gif` | a session finishes: drop-down + the turnip's spring out of the pot |
| `permission.gif` | permission drop-down, pointer on **Allow**, back to the pill |
| `reader.gif` | panel → scroll over a row → reply reader → scroll through the reply |
| `expanded.png`, `question.png`, `plan.png`, `away.png` | stills of those states |
| `mascots.png` | the turnip in every mood |
| `pills.png` | idle / working / "2 done" pills |
