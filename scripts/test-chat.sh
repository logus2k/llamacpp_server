#!/usr/bin/env bash
# Send one prompt through the OpenAI-compatible endpoint and report the
# answer plus the throughput the server measured.
#
#   ./scripts/test-chat.sh "your prompt here"

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT="${*:-Explain in two sentences why integrated GPUs share system memory.}"
BASE="http://localhost:$PORT"

curl -fsS "$BASE/health" >/dev/null 2>&1 \
  || die "server is not answering on $BASE — run ./scripts/start.sh first"

printf '== Loaded model ==\n'
curl -fsS "$BASE/v1/models" \
  | python3 -c 'import json,sys; [print(" ", m.get("id","?")) for m in json.load(sys.stdin).get("data",[])]'

printf '\n== Prompt ==\n%s\n\n== Response ==\n' "$PROMPT"

python3 "$HERE/build_request.py" "$PROMPT" \
  | curl -fsS "$BASE/v1/chat/completions" \
      -H 'Content-Type: application/json' --data @- \
  | python3 "$HERE/show_response.py"

printf '\n'
