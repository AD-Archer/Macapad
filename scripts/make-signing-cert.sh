#!/bin/bash
# Creates a self-signed "Macapad Dev" code-signing identity in your login keychain.
# Signing with it gives the app a stable identity, so macOS keeps its Accessibility
# permission across rebuilds (ad-hoc signatures change with every build).
# Run once. Remove later in Keychain Access → login → My Certificates → "Macapad Dev".
set -euo pipefail

NAME="Macapad Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists in your login keychain"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# -legacy: macOS's keychain can't read OpenSSL 3's default p12 encryption
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/identity.p12" -passout pass:macapad

# -T lets codesign use the key without a keychain prompt on every build
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P macapad -T /usr/bin/codesign >/dev/null
echo "Created \"$NAME\" in your login keychain"
