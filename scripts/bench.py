"""Measure generation throughput against a running llama-server.

Sampling is greedy (temperature 0) and token counts are fixed, so runs are
comparable across speculative-decoding settings.
"""

import argparse
import json
import sys
import urllib.error
import urllib.request

# n-gram speculation drafts from text already in the context, so its benefit
# depends enormously on how much the output echoes the input. These three
# scenarios span that range deliberately.
SOURCE = """def fetch_user(uid):
    conn = db.connect(DSN)
    row = conn.execute("SELECT id, name, email FROM users WHERE id = ?", uid)
    if row is None:
        return None
    return {"id": row[0], "name": row[1], "email": row[2]}
"""

SCENARIOS = {
    "open": (
        "Explain why integrated GPUs are usually limited by memory bandwidth "
        "rather than raw compute. Write one detailed paragraph."
    ),
    "edit": (
        "Repeat the following text back verbatim, then add one short closing "
        "sentence:\n\n" + SOURCE
    ),
    "code": (
        "Rewrite this function to add a type hint and a docstring. Keep all "
        "other lines identical and output the whole function:\n\n" + SOURCE
    ),
}


def run(base: str, prompt: str, max_tokens: int) -> dict:
    body = json.dumps({
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "seed": 1234,
        "cache_prompt": False,
    }).encode()
    req = urllib.request.Request(
        f"{base}/v1/chat/completions",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=600) as resp:
        return json.loads(resp.read())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://localhost:8080")
    ap.add_argument("--max-tokens", type=int, default=200)
    ap.add_argument("--label", default="")
    ap.add_argument("--show-timing-keys", action="store_true",
                    help="dump the raw timings object (to discover draft stats)")
    args = ap.parse_args()

    # Warm-up: the first request pays one-off setup costs.
    try:
        run(args.base, "Say OK.", 8)
    except urllib.error.URLError as exc:
        print(f"cannot reach {args.base}: {exc}", file=sys.stderr)
        return 1

    if args.label:
        print(f"\n### {args.label}")
    print(f"{'scenario':<10} {'tok/s':>8} {'tokens':>8}   {'accept':>8}")
    print("-" * 40)

    results = {}
    for name, prompt in SCENARIOS.items():
        r = run(args.base, prompt, args.max_tokens)
        t = r.get("timings") or {}
        rate = t.get("predicted_per_second") or 0.0
        n = int(t.get("predicted_n") or 0)

        # Acceptance rate is what tells you whether speculation actually paid
        # off; key names vary by build, so probe several.
        acc = ""
        drafted = t.get("draft_n") or t.get("n_draft") or 0
        accepted = t.get("draft_n_accepted") or t.get("n_draft_accepted") or 0
        if drafted:
            acc = f"{100.0 * accepted / drafted:.0f}%"

        results[name] = rate
        print(f"{name:<10} {rate:>8.1f} {n:>8}   {acc:>8}")

        if args.show_timing_keys:
            print(f"    raw timings: {json.dumps(t)}")

    print(json.dumps({"label": args.label, "rates": results}), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
