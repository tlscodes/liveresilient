#!/usr/bin/env bash
# h2_matrix.sh — run the whole H2 threshold set and print one table.
#
# Deliberately thin: it is a loop over h2_run.sh, because every guarantee that
# matters (teardown on any exit, traffic verification, refusing an unrouted
# result) belongs in the single runner rather than being re-implemented per
# caller. This script's only jobs are ordering and summarising.
#
# ORDER IS NOT ARBITRARY. `clean` runs first as a control: if the app cannot
# pass over the shaped path with NO impairment, every later row is measuring
# the rig, not the thresholds — the same reason the selftest checks its
# baseline before it checks its shaping.
#
#   sudo tools/t2/h2_matrix.sh [device-id]
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
RUN="$HERE/h2_run.sh"
DEVICE="${1:-${T2_DEVICE:-}}"
# The SLA test by default: it prints SLA_SUMMARY, so every row carries measured
# numbers instead of a connectivity verdict. `loopback_call_test.dart` remains
# the right choice when the question is "does the call still work at all",
# but it measures nothing, and a table of PASS/FAIL is not a table of results.
TEST="${T2_TEST:-integration_test/sla_thresholds_test.dart}"

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 2; }

# UNATTENDED-READINESS GATE. The matrix exists to run with nobody watching, and
# the one thing that legitimately raises an iOS prompt is a FIRST install of the
# bundle id: TCC grants are per bundle id (and signing team), so a brand-new id
# starts with no microphone grant and the first getUserMedia stalls 30 s waiting
# for a tap (measured 2026-08-04: `e2e media mode: noLocalAudio ...
# TimeoutException after 0:00:30`). That is exactly what happened when the app
# was renamed com.voicecallkit.* -> com.tlscodes.*: the new id had never been
# granted anything. Reinstalls over the SAME id are upgrades and keep the grant,
# so the gate is: the app must already be installed (and therefore already
# granted, attended, once) before an unattended matrix may start.
#
# Policy: a definitive "not installed" refuses (exit 4) — a wrong refusal costs
# a minute, an unattended stall costs the night. A devicectl failure or an empty
# DEVICE cannot prove anything either way, so those WARN and continue.
BUNDLE_ID="${T2_BUNDLE_ID:-com.tlscodes.referenceApp}"
if [ -n "${DEVICE:-}" ]; then
  APPS_JSON=$(mktemp /tmp/h2apps.XXXXXX.json)
  if xcrun devicectl device info apps --device "$DEVICE" \
       --json-output "$APPS_JSON" >/dev/null 2>&1; then
    installed=$(python3 - "$APPS_JSON" "$BUNDLE_ID" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    apps = d.get("result", {}).get("apps", [])
    print(1 if any(a.get("bundleIdentifier") == sys.argv[2] for a in apps) else 0)
except Exception:
    print("err")
PY
)
    if [ "$installed" = "0" ]; then
      rm -f "$APPS_JSON"
      echo "REFUSING TO START: $BUNDLE_ID is not installed on $DEVICE." >&2
      echo "A first install prompts for microphone permission and developer" >&2
      echo "trust, and an unattended run cannot answer prompts. Do ONE attended" >&2
      echo "pass first: trust the computer, enable Developer Mode, run" >&2
      echo "  sudo tools/t2/h2_run.sh clean $TEST $DEVICE" >&2
      echo "and tap Allow on the microphone prompt. Re-run attended again if" >&2
      echo "the signing team ever changes — TCC grants are per id AND team." >&2
      exit 4
    elif [ "$installed" = "1" ]; then
      echo "preflight  $BUNDLE_ID installed on device — reinstalls are upgrades,"
      echo "           the microphone grant survives; no prompts expected."
    else
      echo "preflight  WARNING: could not parse devicectl app list; proceeding." >&2
    fi
  else
    echo "preflight  WARNING: devicectl could not query $DEVICE; cannot verify" >&2
    echo "           the app is installed. Proceeding — a first install would" >&2
    echo "           prompt and stall." >&2
  fi
  rm -f "$APPS_JSON"
else
  echo "preflight  no device id — install check skipped."
fi

declare -a ROWS=()

# Between runs the device debugger needs a moment, and a stale one is a known
# cause of the attach failures this matrix now detects. Cheap insurance.
settle() {
  # `lldb-rpc-server` was missing from this list and is the one that actually
  # survives: after a Ctrl-C'd run it was still alive on this machine while
  # `lldb` and `debugserver` were long gone.
  killall -9 lldb debugserver lldb-rpc-server >/dev/null 2>&1 || true
  sleep 5
}

run_one() {
  local profile=$1 threshold=$2
  echo "=============================================================="
  echo "profile $profile   (threshold $threshold)"
  echo "=============================================================="
  local out rc row
  out=$("$RUN" "$profile" "$TEST" $DEVICE 2>&1)
  rc=$?

  # Exit 8 means flutter never attached; exit 7 means it attached and the
  # NATIVE media stack never came up. Neither is about the app, both are
  # intermittent, and both are worth one retry: a retry costs three minutes
  # while a wrong row costs the credibility of the whole table.
  #
  # 7 was added after 2026-08-03T22:57, when a `clean` run wedged in
  # `setLocalDescription` on state inherited from an interrupted run and was
  # recorded as a threshold FAIL on an unimpaired link.
  if [ "$rc" -eq 8 ] || [ "$rc" -eq 7 ]; then
    echo
    if [ "$rc" -eq 8 ]; then
      echo "--- attach failed; settling and retrying once ---"
    else
      echo "--- native media stack stalled; settling and retrying once ---"
    fi
    settle
    out=$("$RUN" "$profile" "$TEST" $DEVICE 2>&1)
    rc=$?
  fi

  printf '%s\n' "$out"
  row=$(printf '%s\n' "$out" | tail -1)
  ROWS+=("$threshold	$row")

  # A control failure invalidates the run: stop rather than collect numbers
  # that describe a broken rig. Tooling failures on the control are the same
  # thing — the rig is not ready.
  if [ "$profile" = clean ] && [ "$rc" -ne 0 ]; then
    echo
    echo "STOPPING: the control profile did not pass. Nothing below it would" >&2
    echo "mean anything — fix the rig or the test before measuring thresholds." >&2
    exit 3
  fi
  settle
}

run_one clean     "control"
run_one normal    "#4 text < 500 ms"
run_one latency   "#1 RTT 1800 ms"
run_one bandwidth "#3 32 kbps audio"
run_one narrow    "#3 16 kbps text"
run_one loss10    "#5 PLC at 10% loss"
run_one loss60    "STRESS #2 survive 60% loss"
run_one extreme   "STRESS #7 survive and recover"

echo
echo "=============================================================="
echo "H2 RESULTS"
echo "=============================================================="
printf 'threshold\tprofile\tverdict\trtt_ms\tloss_pct\tpackets\telapsed_ms\tconnect_ms\tack_p50\tack_p95\tack_loss\trecovery_ms\talive\tnote\n'
for r in "${ROWS[@]}"; do printf '%s\n' "$r"; done

cat <<'EOF'

HOW TO READ THE MEASURED COLUMNS
  connect_ms    time from start() to both sides connected
  ack_p50/p95   signalling frame sent -> acknowledged, over the shaped link.
                NOT chat latency: the app's chat runs on a WebRTC data channel
                this harness does not expose. Threshold #4 is judged against
                p95, not the median, because a median hides the tail a user
                actually notices.
  ack_loss      probes that expired rather than being acknowledged
  recovery_ms   ICE restart request -> connected again. A PROXY for threshold
                #7: a real outage must also be DETECTED first, and detection
                time is not measured here.
  alive         still connected at the end. A row with good latencies and
                alive=False is a failure, whatever the verdict column says.

TIERS (each row's note carries a criterion= field naming which one judged it)
  sla           six profiles; the global SLA machinery applies unchanged, so
                a slowness regression stays visible.
  stress        loss60 and extreme; verdicts PASS/STRESS and FAIL/STRESS.
                Criterion is SURVIVAL: connect, media in both directions,
                recover from a break — each inside a bound h2_run.sh derives
                INDEPENDENTLY from the shaper's own rtt/loss/bandwidth
                (deliberate double-entry: it never reads the app's budget,
                which would pass by construction). p50/p95/ack_loss are
                recorded but not judged there — they are physics at 60% loss,
                not product quality.
EOF

echo
echo "Reminders that belong in any report built from this table:"
echo " · dummynet loss is i.i.d.; real bursty loss at the same rate is harder."
echo " · INVALID/UNROUTED and TOOLING/NO-ATTACH rows describe the RIG, not the"
echo "   app. They are neither passes nor failures and must not be counted as"
echo "   either — on 2026-08-03 two attach failures were scored FAIL and looked"
echo "   exactly like threshold failures."
echo " · only UDP is shaped by default (mDNS excluded), so the media path is"
echo "   impaired and flutter's own control channel is not."
echo " · jitter is absent on purpose: dummynet has no delay distribution, so a"
echo "   jitter row here could only be constant latency wearing a jitter label."
echo " · threshold #6 (media reconstruction after outages) is NOT here: it needs"
echo "   the receive-side layer router, which does not exist yet."
