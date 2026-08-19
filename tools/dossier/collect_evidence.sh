#!/bin/bash
# D1 — evidence bundle with hashes (gate T5 item 1). Collects the run's
# measurement artifacts into tools/dossier/manifest.tsv: repo-relative path,
# bytes, sha256 per item. Network captures from the newest rig run are
# copied under tools/dossier/evidence/ first so they survive /tmp.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DOS="$REPO/tools/dossier"
MAN="$DOS/manifest.tsv"
mkdir -p "$DOS/evidence"

# pull the newest rig capture (if any) out of /tmp before it evaporates
NEWRUN=$(ls -1dt /tmp/h2run.* 2>/dev/null | head -1 || true)
if [ -n "$NEWRUN" ]; then
  for f in "$NEWRUN"/*.pcap "$NEWRUN"/dgram_relay.log; do
    [ -f "$f" ] && cp -f "$f" "$DOS/evidence/" && chmod 644 "$DOS/evidence/$(basename "$f")"
  done
fi

items=(
  tools/phase5/h3_results.tsv
  tools/phase5/corpus/manifest.tsv
  tools/t2/h2_results.tsv
  tools/dossier/e2e_ios_results.tsv
  tools/dossier/e2e_payloads/payloads.tsv
  tools/phase5/native/ios/PROVENANCE.tsv
  tools/dossier/logs/full_tree_summary.tsv
  tools/dossier/logs/ios_boot_verified.done
  tools/dossier/logs/ffi_finalizer_test.log
  tools/dossier/logs/e2e_netshape.log
  tools/dossier/logs/e2e_matrix_test.log
)
# every retained gate log
while IFS= read -r f; do items+=("${f#"$REPO"/}"); done \
  < <(find "$REPO/tools/dossier/logs" -name 'gate_*.log' ! -name '*.check.log' -type f | sort)
while IFS= read -r f; do items+=("${f#"$REPO"/}"); done \
  < <(find "$REPO/tools/phase5/logs" -name 'gate_*.log' ! -name '*.check.log' -type f | sort)
# captures copied above
while IFS= read -r f; do items+=("${f#"$REPO"/}"); done \
  < <(find "$DOS/evidence" -type f 2>/dev/null | sort)

TMPF="$MAN.tmp.$$"
printf 'path\tbytes\tsha256\n' > "$TMPF"
missing=0
for p in "${items[@]}"; do
  if [ ! -f "$REPO/$p" ]; then
    echo "MISSING (not yet produced): $p" >&2
    missing=$((missing + 1))
    continue
  fi
  printf '%s\t%s\t%s\n' "$p" "$(stat -f %z "$REPO/$p")" \
    "$(shasum -a 256 "$REPO/$p" | awk '{print $1}')" >> "$TMPF"
done
mv "$TMPF" "$MAN"
echo "manifest rows: $(($(wc -l < "$MAN") - 1)), missing inputs: $missing"
