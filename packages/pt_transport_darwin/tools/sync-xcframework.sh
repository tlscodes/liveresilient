#!/usr/bin/env bash
# Copy the freshly built xcframework from the engine tree into this plugin, for
# both Apple platforms. Kept a copy on purpose: CocoaPods resolves
# vendored_frameworks relative to the pod directory, and a path pointing outside
# it does not survive `pod install`.
set -euo pipefail

SRC=${1:-/Users/behnam/Downloads/questions/engine/pt/build/PtTransport.xcframework}
PKG=$(cd "$(dirname "$0")/.." && pwd)

[ -d "$SRC" ] || { echo "missing $SRC — run engine/pt/tools/make_xcframework.sh first" >&2; exit 1; }

for p in ios macos; do
  mkdir -p "$PKG/$p/Frameworks"
  rm -rf "$PKG/$p/Frameworks/PtTransport.xcframework"
  cp -R "$SRC" "$PKG/$p/Frameworks/"
done

for b in "$PKG"/ios/Frameworks/PtTransport.xcframework/*/PtTransport.framework/PtTransport; do
  printf '%-70s exports=%s\n' "${b#$PKG/}" "$(nm -gU "$b" 2>/dev/null | grep -c ' T ')"
done
echo "synced into $PKG/{ios,macos}/Frameworks"
