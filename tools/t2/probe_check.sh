#!/bin/bash
# Which of the three resolver nonces reached our responder first?
# Reads the responder log (tools/t2/txt_query_server.py "probe group=" lines).
#
#   NL=user@host LOG=/path/to/valve.log bash tools/t2/probe_check.sh [group]
#   LOG=/local/valve.log bash tools/t2/probe_check.sh [group]      (no NL: local file)
#
# Without [group]: the latest probe group in the log. Match the group with the
# phone's "LETTER probe group=<id> winner=<i> <label>:<nonce>:<rank> ..." line.
set -u
: "${LOG:?set LOG to the responder log path}"
if [ -n "${NL:-}" ]; then
  lines=$(ssh -o ConnectTimeout=10 "$NL" "grep 'probe group=' '$LOG'")
else
  lines=$(grep 'probe group=' "$LOG")
fi
[ -z "$lines" ] && { echo "NO PROBE in $LOG — no nonce reached the responder (the letter is queued)"; exit 2; }
group=${1:-$(echo "$lines" | tail -n 1 | sed -E 's/.*probe group=([0-9a-f]+).*/\1/')}
echo "$lines" | grep "group=$group" | sed -E 's/^([0-9-]+ [0-9:,]+) probe group=([0-9a-f]+) nonce=([0-9a-f]+) rank=([0-9]+) winner=([0-9a-f]+) source=(.*)$/\1  nonce=\3  rank=\4  source=\6  winner=\5/'
n=$(echo "$lines" | grep -c "group=$group")
w=$(echo "$lines" | grep "group=$group" | head -n 1 | sed -E 's/.*winner=([0-9a-f]+).*/\1/')
echo "group=$group  nonces_logged=$n/3  WINNER nonce=$w"
