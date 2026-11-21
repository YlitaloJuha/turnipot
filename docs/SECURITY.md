# Security

Turnipot can answer Claude Code for you: it allows or denies tool calls, answers questions, approves plans and types replies into terminals. Please report security problems privately.

## Reporting

- Don't open a public issue.
- Use GitHub's private vulnerability reporting for this repository (Security → Report a vulnerability), or contact the owner, @YlitaloJuha, directly.
- Say what you found, how to reproduce it, and which version (⚙ menu, or `Turnipot --dump`).

## Supported versions

The latest release, and the latest commit on `main`. Fixes ship as a new release; Turnipot's update check tells you about it.

## What Turnipot does to stay safe

- **Nothing leaves your Mac.** The only network request is the update check: an anonymous `GET` of the latest GitHub release, once at launch and once a day, which you can turn off. No telemetry, no analytics, and no keychain items or OAuth tokens are read.
- **Local sockets only.** The hook and the editor extension talk to the app over Unix sockets in `~/Library/Application Support/Turnipot/`, readable and writable by your user only (mode 0600). Nothing listens on the network.
- **The hook fails closed to the terminal.** If the app isn't running, doesn't answer in time, or replies with anything it can't parse, `turnipot-hook` prints nothing and Claude Code shows its normal terminal prompt. It never allows anything by default.
- **No accidental approvals.** A new drop-down ignores clicks and keys for 400 ms, so a click meant for something else can't approve it, and its hot keys (⌘↩ / esc) work only after the pointer has moved onto it. "Always allow" adds Claude's own suggested rule, never a guessed wider one.
- **No typing into a prompt.** Quick reply is paused for a session while Claude may be showing its own prompt in that terminal, so your Enter can't pick one of its options.
- **Your settings file is backed up.** Installing or removing the hook shows what will change in `~/.claude/settings.json`, writes a backup first, and replaces the file atomically.
- **Signed and notarized.** Releases are signed with a Developer ID, use the hardened runtime with no entitlements, and are notarized by Apple. Each release lists the zip's SHA-256.

## What you trust

- **The notch speaks for you.** Whatever you allow, approve or send from the notch is the same as doing it in the terminal. Read the request first.
- **The editor extension types into terminals.** The app sends it a terminal's shell process id and the text to type. Any process running as your user can reach the same socket, as it could reach your terminal anyway.
- **Claude Code's files.** Turnipot reads `~/.claude` (sessions and transcripts) read-only, and runs your own `claude -p "/usage"` every two minutes for the usage numbers.
