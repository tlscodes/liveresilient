#!/bin/bash
# Rebuildable local voice-clone environment (Intel mac, torch<=2.2.2 ceiling).
# Durable location so a session-scratchpad wipe costs nothing next time.
set -euo pipefail
ENV=~/.cache/hamseda_ttsenv
PY=/usr/local/opt/python@3.11/bin/python3.11

if [ ! -x "$ENV/bin/python" ]; then
  "$PY" -m venv "$ENV"
fi
"$ENV/bin/pip" install -q --only-binary :all: \
  "llvmlite==0.42.0" "numba==0.59.1" "torch==2.2.2" "torchaudio==2.2.2"
"$ENV/bin/pip" install -q "TTS==0.22.0" "transformers==4.40.2"
"$ENV/bin/python" - <<'EOF'
import torch, TTS
print("VOICE-CLONE ENV OK  torch", torch.__version__)
EOF
