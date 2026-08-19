#!/bin/bash
# Peak 1 build — train the zstd chat dictionary (appendix C budget: <= 32KB,
# committed at packages/messaging/assets/zstd_chat.dict, 1-byte dictVer in the
# message schema, NOT a hash in the header).
# Training set: chat_train_2000.jsonl ONLY (seed 54) — never the 200-message
# eval set, so the dictionary learns substrings, not the eval strings.
set -euo pipefail
cd "$(dirname "$0")"

SAMPLES=$(mktemp -d)
trap 'rm -rf "$SAMPLES"' EXIT

python3 - "$SAMPLES" <<'PY'
import json, sys, pathlib
d = pathlib.Path(sys.argv[1])
src = pathlib.Path(__file__).resolve()
for i, line in enumerate(open("corpus/chat_train_2000.jsonl", encoding="utf-8")):
    (d / f"s{i:04d}.txt").write_bytes(json.loads(line)["text"].encode("utf-8"))
PY

OUT=../../packages/messaging/assets/zstd_chat.dict
mkdir -p "$(dirname "$OUT")"
zstd --train "$SAMPLES"/*.txt -o "$OUT" --maxdict=32768 -f 2>&1 | grep -v '^!' || true

test -f "$OUT" || { echo "dict training produced nothing"; exit 1; }
BYTES=$(stat -f %z "$OUT")
[ "$BYTES" -le 32768 ] || { echo "dict over budget: $BYTES"; exit 1; }
shasum -a 256 "$OUT"
echo "DICT OK: $BYTES bytes (budget 32768)"
