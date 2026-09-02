#!/usr/bin/env bash
# leak_gate.sh — on-wire leak NO-REGRESSION gate.
#
# This gate does NOT use the evaluator's default kl_threshold (0.25): the
# current, known state of the pipeline measures kl = 0.997831 nats against the
# committed synthetic reference, so a 0.25 gate would be red on day one. Instead
# it fails only when kl gets WORSE than the committed baseline plus a tolerance
# (see tools/leak_gate_baseline.env for the numbers and their justification).
#
# The evaluator (trace-gate) lives in a separate repository. Its location MUST
# be given via LEAK_GATE_ENGINE_DIR; when unset or unbuildable the gate prints
# NOT RUN and exits non-zero — a skipped gate must never look like a pass.
#
# Optional: LEAK_GATE_OBSERVED=<csv> skips emission and gates that file
# (used to exercise the regression path with a known-bad trace).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BASELINE_FILE="$SCRIPT_DIR/leak_gate_baseline.env"
EMITTER_PKG="$REPO_ROOT/packages/connection_orchestrator"

not_run() {
  echo "==================================================================="
  echo "LEAK GATE: NOT RUN — $1"
  echo "This is a hard failure, not a skip: a silently skipped gate reads"
  echo "as a passing gate. Set LEAK_GATE_ENGINE_DIR to the checkout of the"
  echo "engine repo that contains the trace-gate crate."
  echo "==================================================================="
  exit 3
}

[ -f "$BASELINE_FILE" ] || not_run "baseline file missing: $BASELINE_FILE"
# shellcheck source=leak_gate_baseline.env
. "$BASELINE_FILE"

REFERENCE="$SCRIPT_DIR/$BASELINE_REFERENCE"
[ -f "$REFERENCE" ] || not_run "reference csv missing: $REFERENCE"

# Two evaluators implement the same frozen contract. The Rust one in the engine
# repository is the reference; the Dart one in this repository exists so the
# gate can run where that repository is not available, which is everywhere
# outside the author's machine. They agree to six decimals on the committed
# fixtures — tools/trace_gate/test/cross_check_test.dart pins that, and the
# baseline in leak_gate_baseline.env, measured with the Rust one a month
# earlier, corroborates it.
EVALUATOR=""
if [ -n "${LEAK_GATE_ENGINE_DIR:-}" ] && [ -d "$LEAK_GATE_ENGINE_DIR" ] \
   && (cd "$LEAK_GATE_ENGINE_DIR" && cargo build -q -p trace-gate 2>/dev/null); then
  EVALUATOR="rust"
elif command -v dart >/dev/null 2>&1 \
     && [ -f "$REPO_ROOT/tools/trace_gate/bin/trace_gate.dart" ]; then
  EVALUATOR="dart"
else
  not_run "no evaluator available: set LEAK_GATE_ENGINE_DIR, or install the Dart SDK"
fi
echo "leak_gate: evaluator = $EVALUATOR"

TMPDIR_GATE="$(mktemp -d "${TMPDIR:-/tmp}/leak_gate.XXXXXX")"
trap 'rm -rf "$TMPDIR_GATE"' EXIT

if [ -n "${LEAK_GATE_OBSERVED:-}" ]; then
  OBSERVED="$LEAK_GATE_OBSERVED"
  [ -f "$OBSERVED" ] || not_run "LEAK_GATE_OBSERVED does not exist: $OBSERVED"
  echo "leak_gate: gating externally supplied trace: $OBSERVED"
else
  OBSERVED="$TMPDIR_GATE/observed.csv"
  if ! (cd "$EMITTER_PKG" && dart run tool/emit_wire_trace.dart "$OBSERVED" "$BASELINE_TICKS"); then
    not_run "emitter failed in $EMITTER_PKG"
  fi
fi

KL_THRESHOLD="$(awk -v b="$BASELINE_KL" -v t="$KL_TOLERANCE" 'BEGIN{printf "%.6f", b+t}')"

echo "==================================================================="
echo "LEAK GATE — no-regression mode"
echo "  This gate compares against the committed baseline kl=$BASELINE_KL"
echo "  ($BASELINE_DATE) and fails only if kl exceeds baseline+tolerance"
echo "  = $KL_THRESHOLD nats (tolerance $KL_TOLERANCE, see leak_gate_baseline.env)."
echo "  CAVEAT: the reference ($BASELINE_REFERENCE) is SYNTHETIC and the"
echo "  thresholds are uncalibrated — this is a relative tracking number,"
echo "  not proof of resistance to real traffic analysis."
echo "  CAVEAT: sample pinned at $BASELINE_TICKS ticks / ~$BASELINE_RECORDS records to match"
echo "  the baseline's measurement conditions (longer runs trip the spectral"
echo "  check on emitter periodicity); the KL estimate is provisional at"
echo "  this sample size."
echo "==================================================================="

if [ "$EVALUATOR" = "rust" ]; then
  (cd "$LEAK_GATE_ENGINE_DIR" && cargo run -q -p trace-gate -- \
    "$OBSERVED" "$REFERENCE" --kl-threshold "$KL_THRESHOLD")
else
  (cd "$REPO_ROOT/tools/trace_gate" && dart pub get -q >/dev/null 2>&1 || true)
  dart run "$REPO_ROOT/tools/trace_gate/bin/trace_gate.dart" \
    "$OBSERVED" "$REFERENCE" --kl-threshold "$KL_THRESHOLD"
fi
RC=$?

if [ "$RC" -eq 0 ]; then
  echo "LEAK GATE: PASS (no regression beyond baseline $BASELINE_KL + $KL_TOLERANCE)"
elif [ "$RC" -eq 1 ]; then
  echo "LEAK GATE: FAIL — regression beyond baseline $BASELINE_KL + $KL_TOLERANCE (or spectral not clean)"
else
  echo "LEAK GATE: NOT RUN — trace-gate exited with usage/parse error ($RC)"
  exit 3
fi
exit "$RC"
