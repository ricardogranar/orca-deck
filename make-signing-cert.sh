#!/usr/bin/env bash
# Creates a self-signed code-signing identity "Orca Deck Local Signing" in your login keychain.
# build.sh uses it automatically. With a stable signature macOS remembers the Accessibility permission
# Orca Deck needs to keep the Dock off the phone; with ad-hoc signing it forgets it on every rebuild.
set -euo pipefail
NAME="Orca Deck Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then echo "already there: $NAME"; exit 0; fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<CFG
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CFG
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/k.pem" -out "$TMP/c.pem" -days 3650 -config "$TMP/cfg" 2>/dev/null
PASS="orca-deck-$RANDOM"
# -legacy keeps the PKCS#12 readable by macOS `security` when openssl is 3.x or newer.
openssl pkcs12 -export -legacy -inkey "$TMP/k.pem" -in "$TMP/c.pem" -out "$TMP/id.p12" -passout "pass:$PASS" -name "$NAME" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/k.pem" -in "$TMP/c.pem" -out "$TMP/id.p12" -passout "pass:$PASS" -name "$NAME"
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "created: $NAME (now run ./build.sh --install)"
