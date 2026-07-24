#!/bin/bash
# Fetch the 5-candidate on-device model pool for the offline-assistant bake-off.
# Four phone-class candidates (<=600MB) + one over-budget quality reference.
set -euo pipefail
cd "$(dirname "$0")/../models"
TOK="$(cat ~/.cache/huggingface/token)"
fetch() { # fetch <local-name> <repo> <file>
  [ -s "$1" ] && { echo "SKIP $1 (exists)"; return; }
  echo "GET  $1"
  curl -sL -H "Authorization: Bearer $TOK" -o "$1" \
    "https://huggingface.co/$2/resolve/main/$3"
  echo "DONE $1 $(stat -f%z "$1") bytes"
}
fetch gemma3-1b-it-q4.litertlm litert-community/Gemma3-1B-IT Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm &
fetch gemma3-270m-it-q8.litertlm litert-community/gemma-3-270m-it gemma3-270m-it-q8.litertlm &
fetch smollm2-135m-it.litertlm litert-community/SmolLM2-135M-Instruct SmolLM2_135M_Instruct.litertlm &
fetch qwen3-1.7b-reference.litertlm litert-community/Qwen3-1.7B Qwen3_1.7B.litertlm &
wait
ls -lh .
