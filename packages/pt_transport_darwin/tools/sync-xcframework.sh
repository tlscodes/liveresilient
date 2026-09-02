#!/usr/bin/env bash
# Copy the freshly built xcframework from the engine tree into this plugin, for
# both Apple platforms. Kept a copy on purpose: CocoaPods resolves
# vendored_frameworks relative to the pod directory, and a path pointing outside
# it does not survive `pod install`.
set -euo pipefail

# No default: the engine tree lives outside this repository, and a path under
# one developer's home directory is not a default anyone else can use.
SRC=${1:-${PT_XCFRAMEWORK:-}}
[ -n "$SRC" ] || { echo "usage: $0 <path/to/PtTransport.xcframework>  (or set PT_XCFRAMEWORK)" >&2; exit 2; }
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
