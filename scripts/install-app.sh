#!/bin/sh
# Install build/Turnipot.app into /Applications (or ~/Applications if /Applications isn't writable),
# quit the running copy, launch the installed one, and point the Claude Code hook at the installed
# app's turnipot-hook so the hook path stays valid. Run ONLY by the user.
#
# Usage: scripts/install-app.sh [--no-hook] [--dest DIR]
#
#   --no-hook   don't touch ~/.claude/settings.json (default: re-run install-hook.sh --hook <installed hook>,
#               which backs up settings.json first and replaces only Turnipot's own entry)
#   --dest DIR  install into DIR instead of /Applications / ~/Applications
#
# Build first with scripts/build-app.sh. Afterwards "Launch at login" (⚙ menu) registers the
# installed copy; if you turned it on for build/Turnipot.app before, turn it off and on again.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/Turnipot.app"
DEST=""
HOOK=1

while [ $# -gt 0 ]; do
  case "$1" in
    --no-hook) HOOK=0 ;;
    --dest) shift; DEST="$1" ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ ! -d "$SRC" ]; then
  echo "$SRC not found. Run scripts/build-app.sh first." >&2
  exit 1
fi

if [ -z "$DEST" ]; then
  if [ -w /Applications ]; then DEST=/Applications; else DEST="$HOME/Applications"; fi
fi
mkdir -p "$DEST"
TARGET="$DEST/Turnipot.app"

echo "==> quitting running Turnipot"
if pgrep -f "Turnipot.app/Contents/MacOS/Turnipot" >/dev/null 2>&1; then
  pkill -TERM -f "Turnipot.app/Contents/MacOS/Turnipot" || true
  # The island retracts before quitting (up to ~1 s).
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "Turnipot.app/Contents/MacOS/Turnipot" >/dev/null 2>&1 || break
    sleep 0.3
  done
fi

echo "==> installing $TARGET"
STAGE="$DEST/.Turnipot.app.installing-$$"
rm -rf "$STAGE"
ditto "$SRC" "$STAGE"
rm -rf "$TARGET"
mv "$STAGE" "$TARGET"
# A locally built app has no quarantine flag; clear it anyway in case the source was downloaded.
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

if [ "$HOOK" -eq 1 ]; then
  echo "==> pointing the Claude Code hook at the installed app"
  "$ROOT/scripts/install-hook.sh" --hook "$TARGET/Contents/Helpers/turnipot-hook"
fi

echo "==> launching $TARGET"
open "$TARGET"
echo "Done. Turnipot $(defaults read "$TARGET/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '') runs from $TARGET."
echo "You can delete build/Turnipot.app; ⚙ → Launch at login starts the installed copy at login."
