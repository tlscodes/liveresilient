#!/bin/bash
# Writes apps/reference_app/macos/Runner/Configs/LocalSigning.xcconfig (untracked)
# from the VALID "Apple Development" identity in this Mac's keychain, so the
# Debug build keeps one signature across rebuilds and the keychain's "Always
# Allow" holds. Changes nothing when no such identity is there. Prints no team id.
#
# The team is read from the certificate whose SHA-1 is the valid identity's:
# a keychain also keeps expired certificates under the same name, and the
# first one found by name can belong to another team (it did, 2026-10-05).
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=apps/reference_app/macos/Runner/Configs/LocalSigning.xcconfig
HASH=$(security find-identity -v -p codesigning \
  | awk '/"Apple Development:/ {print $2; exit}')
if [ -z "$HASH" ]; then
  echo "no valid Apple Development identity in the keychain; nothing written"
  exit 1
fi
TEAM=$(security find-certificate -a -c "Apple Development" -Z -p \
  | awk -v want="$HASH" '
      /^SHA-1 hash: / { keep = ($3 == want) }
      keep && /-----BEGIN CERTIFICATE-----/ { pem = 1 }
      keep && pem { print }
      /-----END CERTIFICATE-----/ { pem = 0 }' \
  | openssl x509 -noout -subject -nameopt multiline \
  | awk -F'= ' '/organizationalUnitName/ {print $2; exit}')
[ -n "$TEAM" ] || { echo "the identity names no team (OU); nothing written"; exit 1; }
{
  echo "// Written by tools/t2/mac_local_signing.sh; untracked, this Mac only."
  echo "CODE_SIGN_IDENTITY[config=Debug] = Apple Development"
  echo "DEVELOPMENT_TEAM[config=Debug] = $TEAM"
} >"$OUT"
echo "wrote $OUT (identity …${HASH: -6}, team id of ${#TEAM} characters, not shown)"
