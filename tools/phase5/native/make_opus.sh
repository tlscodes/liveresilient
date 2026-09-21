#!/usr/bin/env bash
# libopus 1.5.2 for the voice letter (mode 12 on the voice-note wire):
#   * a macOS host dylib for the Dart CLI tools and host tests
#     (tools/phase5/native/opus-mac/libopus.dylib), and
#   * an ios-arm64 DYNAMIC-framework XCFramework, packed exactly like
#     codec2.xcframework (Dart FFI opens 'opus.framework/opus' in-process),
#     copied into apps/reference_app/ios/NativeCodecs/ and pinned in
#     tools/phase5/native/ios/PROVENANCE.tsv.
# Source: opus-1.5.2.tar.gz, sha256
#   65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1
# (the one approved download, 2026-09-21). OSCE (LACE/NoLACE decoder
# enhancement) is NOT compiled in: dnn/osce.c:933 only enhances SILK at
# 16 kHz with 20 ms frames, and mode 12 is narrowband 60 ms — measured
# 2026-09-21, complexity 7 decoded byte-identical to complexity 0 with
# OSCE on, at +2.3 MB of weights. A wideband 20 ms mode would need it.
set -euo pipefail
NATIVE="$(cd "$(dirname "$0")" && pwd)"
TARBALL="$NATIVE/opus-1.5.2.tar.gz"
SRC="$NATIVE/opus-1.5.2"
OUT="$NATIVE/ios"
APP_FW="$NATIVE/../../../apps/reference_app/ios/NativeCodecs"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
MIN_IOS=13.0
JOBS=$(sysctl -n hw.ncpu)
log() { printf '[opus %s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

EXPECT=65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1
GOT=$(shasum -a 256 "$TARBALL" | awk '{print $1}')
[ "$GOT" = "$EXPECT" ] || { echo "tarball sha mismatch: $GOT"; exit 1; }
if [ ! -f "$SRC/CMakeLists.txt" ]; then
  tar -xzf "$TARBALL" -C "$NATIVE"
  log "unpacked $SRC"
fi

common=(
  -DCMAKE_BUILD_TYPE=Release
  -DOPUS_BUILD_SHARED_LIBRARY=ON
  -DOPUS_BUILD_PROGRAMS=OFF
  -DOPUS_BUILD_TESTING=OFF
  -DOPUS_OSCE=OFF
  -DOPUS_DRED=OFF
)

# ---------------- macOS host dylib (x86_64, this iMac) ---------------------
if [ ! -f "$NATIVE/opus-mac/libopus.dylib" ] || [ "${FORCE:-0}" = 1 ]; then
  B="$NATIVE/opus-mac"
  cmake -S "$SRC" -B "$B" "${common[@]}" \
    -DCMAKE_OSX_ARCHITECTURES=x86_64 >/dev/null
  cmake --build "$B" -j "$JOBS" >/dev/null
  log "mac dylib: $(ls -la "$B"/libopus.dylib | awk '{print $5}') B"
  nm -gU "$B/libopus.dylib" | grep -c ' T _opus_' | sed 's/^/[opus] exported opus_ symbols: /'
fi

# ---------------- ios-arm64 dynamic framework ------------------------------
if [ ! -d "$OUT/opus.xcframework" ] || [ "${FORCE:-0}" = 1 ]; then
  B="$NATIVE/opus-ios"
  cmake -S "$SRC" -B "$B" "${common[@]}" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_SYSROOT="$SDK" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS" \
    -DCMAKE_INSTALL_NAME_DIR=@rpath \
    -DCMAKE_MACOSX_BUNDLE=OFF >/dev/null
  cmake --build "$B" -j "$JOBS" >/dev/null
  DY=$(find "$B" -maxdepth 1 -name 'libopus*.dylib' -type f | head -1)
  [ -n "$DY" ] || { echo "ios dylib not produced"; exit 1; }
  WORK="$NATIVE/opus-ios/fw"; rm -rf "$WORK"
  fw="$WORK/opus.framework"; mkdir -p "$fw/Headers"
  cp "$DY" "$fw/opus"
  cp "$SRC"/include/*.h "$fw/Headers/"
  install_name_tool -id "@rpath/opus.framework/opus" "$fw/opus"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string app.voicecallkit.opus" \
    -c "Add :CFBundleName string opus" \
    -c "Add :CFBundleExecutable string opus" \
    -c "Add :CFBundlePackageType string FMWK" \
    -c "Add :CFBundleVersion string 1.5.2" \
    -c "Add :CFBundleShortVersionString string 1.5.2" \
    -c "Add :MinimumOSVersion string $MIN_IOS" \
    "$fw/Info.plist" >/dev/null
  rm -rf "$OUT/opus.xcframework"
  xcodebuild -create-xcframework -framework "$fw" -output "$OUT/opus.xcframework" >/dev/null
  log "packed opus.xcframework ($(du -sh "$OUT/opus.xcframework" | awk '{print $1}'))"
  SHA=$(shasum -a 256 "$OUT/opus.xcframework/ios-arm64/opus.framework/opus" | awk '{print $1}')
  grep -v '^opus	' "$OUT/PROVENANCE.tsv" > "$OUT/PROVENANCE.tmp" || true
  printf 'opus\topus-1.5.2.tar.gz sha256 %s (OSCE off, DRED off)\t1.5.2\t%s\n' "$EXPECT" "$SHA" >> "$OUT/PROVENANCE.tmp"
  mv "$OUT/PROVENANCE.tmp" "$OUT/PROVENANCE.tsv"
  rm -rf "$APP_FW/opus.xcframework"
  cp -R "$OUT/opus.xcframework" "$APP_FW/opus.xcframework"
  log "vendored into $APP_FW/opus.xcframework sha256 $SHA"
fi
lipo -info "$OUT/opus.xcframework/ios-arm64/opus.framework/opus"
nm -gU "$OUT/opus.xcframework/ios-arm64/opus.framework/opus" | grep -c ' T _opus_' | sed 's/^/[opus] ios exported opus_ symbols: /'
