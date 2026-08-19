#!/bin/bash
# Gate T2 — native libraries for the device + app boot (FULL_TEST_PLAN track 2).
# exit 0 ONLY when:
#   T2.1 all four XCFrameworks exist with an ios-arm64 slice:
#        tools/phase5/native/ios/{libcodec2,libavif,libdav1d,libsvtav1}.xcframework
#   T2.2 the FFI NativeFinalizer test ran green and its complete log sits at
#        tools/dossier/logs/ffi_finalizer_test.log
#   T2.3 a Release boot on the CONNECTED device is recorded at
#        tools/dossier/logs/ios_boot_verified.done carrying the device UDID
#        (read from device_udid.txt, never hardcoded) and a timestamp.
# The heavy builds happen in the track's build scripts, not here — this gate
# is check-shaped in both modes; normal mode only re-verifies harder.
set -euo pipefail
. "$(dirname "$0")/tgate_lib.sh"
tgate_log t2_ios

XCDIR="$PHASE5/native/ios"
# container names == inner framework names (the linker resolves
# -framework <name> against the inner bundle; mismatch burned the first
# Release link: "Framework 'libavif' not found")
FRAMEWORKS=(codec2 avif dav1d SvtAv1Enc)
BOOT="$DLOGS/ios_boot_verified.done"
FFILOG="$DLOGS/ffi_finalizer_test.log"

check() {
  local f
  for f in "${FRAMEWORKS[@]}"; do
    local xc="$XCDIR/$f.xcframework"
    [ -d "$xc" ] || die "missing XCFramework: $f"
    ls "$xc"/ios-arm64*/ >/dev/null 2>&1 || die "$f.xcframework has no ios-arm64 slice"
    [ -f "$xc/Info.plist" ] || die "$f.xcframework has no Info.plist"
    echo "xcframework ok: $f  ($(du -sh "$xc" | awk '{print $1}'))"
  done
  [ -s "$FFILOG" ] || die "FFI finalizer test log missing"
  grep -qE 'All tests passed!' "$FFILOG" || die "FFI finalizer test log not green"
  [ -s "$BOOT" ] || die "ios_boot_verified.done missing (device boot not recorded)"
  local udid
  udid=$(device_udid)
  grep -q "$udid" "$BOOT" || die "boot record does not carry the device UDID from device_udid.txt"
  grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z' "$BOOT" || die "boot record has no timestamp"
  echo "boot record: $(cat "$BOOT")"
}

check
if [ "${GATE_CHECK_ONLY:-0}" = "1" ]; then
  echo "gate_t2_ios check-only OK"
else
  echo "gate_t2_ios -> PASS"
fi
