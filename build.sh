#!/usr/bin/env bash
# Builds Orca Deck.app next to this script. Usage: ./build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Orca Deck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/OrcaDeck" main.swift system.swift \
  -framework AppKit -framework WebKit -framework IOKit
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
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Sign with a stable identity when there is one, so macOS keeps the Accessibility permission (Dock guard)
# across rebuilds. An ad-hoc signature changes every build and macOS then asks again.
# Create one with ./make-signing-cert.sh, or set ORCA_DECK_SIGN_ID to another identity.
SIGN_ID="${ORCA_DECK_SIGN_ID:-}"
if [[ -z "$SIGN_ID" ]] && security find-identity -p codesigning 2>/dev/null | grep -q "Orca Deck Local Signing"; then
  SIGN_ID="Orca Deck Local Signing"
fi
if [[ -n "$SIGN_ID" ]] && codesign --force --sign "$SIGN_ID" "$APP" >/dev/null 2>&1; then
  echo "signed: $SIGN_ID"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  echo "signed: ad-hoc (Accessibility must be granted again after each build; see ./make-signing-cert.sh)"
fi
echo "built: $PWD/$APP"
if [[ "${1:-}" == "--install" ]]; then
  rm -rf "$HOME/Applications/Orca Deck.app"; mkdir -p "$HOME/Applications"
  cp -R "$APP" "$HOME/Applications/"
  echo "installed: $HOME/Applications/Orca Deck.app"
  # Restart a running copy so the new build takes over.
  if pgrep -xq OrcaDeck; then
    osascript -e 'quit app "Orca Deck"' >/dev/null 2>&1 || pkill -x OrcaDeck || true
    for _ in $(seq 1 30); do pgrep -xq OrcaDeck || break; sleep 0.2; done
    open "$HOME/Applications/Orca Deck.app"
    echo "restarted Orca Deck"
  fi
fi
