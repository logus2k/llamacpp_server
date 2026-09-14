#!/usr/bin/env bash
# Show whether the server is still loading, serving, or stuck.
#
# The web UI shows "loading model" for both a healthy load (~80 s here) and a
# wedged one, so check here before killing anything.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if ! "${DOCKER[@]}" info >/dev/null 2>&1; then
  printf 'Docker daemon: NOT running — ./scripts/dockerd-up.sh\n'
  exit 1
fi

if ! container_exists; then
  printf 'Container    : does not exist — ./scripts/start.sh\n'
  exit 1
fi

state="$("${DOCKER[@]}" inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)"
health="$("${DOCKER[@]}" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER_NAME" 2>/dev/null)"
exitcode="$("${DOCKER[@]}" inspect --format '{{.State.ExitCode}}' "$CONTAINER_NAME" 2>/dev/null)"
started="$("${DOCKER[@]}" inspect --format '{{.State.StartedAt}}' "$CONTAINER_NAME" 2>/dev/null)"

printf 'Container    : %s (health: %s)\n' "$state" "$health"
printf 'Started at   : %s\n' "$started"

# Seconds since start, to judge whether a load is merely slow.
if age=$(( $(date +%s) - $(date -d "$started" +%s) )) 2>/dev/null; then
  printf 'Running for  : %ss\n' "$age"
fi

if [[ "$state" != "running" ]]; then
  printf 'Exit code    : %s\n' "$exitcode"
  # 137 = SIGKILL, which on this box almost always means out of memory.
  [[ "$exitcode" == "137" ]] \
    && printf '  -> 137 = killed, almost certainly out of memory.\n     Lower CTX_SIZE in .env, or give WSL more RAM in .wslconfig.\n'
  printf '\nLast log lines:\n'
  "${DOCKER[@]}" logs --tail 15 "$CONTAINER_NAME" 2>&1 | grep -v 'zesInit failed' | sed 's/^/  /'
  exit 1
fi

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:$PORT/health" 2>/dev/null)"
case "$code" in
  200) printf 'HTTP /health : 200 — server is READY\n' ;;
  503) printf 'HTTP /health : 503 — still loading the model (normal for ~80s)\n' ;;
  000) printf 'HTTP /health : no response — port %s not answering yet\n' "$PORT" ;;
  *)   printf 'HTTP /health : %s\n' "$code" ;;
esac

printf '\nMemory (host, %s total):\n' "$(free -h | awk '/^Mem:/{print $2}')"
free -h | awk '/^Mem:/{printf "  used %s, available %s\n", $3, $7}'

printf '\nLast log lines:\n'
"${DOCKER[@]}" logs --tail 8 "$CONTAINER_NAME" 2>&1 | grep -v 'zesInit failed' | sed 's/^/  /'
