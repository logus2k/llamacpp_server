#!/usr/bin/env bash
# Compare generation throughput across speculative-decoding modes.
#
#   ./scripts/bench.sh                          # default comparison set
#   ./scripts/bench.sh none ngram-simple        # only these modes
#   BENCH_TOKENS=400 ./scripts/bench.sh         # longer generations
#
# Each mode restarts the server, so a full run takes a few minutes.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

configs=("$@")
(( ${#configs[@]} )) || configs=(none ngram-simple ngram-mod ngram-cache)

summary="$(mktemp)"
trap 'rm -f "$summary"' EXIT

for cfg in "${configs[@]}"; do
  printf '\n=== restarting with spec-type: %s ===\n' "$cfg"
  start_log="$(mktemp)"
  if ! SPEC_TYPE_OVERRIDE="$cfg" "$HERE/start.sh" >"$start_log" 2>&1; then
    printf 'server failed to start for "%s" — skipping. Reason:\n' "$cfg"
    sed 's/^/    /' "$start_log" | tail -12
    rm -f "$start_log"
    continue
  fi
  rm -f "$start_log"
  # bench.py prints the table on stdout and a JSON line on stderr.
  python3 "$HERE/bench.py" \
      --label "$cfg" \
      --max-tokens "${BENCH_TOKENS:-200}" \
    2>>"$summary"
done

printf '\n===== summary (tok/s, higher is better) =====\n'
python3 - "$summary" <<'PY'
import json, sys

rows = []
for line in open(sys.argv[1]):
    line = line.strip()
    if line.startswith("{"):
        rows.append(json.loads(line))
if not rows:
    print("no results")
    raise SystemExit(0)

scenarios = list(rows[0]["rates"])
width = max(len(r["label"]) for r in rows) + 2
print("mode".ljust(width) + "".join(s.rjust(10) for s in scenarios))
print("-" * (width + 10 * len(scenarios)))

base = rows[0]["rates"]
for r in rows:
    line = r["label"].ljust(width)
    for s in scenarios:
        line += f"{r['rates'].get(s, 0):10.1f}"
    print(line)

# Relative change against the first mode benchmarked.
if len(rows) > 1:
    print("\nchange vs " + rows[0]["label"] + ":")
    for r in rows[1:]:
        parts = []
        for s in scenarios:
            b, v = base.get(s, 0), r["rates"].get(s, 0)
            parts.append(f"{s} {((v / b - 1) * 100):+.0f}%" if b else f"{s} n/a")
        print("  " + r["label"].ljust(width) + "  ".join(parts))
PY
