#!/usr/bin/env bash
# Make sure the Docker daemon is running, or restart it.
#
#   ./scripts/dockerd-up.sh             start it if it is not running
#   ./scripts/dockerd-up.sh --restart   stop and start it again
#
# WSL2 distros normally run WSL's own init rather than systemd, so there is no
# docker.service: "systemctl restart docker" and "service docker restart" both
# fail, and dockerd does not start at boot. Run this once per WSL session
# before "docker compose up" (the ./scripts/*.sh entry points call it for you).

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

command -v dockerd >/dev/null 2>&1 \
  || die "dockerd is not installed — sudo apt install -y docker.io docker-compose-v2"

if [[ "${1:-}" == "--restart" ]]; then
  printf 'Stopping dockerd (running containers will stop too)...\n'
  sudo pkill -TERM dockerd 2>/dev/null || true
  for _ in $(seq 1 30); do
    pgrep -x dockerd >/dev/null 2>&1 || break
    sleep 1
  done
  # SIGKILL only if it ignored the polite request.
  if pgrep -x dockerd >/dev/null 2>&1; then
    printf 'dockerd did not exit; forcing.\n'
    sudo pkill -KILL dockerd 2>/dev/null || true
    sleep 2
  fi
  # A stale socket left by a hard kill blocks the next bind.
  [[ -S /var/run/docker.sock ]] && sudo rm -f /var/run/docker.sock
elif "${DOCKER[@]}" info >/dev/null 2>&1; then
  printf 'Docker is already running (server %s).\n' \
    "$("${DOCKER[@]}" info --format '{{.ServerVersion}}' 2>/dev/null)"
  exit 0
fi

ensure_dockerd
printf 'Docker is up (server %s).\n' \
  "$("${DOCKER[@]}" info --format '{{.ServerVersion}}' 2>/dev/null)"
