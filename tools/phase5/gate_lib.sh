#!/bin/bash
# Shared helpers for phase 5 gates. Sourced by gate_1..6.sh and goal_verify.sh.
# Contract (from the completed design consult, 2026-08-19):
#   - single writer: only gate_N.sh writes its feature's TSV row, and always
#     replace-not-append via tmp+mv (idempotent re-runs, no duplicate rows)
#   - GATE_CHECK_ONLY=1: verify existing artifacts + row, never re-measure,
#     never write — goal_verify.sh uses this so verification cannot mutate
#     evidence
#   - no gate runs on an unhashed asset: verify_asset re-hashes the corpus item
#     against manifest.tsv before any measurement

PHASE5_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORPUS="$PHASE5_DIR/corpus"
MANIFEST="$CORPUS/manifest.tsv"
TSV="$PHASE5_DIR/h3_results.tsv"
TSV_HEADER=$'Feature\tStandard_Size\tCompressed_Size\tWire_Time_At_2Kbps\tLoss_Survival\tStatus'

die() { echo "GATE FAIL: $*" >&2; exit 1; }

# verify_asset <corpus-file-name> — sha256 must match the manifest row
verify_asset() {
  local name="$1" want got
  [ -f "$CORPUS/$name" ] || die "asset missing: $name"
  want=$(awk -F'\t' -v n="$name" '$1==n{print $3}' "$MANIFEST")
  [ -n "$want" ] || die "asset not in manifest: $name"
  got=$(shasum -a 256 "$CORPUS/$name" | awk '{print $1}')
  [ "$want" = "$got" ] || die "sha256 mismatch for $name (manifest=$want disk=$got)"
}

# tsv_row_replace <Feature> <Std> <Comp> <Wire> <Loss> <Status>
tsv_row_replace() {
  local feat="$1"
  [ -f "$TSV" ] || printf '%s\n' "$TSV_HEADER" > "$TSV"
  local tmp="$TSV.tmp.$$"
  awk -F'\t' -v f="$feat" '$1!=f' "$TSV" > "$tmp"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$tmp"
  mv "$tmp" "$TSV"
}

# tsv_row_get <Feature> — prints the row or nothing
tsv_row_get() { awk -F'\t' -v f="$1" '$1==f' "$TSV" 2>/dev/null; }

# wire_time_2kbps <bytes> — seconds at 2kbps, one decimal
wire_time_2kbps() { python3 -c "print(f'{$1*8/2000:.1f}s')"; }

# gate_log <N> — route all output to the full log (never tail/head).
# The check-only contract above says verification never writes evidence —
# but this tee used to rewrite the retained log on every GATE_CHECK_ONLY
# re-verify, silently changing the log's hash (caught 2026-08-19 by the
# dossier manifest gate). Check-only output now goes to a .check file.
gate_log() {
  mkdir -p "$PHASE5_DIR/logs"
  if [ "${GATE_CHECK_ONLY:-0}" = "1" ]; then
    exec > >(tee "$PHASE5_DIR/logs/gate_$1.check.log") 2>&1
  else
    exec > >(tee "$PHASE5_DIR/logs/gate_$1.log") 2>&1
  fi
  echo "== gate_$1 $(date -u +%Y-%m-%dT%H:%M:%SZ) check_only=${GATE_CHECK_ONLY:-0} =="
}

# require_row <Feature> <Status-regex> — check-only helper
require_row() {
  local row
  row=$(tsv_row_get "$1")
  [ -n "$row" ] || die "no TSV row for $1"
  echo "$row" | awk -F'\t' -v s="$2" '$6~s{ok=1} END{exit !ok}' \
    || die "row status not matching /$2/ for $1: $row"
}
