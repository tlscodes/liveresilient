#!/bin/bash
# Gate 1 — Text: wire message p50 <= 80B and p95 <= 100B over the 200-message
# corpus, lossless round-trip on every message.
# Wire format measured: 4B header [ver/flags][msgId u16][dictVer] + zstd -19
# body compressed with the committed trained dictionary. The measurement
# includes the full zstd frame as emitted (conservative: real wire could strip
# the 4B magic; we do not).
# Build prerequisites (peak 1 build step):
#   packages/messaging/assets/zstd_chat.dict      trained dict, <= 32768 B
#   packages/messaging/lib/src/compact_text_codec.dart   the codec (round-trip
#     proven by its own dart test; this gate re-proves losslessness via zstd CLI)
#   tools/phase5/measure_text.py                  per-message measurer
set -euo pipefail
. "$(dirname "$0")/gate_lib.sh"
gate_log 1

DICT="$PHASE5_DIR/../../packages/messaging/assets/zstd_chat.dict"

if [ "${GATE_CHECK_ONLY:-0}" = "1" ]; then
  [ -f "$DICT" ] || die "dict missing"
  [ "$(stat -f %z "$DICT")" -le 32768 ] || die "dict over 32KB"
  [ -f "$PHASE5_DIR/logs/text_sizes.tsv" ] || die "no measurement evidence"
  require_row "Text" '^PASS'
  echo "gate_1 check-only OK"
  exit 0
fi

verify_asset chat_corpus_200.jsonl
[ -f "$DICT" ] || die "zstd_chat.dict not built yet"
[ "$(stat -f %z "$DICT")" -le 32768 ] || die "dict over 32KB budget: $(stat -f %z "$DICT")"
[ -f "$PHASE5_DIR/measure_text.py" ] || die "measure_text.py not built yet"

# measure_text.py prints TSV: id, raw_bytes, wire_bytes, roundtrip(ok|FAIL)
python3 "$PHASE5_DIR/measure_text.py" \
  "$CORPUS/chat_corpus_200.jsonl" "$DICT" > "$PHASE5_DIR/logs/text_sizes.tsv"

read -r P50_RAW P50 P95 WORST BAD <<EOF2
$(python3 - "$PHASE5_DIR/logs/text_sizes.tsv" <<'PY'
import sys, statistics
rows = [l.split('\t') for l in open(sys.argv[1]) if l.strip()][1:]
raw = sorted(int(r[1]) for r in rows)
wire = sorted(int(r[2]) for r in rows)
bad = sum(1 for r in rows if r[3].strip() != 'ok')
q = lambda v, p: v[min(len(v)-1, int(round(p*(len(v)-1))))]
print(q(raw,.5), q(wire,.5), q(wire,.95), wire[-1], bad)
PY
)
EOF2

echo "p50_raw=$P50_RAW p50=$P50 p95=$P95 worst=$WORST roundtrip_failures=$BAD (n=200)"
STATUS=FAIL
[ "$P50" -le 80 ] && [ "$P95" -le 100 ] && [ "$BAD" -eq 0 ] && STATUS=PASS
tsv_row_replace "Text" "${P50_RAW}B" "${P50}B" "$(wire_time_2kbps "$P50")" "n/a" "$STATUS"
echo "gate_1 -> $STATUS (p50=${P50}B p95=${P95}B worst=${WORST}B)"
[ "$STATUS" = PASS ]
