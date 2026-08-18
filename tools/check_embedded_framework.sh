#!/usr/bin/env bash
# Packaging gate for every build that carries the native core: the Apple bundles
# and the Android APK. Named for the Apple case it started as.
#
# WHY THIS EXISTS. Three defects got past a fully green test suite on 2026-08-01:
#   1. the macOS slice of the native core linked /usr/local/opt/openssl@3/... — an
#      absolute build-machine path that exists on no user's device, so the shipped
#      app would fail to load the core at launch;
#   2. the macOS framework was built as a shallow bundle, which Xcode rejects;
#   3. CocoaPods served a cached copy, so the first "fixed" check was false.
# None of them produced a warning in the build output. So this is an explicit gate,
# run against the framework INSIDE the built .app — not against the intermediate.
#
# Usage: bash tools/check_embedded_framework.sh [app-bundle ...]
# With no arguments it checks whatever release bundles exist under apps/reference_app/build.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
FW=PtTransport
EXPECTED_EXPORTS=12
fail=0

note() { printf '%-6s %s\n' "$1" "$2"; }

check_binary() {
  local bin=$1 label=$2
  local bad
  bad=$(otool -L "$bin" | tail -n +2 | awk '{print $1}' \
        | grep -vE '^(/usr/lib/|/System/|@rpath/|@executable_path/|@loader_path/)' || true)
  if [ -n "$bad" ]; then
    note FAIL "$label links paths that will not exist on a user's machine:"
    printf '         %s\n' $bad
    fail=1
  else
    note ok "$label has no build-machine paths"
  fi

  local n
  n=$(nm -gU "$bin" 2>/dev/null | grep -c ' T ')
  if [ "$n" = "$EXPECTED_EXPORTS" ]; then
    note ok "$label exports $n symbols"
  else
    note FAIL "$label exports $n symbols, expected $EXPECTED_EXPORTS"
    fail=1
  fi
}

check_bundle() {
  local app=$1
  local fwdir
  if [ -d "$app/Contents/Frameworks" ]; then
    fwdir="$app/Contents/Frameworks/$FW.framework"   # macOS: versioned bundle
    if [ -d "$fwdir" ] && [ ! -d "$fwdir/Versions" ]; then
      note FAIL "$fwdir is shallow; macOS requires Versions/Current/Resources/Info.plist"
      fail=1
    fi
  else
    fwdir="$app/Frameworks/$FW.framework"            # iOS: shallow bundle
  fi

  if [ ! -d "$fwdir" ]; then
    note FAIL "$app does not embed $FW.framework"
    fail=1
    return
  fi
  note ok "$(basename "$app") embeds $FW.framework"
  check_binary "$fwdir/$FW" "$(basename "$app")/$FW"
}

# Android: the same question asked of the APK — is the core actually in there, and
# did the exported surface survive AGP's strip pass? Strip removes .symtab and
# debug info but not .dynsym, which is what dlopen/dlsym and the version script
# govern; this proves it rather than assuming it.
check_apk() {
  local apk=$1
  local nm entries tmp n
  # EVERY ABI in the APK is checked, not the first one found: shipping arm64 with
  # a broken x86_64 slice would pass a first-match check and fail on an emulator.
  entries=$(unzip -l "$apk" | awk '/lib\/[^ ]*\/libpt_transport\.so/{print $4}')
  if [ -z "$entries" ]; then
    note FAIL "$(basename "$apk") does not contain libpt_transport.so"
    fail=1
    return
  fi

  nm=$(ls "$HOME"/Library/Android/sdk/ndk/*/toolchains/llvm/prebuilt/*/bin/llvm-nm 2>/dev/null | head -1)
  for entry in $entries; do
    note ok "$(basename "$apk") contains $entry"
    if [ -z "$nm" ]; then
      note SKIP "no llvm-nm in an installed NDK — symbol count not checked"
      continue
    fi
    tmp=$(mktemp -d)
    unzip -o -q "$apk" "$entry" -d "$tmp"
    n=$("$nm" -D --defined-only "$tmp/$entry" 2>/dev/null | grep -c ' T pt_')
    rm -rf "$tmp"
    if [ "$n" = "$EXPECTED_EXPORTS" ]; then
      note ok "$entry exports $n pt_ symbols after packaging"
    else
      note FAIL "$entry exports $n pt_ symbols after packaging, expected $EXPECTED_EXPORTS"
      fail=1
    fi
  done
}

for apk in "$REPO"/apps/reference_app/build/app/outputs/flutter-apk/app-release.apk; do
  [ -f "$apk" ] && check_apk "$apk"
done

apps=("$@")
if [ ${#apps[@]} -eq 0 ]; then
  while IFS= read -r a; do apps+=("$a"); done < <(
    find "$REPO/apps/reference_app/build" -maxdepth 6 -name '*.app' -type d 2>/dev/null \
      | grep -E '/(Release|iphoneos)/' || true
  )
fi

if [ ${#apps[@]} -eq 0 ]; then
  note SKIP "no release .app bundles found — build one first"
  exit 0
fi

for a in "${apps[@]}"; do check_bundle "$a"; done
[ $fail = 0 ] && echo "PACKAGING GATE PASSED" || echo "PACKAGING GATE FAILED"
exit $fail
