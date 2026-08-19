#!/bin/bash
# Gate 6 — NewsPage: reference page wire size <= 1536B, parse round-trip exact,
# embedded image representation <= 500B.
# Wire format measured: canonical CBOR encoding of the page + brotli -q 11,
# full brotli stream as emitted.
# Build prerequisites (peak 6 build step):
#   packages/broadcast_media/lib/src/compact_news_codec.dart
#   tools/phase5/measure_news.py   (CBOR+brotli measurer, prints TSV + roundtrip)
set -euo pipefail
. "$(dirname "$0")/gate_lib.sh"
gate_log 6

if [ "${GATE_CHECK_ONLY:-0}" = "1" ]; then
  [ -f "$PHASE5_DIR/logs/news_sizes.tsv" ] || die "no measurement evidence"
  require_row "NewsPage" '^PASS'
  echo "gate_6 check-only OK"
  exit 0
fi

verify_asset news_ref_page.json
[ -f "$PHASE5_DIR/measure_news.py" ] || die "measure_news.py not built yet"

# measure_news.py prints: raw_bytes cbor_bytes wire_bytes image_bytes roundtrip(ok|FAIL)
OUT=$(python3 "$PHASE5_DIR/measure_news.py" "$CORPUS/news_ref_page.json")
echo "$OUT" > "$PHASE5_DIR/logs/news_sizes.tsv"
read -r RAW CBOR WIRE IMG RT <<< "$OUT"

echo "raw=$RAW cbor=$CBOR wire=$WIRE image_repr=$IMG roundtrip=$RT"
STATUS=FAIL
[ "$WIRE" -le 1536 ] && [ "$IMG" -le 500 ] && [ "$RT" = "ok" ] && STATUS=PASS
tsv_row_replace "NewsPage" "${RAW}B" "${WIRE}B" "$(wire_time_2kbps "$WIRE")" "n/a" "$STATUS"
echo "gate_6 -> $STATUS (wire=${WIRE}B budget=1536B)"
[ "$STATUS" = PASS ]
