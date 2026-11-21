#!/bin/sh
# Register turnipot-hook as a Claude Code PermissionRequest hook in ~/.claude/settings.json.
# Run ONLY by the user. Backs up settings.json first; merges (does not overwrite) existing hooks.
#
# Usage:
#   scripts/install-hook.sh [--dry-run] [--uninstall] [--hook PATH] [--settings PATH]
#
#   --hook PATH      turnipot-hook binary to register. Default: build/Turnipot.app/Contents/Helpers/turnipot-hook
#                    (from scripts/build-app.sh), else .build/release/turnipot-hook.
#   --dry-run        print the resulting settings.json to stdout, change nothing.
#   --uninstall      remove our entries (turnipot-hook, and the old notch-hook) instead of adding one.
#   --settings PATH  settings file to edit (default ~/.claude/settings.json).
#
# Resulting entry (matcher "*" = every tool, including AskUserQuestion / ExitPlanMode; timeout 600s >
# the hook's own waits: 60s for permission prompts, 570s for questions / plans):
#   "hooks": { "PermissionRequest": [ { "matcher": "*",
#       "hooks": [ { "type": "command", "command": "'/path/to/turnipot-hook'", "timeout": 600 } ] } ] }
#
# Idempotent: any existing PermissionRequest entry whose executable is named turnipot-hook, or the hook from
# before the rename (notch-hook, from claude-notch / ClaudeNotch.app), is replaced by the new one.
# The default hook path is computed from this script's location, so the repo folder can be anywhere.
#
# Safety: when the app isn't running the hook exits 0 immediately with no output, so Claude Code
# shows its normal permission prompt.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="${HOME}/.claude/settings.json"
HOOK=""
DRY_RUN=0
UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --hook) shift; HOOK="$1" ;;
    --settings) shift; SETTINGS="$1" ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$UNINSTALL" -eq 0 ]; then
  if [ -z "$HOOK" ]; then
    for c in "$ROOT/build/Turnipot.app/Contents/Helpers/turnipot-hook" "$ROOT/.build/release/turnipot-hook"; do
      if [ -x "$c" ]; then HOOK="$c"; break; fi
    done
  fi
  if [ -z "$HOOK" ] || [ ! -x "$HOOK" ]; then
    echo "turnipot-hook binary not found. Run scripts/build-app.sh first or pass --hook PATH." >&2
    exit 1
  fi
  HOOK="$(cd "$(dirname "$HOOK")" && pwd)/$(basename "$HOOK")"
fi

PY=/usr/bin/python3
[ -x "$PY" ] || PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then echo "python3 is required for the JSON merge." >&2; exit 1; fi

if [ "$DRY_RUN" -eq 0 ] && [ -f "$SETTINGS" ]; then
  BACKUP="$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)-$$"
  cp -p "$SETTINGS" "$BACKUP"
  echo "Backed up $SETTINGS -> $BACKUP" >&2
fi

"$PY" -I - "$SETTINGS" "$HOOK" "$DRY_RUN" "$UNINSTALL" <<'PYEOF'
import json, os, shlex, sys, tempfile

settings_path, hook, dry_run, uninstall = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4] == "1"
# Follow a symlinked settings.json (dotfiles repos) so os.replace() edits the real file.
settings_path = os.path.realpath(settings_path)

data = {}
if os.path.exists(settings_path):
    with open(settings_path, encoding="utf-8") as f:
        text = f.read()
    if text.strip():
        data = json.loads(text)
if not isinstance(data, dict):
    sys.exit("settings.json is not a JSON object; aborting")

hooks = data.setdefault("hooks", {})
groups = hooks.get("PermissionRequest", [])

# Our hook under its current name, and under the app's old name ("Claude Notch"):
# .../ClaudeNotch.app/Contents/Helpers/notch-hook, .../claude-notch/.build/release/notch-hook.
# Matched on the executable's file name only, so an unrelated hook that merely lives in a
# folder called e.g. "claude-notch-sounds" is never removed.
OURS = ("turnipot-hook", "notch-hook")

def is_ours(h):
    if not isinstance(h, dict):
        return False
    cmd = str(h.get("command", "")).strip()
    try:
        argv = shlex.split(cmd)
    except ValueError:
        argv = cmd.split()
    return bool(argv) and os.path.basename(argv[0]) in OURS

removed = 0
for g in groups:
    if isinstance(g, dict):
        removed += sum(1 for h in g.get("hooks", []) if is_ours(h))
if removed:
    print(f"Replacing/removing {removed} existing Turnipot (or old Claude Notch) hook entr{'y' if removed == 1 else 'ies'}", file=sys.stderr)

# Drop previous handlers (idempotent), keep everything else.
cleaned = []
for g in groups:
    if not isinstance(g, dict):
        cleaned.append(g); continue
    inner = [h for h in g.get("hooks", []) if not is_ours(h)]
    if inner:
        g = dict(g); g["hooks"] = inner; cleaned.append(g)
    elif not g.get("hooks"):
        cleaned.append(g)

if not uninstall:
    cleaned.append({
        "matcher": "*",
        "hooks": [{"type": "command", "command": shlex.quote(hook), "timeout": 600}],
    })

if cleaned:
    hooks["PermissionRequest"] = cleaned
else:
    hooks.pop("PermissionRequest", None)
if not hooks:
    data.pop("hooks", None)

out = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
if dry_run:
    sys.stdout.write(out)
    sys.exit(0)

d = os.path.dirname(settings_path) or "."
os.makedirs(d, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=d, prefix=".settings.", suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write(out)
if os.path.exists(settings_path):
    os.chmod(tmp, os.stat(settings_path).st_mode & 0o777)
os.replace(tmp, settings_path)
print(("Removed Turnipot hook entries from " if uninstall else "Registered PermissionRequest hook in ") + settings_path, file=sys.stderr)
PYEOF

if [ "$DRY_RUN" -eq 0 ]; then
  echo "Done. New Claude Code sessions pick this up; running sessions may need /hooks or a restart." >&2
fi
