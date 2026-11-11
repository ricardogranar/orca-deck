#!/usr/bin/env bash
# Builds Orca Deck.app next to this script. Usage: ./build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Orca Deck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/OrcaDeck" main.swift -framework AppKit -framework WebKit
cp -R web "$APP/Contents/Resources/web"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Orca Deck</string>
  <key>CFBundleIdentifier</key><string>local.orca-deck</string>
  <key>CFBundleExecutable</key><string>OrcaDeck</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built: $PWD/$APP"
if [[ "${1:-}" == "--install" ]]; then
  rm -rf "$HOME/Applications/Orca Deck.app"; mkdir -p "$HOME/Applications"
  cp -R "$APP" "$HOME/Applications/"
  echo "installed: $HOME/Applications/Orca Deck.app"
fi
