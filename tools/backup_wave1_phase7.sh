#!/bin/sh
# Numbered .backups/ copies for Phase 7 Wave 1 (signed_config manifest v2).
set -eu
cd "$(dirname "$0")/.."
mkdir -p .backups
n=$(ls .backups 2>/dev/null | grep -cE '^[0-9]{3}-' || true)
bk() {
  n=$((n + 1))
  dst=".backups/$(printf '%03d' "$n")-$(echo "$1" | tr '/' '-').bak"
  cp "$1" "$dst"
  echo "$dst"
}
bk packages/signed_config/lib/src/endpoint_manifest.dart
bk packages/signed_config/lib/src/manifest_cache.dart
bk packages/signed_config/test/support/fakes.dart
bk packages/signed_config/test/sign_manifest_cli_test.dart
