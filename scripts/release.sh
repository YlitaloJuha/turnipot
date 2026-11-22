#!/bin/sh
# Package a release: build Turnipot.app signed with your Developer ID, have Apple notarize it,
# staple the ticket, then make a zip and a signed, notarized disk image, each with its SHA-256.
#
# Usage: scripts/release.sh [--publish]
#
#   build/Turnipot-<version>.dmg         Turnipot.app + an Applications shortcut (signed, notarized, stapled)
#   build/Turnipot-<version>.dmg.sha256  "<sha256>  Turnipot-<version>.dmg"
#   build/Turnipot-<version>.zip         Turnipot.app (ditto -c -k --keepParent)
#   build/Turnipot-<version>.zip.sha256  "<sha256>  Turnipot-<version>.zip"
#   build/turnipot-bridge-<ext>.vsix     the editor extension, as bundled in the app (<ext> = its own version)
#   build/release-notes-<version>.md     install steps + the "## <version>" section of CHANGELOG.md
#
#   --publish  also create the GitHub release v<version> (YlitaloJuha/turnipot) with the dmg, the zip,
#              their checksums and the .vsix attached and the release notes above. Needs gh logged in as YlitaloJuha;
#              refuses if the tag already exists or the working tree has uncommitted changes.
#
# The version comes from the VERSION file.
#
# Signing and notarization (one-time setup):
#   - a "Developer ID Application" certificate in the login keychain (Xcode → Settings → Accounts, or
#     developer.apple.com → Certificates); SIGN_IDENTITY picks one if there are several
#   - notarytool credentials saved under the profile name "turnipot" (NOTARY_PROFILE overrides it):
#       xcrun notarytool store-credentials turnipot --apple-id <Apple ID> --team-id <team id>
#     (asks for an app-specific password from account.apple.com; kept in the keychain, never here)
#   - the current Apple Developer Program License Agreement accepted at developer.apple.com
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REPO="YlitaloJuha/turnipot"
PUBLISH=0
case "${1:-}" in
  --publish) PUBLISH=1 ;;
  "") ;;
  *) echo "usage: $0 [--publish]" >&2; exit 2 ;;
esac

VERSION="$(tr -d ' \n\r\t' < VERSION)"
TAG="v$VERSION"
ZIP="build/Turnipot-$VERSION.zip"
NOTES="build/release-notes-$VERSION.md"

# Release notes: the CHANGELOG section "## <version>" (up to the next "## ").
awk -v v="$VERSION" '
  /^## / { if (found) exit; if ($2 == v || $2 == "[" v "]") { found = 1; next } }
  found { print }
' CHANGELOG.md | sed -e '/./,$!d' > "$NOTES.tmp" || true
if [ ! -s "$NOTES.tmp" ]; then
  rm -f "$NOTES.tmp"
  echo "CHANGELOG.md has no '## $VERSION' section." >&2
  exit 1
fi
mkdir -p build
EXT_VERSION="$(/usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['version'])" vscode-extension/package.json)"
VSIX="build/turnipot-bridge-$EXT_VERSION.vsix"
# Install steps first (people often land on the release page from a link), then the changelog.
{
  cat <<EOF_NOTES
**Install**
1. Download \`Turnipot-$VERSION.dmg\` below, open it and drag **Turnipot** onto **Applications**, then open it from Applications. It lives in the notch (no Dock icon).
2. Hover the notch, click ⚙ (or right-click the notch) and choose **Install Claude Code hook…** to answer permissions, questions and plans from the notch, and **Install editor extension…** for jump-to-terminal and quick replies in VSCodium, VS Code or Cursor (reload the editor windows afterwards). Sessions in Terminal and iTerm2 need no extension: the first time you click one, macOS asks whether Turnipot may control that app. Turn on **Launch at login** there too.
3. If the app can't install the editor extension (it looks for the editor in /Applications or ~/Applications), download \`turnipot-bridge-$EXT_VERSION.vsix\` below and in the editor choose Extensions → ⋯ → **Install from VSIX…**.

More in the [README](https://github.com/$REPO#install).

---

EOF_NOTES
  cat "$NOTES.tmp"
} > "$NOTES"
rm -f "$NOTES.tmp"

if [ "$PUBLISH" -eq 1 ] && [ -n "$(git status --porcelain)" ]; then
  echo "Uncommitted changes; commit before publishing." >&2
  exit 1
fi

NOTARY_PROFILE="${NOTARY_PROFILE:-turnipot}"
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -n 1)"
fi
if [ -z "$SIGN_IDENTITY" ]; then
  echo "No Developer ID Application certificate in the keychain (see the setup notes at the top)." >&2
  exit 1
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "notarytool can't use the keychain profile '$NOTARY_PROFILE'. Save it once with:" >&2
  echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <Apple ID> --team-id <team id>" >&2
  echo "(or accept the latest agreement at developer.apple.com if the profile exists)." >&2
  exit 1
fi

echo "==> building Turnipot $VERSION ($SIGN_IDENTITY)"
SIGN_IDENTITY="$SIGN_IDENTITY" scripts/build-app.sh

APP="build/Turnipot.app"
BUILT="$(defaults read "$ROOT/$APP/Contents/Info" CFBundleShortVersionString)"
if [ "$BUILT" != "$VERSION" ]; then
  echo "Built app says $BUILT, VERSION says $VERSION." >&2
  exit 1
fi
codesign --verify --deep --strict "$APP"
if ! cmp -s "$VSIX" "$APP/Contents/Resources/turnipot-bridge.vsix"; then
  echo "$VSIX differs from the extension bundled in the app." >&2
  exit 1
fi
for bin in "$APP" "$APP/Contents/Helpers/turnipot-hook"; do
  if ! codesign -dv "$bin" 2>&1 | grep -q 'flags=.*runtime'; then
    echo "$bin is not signed with the hardened runtime." >&2
    exit 1
  fi
done

# Upload a file to Apple's notary service and wait; on a rejection print Apple's log and stop.
notarize() {
  RESULT="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)" || true
  STATUS="$(printf '%s' "$RESULT" | /usr/bin/plutil -extract status raw -o - - 2>/dev/null || true)"
  SUBMISSION="$(printf '%s' "$RESULT" | /usr/bin/plutil -extract id raw -o - - 2>/dev/null || true)"
  if [ "$STATUS" != "Accepted" ]; then
    echo "Notarization of $1 failed (status: ${STATUS:-unknown})." >&2
    printf '%s\n' "$RESULT" >&2
    if [ -n "$SUBMISSION" ]; then
      xcrun notarytool log "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fi
    exit 1
  fi
  echo "    accepted ($SUBMISSION)"
}

echo "==> notarizing the app (usually a few minutes)"
UPLOAD="build/Turnipot-$VERSION-notarize.zip"
rm -f "$UPLOAD"
ditto -c -k --keepParent "$APP" "$UPLOAD"
notarize "$UPLOAD"
rm -f "$UPLOAD"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "==> zipping $ZIP"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd build && shasum -a 256 "Turnipot-$VERSION.zip" > "Turnipot-$VERSION.zip.sha256")
echo "    $(cat "$ZIP.sha256")"
echo "    size: $(du -h "$ZIP" | cut -f1)"

# Disk image: the stapled app beside an Applications shortcut, signed, notarized and stapled itself.
DMG="build/Turnipot-$VERSION.dmg"
echo "==> disk image $DMG"
STAGE="build/dmg-stage"
rm -rf "$STAGE" "$DMG" "$DMG.sha256"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Turnipot.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Turnipot $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
echo "==> notarizing the disk image"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
(cd build && shasum -a 256 "Turnipot-$VERSION.dmg" > "Turnipot-$VERSION.dmg.sha256")
echo "    $(cat "$DMG.sha256")"
echo "    size: $(du -h "$DMG" | cut -f1)"
echo "    extension: $VSIX"
echo "    notes: $NOTES"

if [ "$PUBLISH" -eq 0 ]; then
  echo "Dry run: not published (pass --publish to create the GitHub release $TAG)."
  exit 0
fi

echo "==> publishing $TAG to $REPO"
GH_TOKEN="$(gh auth token --user YlitaloJuha)"
export GH_TOKEN
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG already exists." >&2
  exit 1
fi
gh release create "$TAG" "$DMG" "$DMG.sha256" "$ZIP" "$ZIP.sha256" "$VSIX" \
  --repo "$REPO" --title "Turnipot $VERSION" --notes-file "$NOTES" --target "$(git rev-parse HEAD)"
echo "Published https://github.com/$REPO/releases/tag/$TAG"
