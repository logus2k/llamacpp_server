#!/usr/bin/env bash
# Shared configuration and helpers for the llama.cpp SYCL server.
# Not meant to be run directly — the other scripts source it.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODELS_DIR="$PROJECT_DIR/models"

# ---- defaults; overridden by .env ----------------------------------------
IMAGE="ghcr.io/ggml-org/llama.cpp:server-intel"
CONTAINER_NAME="llamacpp-arc"
PORT="8080"
MODEL=""
N_GPU_LAYERS="99"
CTX_SIZE="4096"
THREADS="4"
EXTRA_ARGS=""

# shellcheck source=/dev/null
[[ -f "$PROJECT_DIR/.env" ]] && source "$PROJECT_DIR/.env"

# .env deliberately wins over the ambient environment, so bench.sh uses these
# explicit hooks to A/B a setting without rewriting the file.
[[ -n "${SPEC_TYPE_OVERRIDE+x}" ]] && SPEC_TYPE="$SPEC_TYPE_OVERRIDE"
[[ -n "${SPEC_DRAFT_MODEL_OVERRIDE+x}" ]] && SPEC_DRAFT_MODEL="$SPEC_DRAFT_MODEL_OVERRIDE"
[[ -n "${SPEC_DRAFT_N_MAX_OVERRIDE+x}" ]] && SPEC_DRAFT_N_MAX="$SPEC_DRAFT_N_MAX_OVERRIDE"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# This WSL distro has no docker group membership for the user, so sudo is the
# normal path; skip it if the user has since been added to the group.
if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
  DOCKER=(docker)
else
  DOCKER=(sudo docker)
fi

# ---- WSL2 GPU passthrough -------------------------------------------------
# There is no /dev/dri under WSL2. The Intel GPU is reached through /dev/dxg,
# and libdxcore.so (from the Windows driver store, mounted at /usr/lib/wsl)
# is what bridges Level Zero to it. BOTH the lib dir and the drivers dir are
# required — mounting only /usr/lib/wsl/lib silently falls back to CPU.
GPU_ARGS=(
  --device=/dev/dxg
  -v /usr/lib/wsl:/usr/lib/wsl:ro
)

# /usr/lib/wsl/lib must be PREPENDED to the image's own LD_LIBRARY_PATH.
# Using a shell prelude (rather than -e LD_LIBRARY_PATH=...) keeps the
# image's long oneAPI path list intact across image updates.
LD_PRELUDE='export LD_LIBRARY_PATH=/usr/lib/wsl/lib:$LD_LIBRARY_PATH;'

# Force the Level Zero GPU so SYCL cannot quietly pick the CPU device.
ENV_ARGS=(
  -e ZES_ENABLE_SYSMAN=1
  -e ONEAPI_DEVICE_SELECTOR=level_zero:0
)

ensure_gpu_node() {
  [[ -e /dev/dxg ]] || die "/dev/dxg is missing — WSL2 GPU passthrough is unavailable.
  Update the Intel Arc driver on Windows, then run 'wsl --shutdown' from PowerShell."
}

# No systemd in this distro, so dockerd does not come up on its own.
ensure_dockerd() {
  if ! "${DOCKER[@]}" info >/dev/null 2>&1; then
    printf 'Docker daemon is not running (no systemd in this WSL distro) — starting it...\n'
    sudo nohup dockerd >/tmp/dockerd.log 2>&1 &
    local i
    for i in $(seq 1 30); do
      "${DOCKER[@]}" info >/dev/null 2>&1 && break
      sleep 1
    done
    "${DOCKER[@]}" info >/dev/null 2>&1 \
      || die "could not start dockerd — see /tmp/dockerd.log"
  fi
}

# Ask llama-server which compute devices it can see. Emits a line like
# "SYCL0: Intel(R) Graphics [0x64a0] (16823 MiB, 16823 MiB free)".
gpu_device_line() {
  "${DOCKER[@]}" run --rm "${GPU_ARGS[@]}" "${ENV_ARGS[@]}" \
    --entrypoint /bin/bash "$IMAGE" \
    -c "$LD_PRELUDE /app/llama-server --list-devices" 2>/dev/null \
    | grep -E '^[[:space:]]*SYCL[0-9]' | sed 's/^[[:space:]]*//' | head -1 \
    || printf '(device query failed)\n'
}

container_running() {
  "${DOCKER[@]}" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"
}

container_exists() {
  "${DOCKER[@]}" ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"
}

# Decide which .gguf to serve: explicit MODEL, else the sole model present.
# Extra shards of a sharded model are filtered out so only shard 1 is offered.
resolve_model() {
  if [[ -n "$MODEL" ]]; then
    [[ -f "$MODELS_DIR/$MODEL" ]] || die "MODEL '$MODEL' not found in $MODELS_DIR"
    printf '%s\n' "$MODEL"
    return
  fi

  local -a found=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && found+=("$f")
  done < <(
    find "$MODELS_DIR" -maxdepth 1 -type f -name '*.gguf' -printf '%f\n' 2>/dev/null \
      | awk '!/-[0-9]+-of-[0-9]+\.gguf$/ || /-0*1-of-[0-9]+\.gguf$/' \
      | grep -viE '^(mmproj|mtp)[-_.]' \
      | sort
  )

  if (( ${#found[@]} == 0 )); then
    # A browser or CLI download still in flight is the usual reason.
    local -a partial=()
    while IFS= read -r f; do
      [[ -n "$f" ]] && partial+=("$f")
    done < <(
      find "$MODELS_DIR" -maxdepth 1 -type f \
           \( -name '*.crdownload' -o -name '*.part' -o -name '*.tmp' \
              -o -name '*.download' \) -printf '%f\n' 2>/dev/null
    )
    if (( ${#partial[@]} > 0 )); then
      printf 'A download still looks incomplete in %s:\n' "$MODELS_DIR" >&2
      printf '  %s\n' "${partial[@]}" >&2
      die "wait for it to finish, then rename it to end in .gguf"
    fi
    die "no .gguf in $MODELS_DIR — put a model there, or set MODEL in .env"
  fi

  if (( ${#found[@]} > 1 )); then
    printf 'Several models are present in %s:\n' "$MODELS_DIR" >&2
    printf '  %s\n' "${found[@]}" >&2
    die "set MODEL in .env to pick one"
  fi

  printf '%s\n' "${found[0]}"
}
