#!/usr/bin/env bash
# Follow the server logs.
#
#   ./scripts/logs.sh            follow, hiding the harmless sysman warning
#   ./scripts/logs.sh --raw      follow, unfiltered
#   ./scripts/logs.sh --tail 50  any other args pass through to `docker logs`

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

container_exists || die "no container named $CONTAINER_NAME — start it first"

# Under WSL the Level Zero sysman (free-memory) query is unavailable, so ggml
# repeats this warning for nearly every operation — on one run it was 1194 of
# 1211 log lines. It is cosmetic, and hiding it makes the log readable.
NOISE='zesInit failed'

if [[ "${1:-}" == "--raw" ]]; then
  shift
  exec "${DOCKER[@]}" logs "${@:--f}" "$CONTAINER_NAME"
fi

"${DOCKER[@]}" logs "${@:--f}" "$CONTAINER_NAME" 2>&1 | grep --line-buffered -v "$NOISE"
