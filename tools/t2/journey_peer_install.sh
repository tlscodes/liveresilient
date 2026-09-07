#!/usr/bin/env bash
# journey_peer_install.sh — install the PERSISTENT phone-side journey peer once.
#
# Compiles integration_test/journey_peer_app.dart (a plain Flutter app, not a
# test) in profile mode — a mode the phone can launch on its own, with no
# tooling attached — installs it over the rig phone's copy of the reference
# app bundle, and launches it. The peer then pre-warms the microphone, which
# raises the ONE permission prompt this install will ever show: answer it on
# the phone. Every later tools/t2/journey_run.sh only launches this install
# (devicectl), never reinstalls, so the prompt never returns and every profile
# row carries real phone audio.
#
# Re-run only when the peer's own code changed (a fresh install re-asks).
#
# USAGE  tools/t2/journey_peer_install.sh
#        JOURNEY_PHONE=<udid> T2_IFACE=bridge100 JOURNEY_RELAY_PORT=4443 override defaults.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
APP="$REPO/apps/reference_app"
PHONE=${JOURNEY_PHONE:-00008030-001215003AF2802E}
BUNDLE_ID=${JOURNEY_BUNDLE_ID:-com.tlscodes.referenceApp}
IFACE=${T2_IFACE:-bridge100}
SELF=$(ifconfig "$IFACE" 2>/dev/null | awk '/inet /{print $2; exit}')
RELAY_PORT=${JOURNEY_RELAY_PORT:-4443}
HTTP_PORT=${JOURNEY_HTTP_PORT:-8765}
BUDGET=${JOURNEY_CONNECT_BUDGET_S:-300}

[ -n "$SELF" ] || { echo "ERROR: $IFACE has no address — Internet Sharing on, phone joined?" >&2; exit 1; }

echo "peer      relay wss://$SELF:$RELAY_PORT/   hub http://$SELF:$HTTP_PORT   budget ${BUDGET}s"
echo "phone     $PHONE ($BUNDLE_ID)"
cd "$APP"
# One hashed build dir per define set: the same defines on every install
# keep the cache small (the 22 GB flutter_build lesson, 2026-09-03).
flutter build ios --profile -t integration_test/journey_peer_app.dart \
  --dart-define=E2E_RELAY_URI="wss://$SELF:$RELAY_PORT/" \
  --dart-define=JOURNEY_HUB_URL="http://$SELF:$HTTP_PORT" \
  --dart-define=E2E_CONNECT_BUDGET_S="$BUDGET"
BUNDLE="$APP/build/ios/iphoneos/Runner.app"
[ -d "$BUNDLE" ] || { echo "ERROR: no bundle at $BUNDLE" >&2; exit 1; }
echo "install   $BUNDLE"
xcrun devicectl device install app --device "$PHONE" "$BUNDLE"
for try in 1 2 3 4 5; do
  out=$(xcrun devicectl device process launch --terminate-existing --device "$PHONE" "$BUNDLE_ID" 2>&1)
  if printf '%s' "$out" | grep -q 'Launched application'; then
    echo "launched  (try $try) — answer the microphone prompt on the phone once"
    exit 0
  fi
  echo "launch denied (try $try): $(printf '%s' "$out" | tail -1 | cut -c1-120)"
  sleep 2
done
echo "ERROR: the phone refused to launch $BUNDLE_ID five times (awake? trusts this Mac?)" >&2
exit 1
