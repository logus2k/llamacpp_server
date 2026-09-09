#!/usr/bin/env bash
# Send an image to the server and print what the model sees.
#
#   ./scripts/test-vision.sh                        # generated text image
#   ./scripts/test-vision.sh photo.jpg "Describe this."
#
# Requires MMPROJ to be set in .env (the multimodal projector).

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="http://localhost:$PORT"

IMAGE="${1:-}"
PROMPT="${2:-What text is written in this image? Answer with just the text.}"

# With no image given, generate one whose contents are known, so the answer
# can be judged rather than merely read.
EXPECT=""
if [[ -z "$IMAGE" ]]; then
  EXPECT="ARC 742"
  IMAGE=/tmp/vision-test.png
  python3 "$HERE/make_test_image.py" --text "$EXPECT" --out "$IMAGE" >/dev/null
fi

[[ -f "$IMAGE" ]] || die "image not found: $IMAGE"
curl -fsS "$BASE/health" >/dev/null 2>&1 \
  || die "server is not answering on $BASE — run ./scripts/start.sh first"

printf 'Image  : %s\n' "$IMAGE"
[[ -n "$EXPECT" ]] && printf 'Expects: %s\n' "$EXPECT"
printf 'Prompt : %s\n\n== Response ==\n' "$PROMPT"

answer="$(
  python3 "$HERE/vision_request.py" "$IMAGE" --prompt "$PROMPT" \
    | curl -fsS "$BASE/v1/chat/completions" \
        -H 'Content-Type: application/json' --data @- \
    | python3 "$HERE/show_response.py"
)"
printf '%s\n' "$answer"

# Judge the generated case: the digits are the part a text-only model or a
# broken projector cannot guess.
if [[ -n "$EXPECT" ]]; then
  printf '\n'
  if grep -qiE '742' <<<"$answer"; then
    printf 'PASS — the model read the image.\n'
  else
    printf 'FAIL — "%s" not found in the reply; the projector may not be loaded.\n' "$EXPECT"
    exit 1
  fi
fi
