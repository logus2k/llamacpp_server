#!/usr/bin/env bash
# Stop and remove the server container.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if ! "${DOCKER[@]}" info >/dev/null 2>&1; then
  printf 'Docker is not running — nothing to stop.\n'
  exit 0
fi

if container_exists; then
  "${DOCKER[@]}" rm -f "$CONTAINER_NAME" >/dev/null
  printf 'Stopped and removed %s.\n' "$CONTAINER_NAME"
else
  printf 'No container named %s.\n' "$CONTAINER_NAME"
fi
