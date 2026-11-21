#!/bin/sh
# Install the Turnipot Bridge extension into VS Code-family editors (user runs this).
#
# Usage: scripts/install-extension.sh [--editor codium|code|cursor] [--copy] [--uninstall] [--package]
#
# Default: installs into every supported editor that is installed (VSCodium, VS Code, Cursor).
# Packages vscode-extension/ as a .vsix (plain zip, no npm/vsce needed) into
# build/turnipot-bridge-<version>.vsix and installs it with each editor's CLI
# (`<cli> --install-extension`), which also registers it in the editor's extensions.json.
# --editor X:  only that editor.
# --copy:      just copy the folder into the editor's extensions dir
#              (~/.vscode-oss, ~/.vscode or ~/.cursor; fallback when the CLI isn't available).
# --uninstall: remove the extension.
# --package:   only build build/turnipot-bridge-<version>.vsix and print its path (used by build-app.sh,
#              which bundles it so the app's ⚙ → Install editor extension… can install it).
# Installing (and --uninstall) also removes the extension under its old id
# (local.claude-notch-bridge, from when the app was called "Claude Notch") from each editor,
# including leftover <extensions dir>/local.claude-notch-bridge-* folders.
# Afterwards reload the editor's windows (Cmd+Shift+P -> "Developer: Reload Window").
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vscode-extension"
NAME="turnipot-bridge"
VERSION="$(/usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[\"version\"])" "$SRC/package.json")"
EXT_ID="local.$NAME"
OLD_EXT_ID="local.claude-notch-bridge"   # the extension's id before the rename
MODE=vsix
ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --copy) MODE=copy ;;
    --uninstall) MODE=uninstall ;;
    --package) MODE=package ;;
    --editor) shift; ONLY="${1:-}" ;;
    *) echo "usage: $0 [--editor codium|code|cursor] [--copy] [--uninstall] [--package]" >&2; exit 2 ;;
  esac
  shift
done

# editor id | app name | CLI name | extensions dir
EDITORS="codium|VSCodium|codium|$HOME/.vscode-oss/extensions
code|Visual Studio Code|code|$HOME/.vscode/extensions
cursor|Cursor|cursor|$HOME/.cursor/extensions"

find_cli() { # app name, cli name
  for c in "/Applications/$1.app/Contents/Resources/app/bin/$2" \
           "$HOME/Applications/$1.app/Contents/Resources/app/bin/$2"; do
    if [ -x "$c" ]; then echo "$c"; return 0; fi
  done
  return 1
}

VSIX=""
build_vsix() {
  [ -n "$VSIX" ] && return 0
  # Build a minimal VSIX (zip with [Content_Types].xml + extension.vsixmanifest + extension/).
  BUILD="$ROOT/build"
  STAGE="$(mktemp -d)"
  trap 'rm -rf "$STAGE"' EXIT
  mkdir -p "$STAGE/extension" "$BUILD"
  cp "$SRC/package.json" "$SRC/extension.js" "$STAGE/extension/"
  cat > "$STAGE/[Content_Types].xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension=".json" ContentType="application/json"/>
  <Default Extension=".js" ContentType="application/javascript"/>
  <Default Extension=".vsixmanifest" ContentType="text/xml"/>
</Types>
XML
  cat > "$STAGE/extension.vsixmanifest" <<XML
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
  <Metadata>
      <Identity Language="en-US" Id="$NAME" Version="$VERSION" Publisher="local"/>
      <DisplayName>Turnipot Bridge</DisplayName>
      <Description xml:space="preserve">Lets the Turnipot app focus and type into integrated terminals running Claude Code.</Description>
      <Properties>
        <Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.80.0"/>
        <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="ui,workspace"/>
      </Properties>
  </Metadata>
  <Installation>
      <InstallationTarget Id="Microsoft.VisualStudio.Code"/>
  </Installation>
  <Dependencies/>
  <Assets>
      <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/>
  </Assets>
</PackageManifest>
XML
  VSIX="$BUILD/$NAME-$VERSION.vsix"
  rm -f "$VSIX"
  (cd "$STAGE" && /usr/bin/zip -q -X -r "$VSIX" "[Content_Types].xml" extension.vsixmanifest extension)
  echo "Packaged $VSIX" >&2
}

if [ "$MODE" = package ]; then
  build_vsix
  echo "$VSIX"
  exit 0
fi

echo "$EDITORS" | while IFS='|' read -r ID APP CLINAME EXT_DIR; do
  [ -n "$ONLY" ] && [ "$ONLY" != "$ID" ] && continue
  CLI="$(find_cli "$APP" "$CLINAME" || true)"
  if [ -z "$CLI" ] && [ ! -d "/Applications/$APP.app" ] && [ ! -d "$HOME/Applications/$APP.app" ]; then
    [ -n "$ONLY" ] && echo "$APP is not installed." >&2
    continue
  fi
  # Remove the old-name extension (installed via CLI or copied) so two bridges don't run side by side.
  if [ -n "$CLI" ] && "$CLI" --list-extensions 2>/dev/null | grep -qix "$OLD_EXT_ID"; then
    "$CLI" --uninstall-extension "$OLD_EXT_ID" >/dev/null 2>&1 || true
    echo "Removed old $OLD_EXT_ID from $APP."
  fi
  for old in "$EXT_DIR/$OLD_EXT_ID-"*; do
    [ -e "$old" ] || continue
    rm -rf "$old"
    echo "Removed leftover $old"
  done
  if [ "$MODE" = uninstall ]; then
    [ -n "$CLI" ] && "$CLI" --uninstall-extension "$EXT_ID" >/dev/null 2>&1 || true
    rm -rf "$EXT_DIR/$EXT_ID-"*
    echo "Removed from $APP. Reload its windows."
    continue
  fi
  if [ "$MODE" = copy ] || [ -z "$CLI" ]; then
    DEST="$EXT_DIR/$EXT_ID-$VERSION"
    mkdir -p "$DEST"
    cp "$SRC/package.json" "$SRC/extension.js" "$DEST/"
    echo "Copied extension to $DEST"
  else
    build_vsix
    "$CLI" --install-extension "$VSIX" --force 2>&1 | grep -v -e DeprecationWarning -e trace-deprecation || true
  fi
  echo "Installed into $APP. Reload its windows (Cmd+Shift+P -> Developer: Reload Window)."
done
