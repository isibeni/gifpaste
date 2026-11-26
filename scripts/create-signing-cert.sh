#!/bin/bash
# Sets up the "GifPaste Signing" certificate. Idempotent: safe to run again at any time
# (new Mac, rotated GitHub secrets, a previous run that failed halfway).
#
# 1Password is the source of truth:
#   - item exists      → reuse that certificate
#   - item missing     → create a new certificate and store it there
# Then: import into the login keychain if missing, and (re)set the GitHub Actions secrets.
#
# Requires: op (1Password CLI, signed in) and gh (GitHub CLI, logged in).
# Usage:    scripts/create-signing-cert.sh [1Password-vault]   (default: Private)
set -euo pipefail

VAULT="${1:-Private}"
REPO="isibeni/gifpaste"
NAME="GifPaste Signing"
ITEM="GifPaste Signing Certificate"
FIELD="p12 password"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/usr/bin/openssl   # macOS LibreSSL: its .p12 files work with `security import`

# --- checks -------------------------------------------------------------------
command -v op >/dev/null || { echo "1Password CLI (op) missing: brew install 1password-cli"; exit 1; }
command -v gh >/dev/null || { echo "GitHub CLI (gh) missing: brew install gh"; exit 1; }
op vault get "$VAULT" >/dev/null || { echo "1Password vault '$VAULT' not found or op not signed in"; exit 1; }
gh repo view "$REPO" >/dev/null || { echo "No access to $REPO via gh"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

# --- 1. certificate: reuse from 1Password or create -----------------------------
if op item get "$ITEM" --vault "$VAULT" >/dev/null 2>&1; then
  op document get "$ITEM" --vault "$VAULT" > signing.p12
  P12_PASSWORD=$(op read "op://$VAULT/$ITEM/$FIELD" 2>/dev/null) || {
    echo "1Password item '$ITEM' has no '$FIELD' field (an earlier run failed halfway)."
    echo "Delete the item in 1Password and run this script again."
    exit 1
  }
  echo "✓ Using existing certificate from 1Password ($VAULT / $ITEM)"
else
  cat > cert.cnf <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  P12_PASSWORD=$("$OPENSSL" rand -hex 24)
  "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config cert.cnf \
    -keyout key.pem -out cert.pem 2>/dev/null
  "$OPENSSL" pkcs12 -export -inkey key.pem -in cert.pem -name "$NAME" \
    -out signing.p12 -passout pass:"$P12_PASSWORD"
  op document create signing.p12 --file-name gifpaste-signing.p12 \
    --title "$ITEM" --vault "$VAULT" >/dev/null
  op item edit "$ITEM" --vault "$VAULT" "$FIELD[password]=$P12_PASSWORD" >/dev/null
  echo "✓ Created new certificate and stored it in 1Password ($VAULT / $ITEM)"
fi

# SHA-1 of the certificate inside the .p12 (same format as `security find-identity`)
CERT_SHA1=$("$OPENSSL" pkcs12 -in signing.p12 -nokeys -passin pass:"$P12_PASSWORD" 2>/dev/null \
  | "$OPENSSL" x509 -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr 'a-f' 'A-F')

# --- 2. login keychain: import only if this exact identity is missing ---------------
KEYCHAIN_HASHES=$(security find-identity -p codesigning "$KEYCHAIN" \
  | awk -v n="\"$NAME\"" 'index($0, n) {print $2}' | sort -u)
if grep -qx "$CERT_SHA1" <<<"$KEYCHAIN_HASHES"; then
  echo "✓ Keychain already has this certificate"
elif [[ -n "$KEYCHAIN_HASHES" ]]; then
  echo "Your keychain has a different '$NAME' certificate:"
  echo "$KEYCHAIN_HASHES"
  echo "Delete it in Keychain Access (My Certificates) and run this script again."
  exit 1
else
  security import signing.p12 -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
  echo "✓ Imported into login keychain"
fi

# --- 3. GitHub Actions secrets: always (re)set --------------------------------------
base64 < signing.p12 | gh secret set SIGNING_CERT_P12_BASE64 -R "$REPO"
printf '%s' "$P12_PASSWORD" | gh secret set SIGNING_CERT_PASSWORD -R "$REPO"
echo "✓ GitHub secrets set on $REPO"

unset P12_PASSWORD
echo "Done. Certificate SHA-1: $CERT_SHA1"
