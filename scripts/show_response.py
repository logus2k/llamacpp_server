"""Pretty-print a llama.cpp /v1/chat/completions response. Reads JSON on stdin."""

import json
import sys


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"could not parse the server response: {exc}", file=sys.stderr)
        return 1

    if "error" in payload:
        print(f"server error: {payload['error']}", file=sys.stderr)
        return 1

    choices = payload.get("choices") or []
    if choices:
        print(choices[0].get("message", {}).get("content", "").strip())

    # llama.cpp adds a non-standard "timings" block; "usage" is the fallback.
    timings = payload.get("timings") or {}
    if timings:
        print("\n== Throughput (measured by llama.cpp) ==")
        prompt_rate = timings.get("prompt_per_second")
        gen_rate = timings.get("predicted_per_second")
        if prompt_rate:
            n = int(timings.get("prompt_n", 0))
            print(f"  prompt eval : {prompt_rate:8.1f} tok/s  ({n} tokens)")
        if gen_rate:
            n = int(timings.get("predicted_n", 0))
            print(f"  generation  : {gen_rate:8.1f} tok/s  ({n} tokens)")
    elif payload.get("usage"):
        usage = payload["usage"]
        print("\n== Tokens ==")
        print(
            f"  prompt {usage.get('prompt_tokens')}, "
            f"completion {usage.get('completion_tokens')}"
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
