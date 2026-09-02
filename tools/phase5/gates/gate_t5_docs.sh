#!/bin/bash
# Gate T5 — dossier package (FULL_TEST_PLAN track 5, fed by DOSSIER_TRACK.md).
# exit 0 ONLY when:
#   1. evidence manifest tools/dossier/manifest.tsv exists and every listed
#      item exists on disk with a MATCHING sha256
#   2. the external-referee reproduction script exists and parses
#      (tools/dossier/reproduce_conditions.sh, linux shaping equivalent)
#   3. the technical dossier + proposal skeleton exist, carry the honest
#      crypto chapter and the «تعهد طراحی» label on unbuilt items
#   4. the executive summary exists
#   5. the number-source lint reports ZERO violations across the three docs
#      (every number line names its TSV/log source)
set -euo pipefail
. "$(dirname "$0")/tgate_lib.sh"
tgate_log t5_docs

MAN="$DOSSIER/manifest.tsv"
REPRO="$DOSSIER/reproduce_conditions.sh"
TECH="$DOSSIER/TECH_DOSSIER.md"
PROP="$DOSSIER/PROPOSAL_SKELETON.md"
EXEC="$DOSSIER/EXEC_SUMMARY.md"

check() {
  [ -s "$MAN" ] || die "manifest.tsv missing"
  # manifest columns: path <tab> bytes <tab> sha256 — verify every row
  local n=0
  while IFS=$'\t' read -r path bytes sha; do
    [ "$path" = "path" ] && continue
    [ -n "$path" ] || continue
    [ -f "$TREPO/$path" ] || die "manifest names a missing file: $path"
    local got
    got=$(shasum -a 256 "$TREPO/$path" | awk '{print $1}')
    [ "$got" = "$sha" ] || die "sha256 mismatch for $path"
    n=$((n + 1))
  done < "$MAN"
  echo "manifest rows verified: $n"
  [ "$n" -ge 4 ] || die "manifest too thin ($n rows) — TSVs, gate logs, captures expected"

  [ -s "$REPRO" ] || die "reproduce_conditions.sh missing"
  bash -n "$REPRO" || die "reproduce_conditions.sh does not parse"

  [ -s "$TECH" ] || die "TECH_DOSSIER.md missing"
  [ -s "$PROP" ] || die "PROPOSAL_SKELETON.md missing"
  [ -s "$EXEC" ] || die "EXEC_SUMMARY.md missing"
  grep -q 'رمزنگاری' "$TECH" || die "tech dossier lacks the honest crypto chapter"
  grep -q 'تعهد طراحی' "$PROP" || die "proposal lacks the «تعهد طراحی» label"

  # The two documents a funder actually opens were outside this lint until
  # 2026-09-02. The application draft stays out on purpose: it is prose bound
  # for a web form, and it carries its own verification table instead.
  python3 "$DOSSIER/number_source_lint.py" "$TECH" "$PROP" "$EXEC" \
    "$DOSSIER/PROBLEM_STATEMENT.md" "$DOSSIER/FUNDING_FACTS.md" \
    || die "number-source lint found violations"
}

check
if [ "${GATE_CHECK_ONLY:-0}" = "1" ]; then
  echo "gate_t5_docs check-only OK"
else
  echo "gate_t5_docs -> PASS"
fi
