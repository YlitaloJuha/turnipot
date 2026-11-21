#!/bin/sh
# Build release binaries and assemble build/Turnipot.app (LSUIElement; ad-hoc signed, or with a
# Developer ID and the hardened runtime when SIGN_IDENTITY is set, as release.sh does).
#   Contents/MacOS/Turnipot   the app
#   Contents/Helpers/turnipot-hook  the Claude Code PermissionRequest hook (see install-hook.sh)
#   Contents/Resources/turnipot-bridge.vsix  the editor extension (⚙ → Install editor extension…)
# The version comes from the VERSION file (CFBundleShortVersionString and CFBundleVersion).
#
# Usage: scripts/build-app.sh [--open]     (--open launches the app afterwards)
#   SIGN_IDENTITY="Developer ID Application: …"  sign for distribution (hardened runtime, secure timestamp)
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/Turnipot.app"
BUNDLE_ID="com.juhaylitalo.turnipot"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
OPEN="${1:-}"
VERSION="$(tr -d ' \n\r\t' < "$ROOT/VERSION")"
case "$VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "VERSION must be MAJOR.MINOR.PATCH (got '$VERSION')" >&2; exit 1 ;;
esac

echo "==> swift build -c release (Turnipot $VERSION)"
swift build -c release --product Turnipot
swift build -c release --product turnipot-hook
BIN="$(swift build -c release --show-bin-path)"

echo "==> assembling $APP"
# Stop a running copy so the binary can be replaced cleanly.
if pgrep -f "$APP/Contents/MacOS/Turnipot" >/dev/null 2>&1; then
  pkill -TERM -f "$APP/Contents/MacOS/Turnipot" || true
  sleep 1
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/Turnipot" "$APP/Contents/MacOS/Turnipot"
cp "$BIN/turnipot-hook" "$APP/Contents/Helpers/turnipot-hook"
chmod 755 "$APP/Contents/MacOS/Turnipot" "$APP/Contents/Helpers/turnipot-hook"
VSIX="$("$ROOT/scripts/install-extension.sh" --package)"
cp "$VSIX" "$APP/Contents/Resources/turnipot-bridge.vsix"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Turnipot</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Turnipot</string>
  <key>CFBundleDisplayName</key><string>Turnipot</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Inside out: the helper first, then the app (no --deep). The app has no entitlements: it sends no
# Apple Events and loads no third-party code, so the hardened runtime needs no exceptions.
if [ -n "$SIGN_IDENTITY" ]; then
  echo "==> codesign ($SIGN_IDENTITY, hardened runtime)"
  set -- --force --options runtime --timestamp --sign "$SIGN_IDENTITY"
else
  echo "==> codesign (ad-hoc)"
  set -- --force --sign -
fi
codesign "$@" --identifier "$BUNDLE_ID.hook" "$APP/Contents/Helpers/turnipot-hook" >/dev/null
codesign "$@" "$APP" >/dev/null
codesign --verify --deep --strict "$APP"

echo "==> built $APP (version $VERSION)"
echo "    hook binary: $APP/Contents/Helpers/turnipot-hook"
echo "    debug:       \"$APP/Contents/MacOS/Turnipot\" --dump"

if [ "$OPEN" = "--open" ]; then
  open "$APP"
fi
