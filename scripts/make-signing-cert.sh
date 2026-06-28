#!/usr/bin/env bash
# Create a local self-signed "Code Signing" identity named "VoiceInput Local" and
# import it into the login keychain.
#
# Why: signing the .app with a STABLE identity gives it a stable codesign
# "designated requirement", so the macOS Accessibility (TCC) grant survives every
# rebuild. Ad-hoc signing (codesign -s -) changes the code hash each build and
# invalidates the grant, forcing a re-grant every time.
#
# Run once:  bash scripts/make-signing-cert.sh
# Then `make app` auto-detects and uses "VoiceInput Local". On the FIRST signing,
# click "Always Allow" on the keychain prompt. Grant Accessibility once afterward.
#
# This produces a self-signed (untrusted-by-Gatekeeper) identity — fine for
# personal/local use, same trust level as ad-hoc but with a stable identity.
set -euo pipefail

NAME="VoiceInput Local"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/codesign.conf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = VoiceInput Local
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

# Key + self-signed code-signing certificate (10 years).
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/codesign.conf"

# Bundle into a PKCS#12 with legacy SHA1/3DES so macOS `security import` accepts it.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -passout pass:vilocal \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
  -out "$TMP/identity.p12"

# Import into the login keychain, allowing codesign to use the key.
security import "$TMP/identity.p12" -P vilocal \
  -k "$HOME/Library/Keychains/login.keychain-db" -T /usr/bin/codesign

echo "Imported identity '$NAME':"
security find-identity -p codesigning | grep "$NAME" || true
echo "Done. Run 'make app' (click Always Allow once), then grant Accessibility."
