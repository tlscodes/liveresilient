#!/bin/bash
# Writes apps/reference_app/macos/Runner/Configs/LocalSigning.xcconfig (untracked)
# from the "Apple Development" certificate in this Mac's keychain, so the Debug
# build keeps one signature across rebuilds and the keychain's "Always Allow"
# holds. Changes nothing when no such certificate is there. Prints no team id.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=apps/reference_app/macos/Runner/Configs/LocalSigning.xcconfig
if ! security find-identity -v -p codesigning | grep -q '"Apple Development:'; then
  echo "no Apple Development certificate in the keychain; nothing written"
  exit 1
fi
TEAM=$(security find-certificate -c "Apple Development" -p \
  | openssl x509 -noout -subject -nameopt multiline \
  | awk -F'= ' '/organizationalUnitName/ {print $2; exit}')
[ -n "$TEAM" ] || { echo "the certificate names no team (OU); nothing written"; exit 1; }
{
  echo "// Written by tools/t2/mac_local_signing.sh; untracked, this Mac only."
  echo "CODE_SIGN_IDENTITY[config=Debug] = Apple Development"
  echo "DEVELOPMENT_TEAM[config=Debug] = $TEAM"
} >"$OUT"
echo "wrote $OUT (team id of ${#TEAM} characters, not shown)"
