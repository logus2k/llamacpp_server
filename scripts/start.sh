#!/usr/bin/env bash
# Start the llama.cpp server on the Intel Arc GPU.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ensure_gpu_node
ensure_dockerd

model="$(resolve_model)"

# Replace any previous container so re-running start.sh is idempotent.
if container_exists; then
  printf 'Removing previous container %s...\n' "$CONTAINER_NAME"
  "${DOCKER[@]}" rm -f "$CONTAINER_NAME" >/dev/null
fi

printf 'Model      : %s\n' "$model"
printf 'GPU layers : %s\n' "$N_GPU_LAYERS"
printf 'Context    : %s\n' "$CTX_SIZE"
printf 'Endpoint   : http://localhost:%s\n' "$PORT"

# The vision projector is a sidecar file, loaded alongside the main model.
vision_env=()
if [[ -n "${MMPROJ:-}" ]]; then
  [[ -f "$MODELS_DIR/$MMPROJ" ]] \
    || die "MMPROJ '$MMPROJ' not found in $MODELS_DIR"
  vision_env+=(-e "LLAMA_ARG_MMPROJ=/models/$MMPROJ")
  printf 'Vision     : %s\n' "$MMPROJ"
fi

# Speculative decoding is opt-in via SPEC_TYPE; ngram modes need no draft model.
spec_env=()
if [[ -n "${SPEC_TYPE:-}" && "${SPEC_TYPE}" != "none" ]]; then
  spec_env+=(-e "LLAMA_ARG_SPEC_TYPE=$SPEC_TYPE")
  printf 'Spec type  : %s\n' "$SPEC_TYPE"

  if [[ -n "${SPEC_DRAFT_MODEL:-}" ]]; then
    [[ -f "$MODELS_DIR/$SPEC_DRAFT_MODEL" ]] \
      || die "SPEC_DRAFT_MODEL '$SPEC_DRAFT_MODEL' not found in $MODELS_DIR"
    spec_env+=(
      -e "LLAMA_ARG_SPEC_DRAFT_MODEL=/models/$SPEC_DRAFT_MODEL"
      -e "LLAMA_ARG_N_GPU_LAYERS_DRAFT=${SPEC_DRAFT_NGL:-99}"
    )
    printf 'Draft model: %s\n' "$SPEC_DRAFT_MODEL"
  elif [[ "$SPEC_TYPE" == draft-* ]]; then
    die "SPEC_TYPE '$SPEC_TYPE' needs a draft model — set SPEC_DRAFT_MODEL in .env"
  fi

  [[ -n "${SPEC_DRAFT_N_MAX:-}" ]] \
    && spec_env+=(-e "LLAMA_ARG_SPEC_DRAFT_N_MAX=$SPEC_DRAFT_N_MAX")
fi
printf '\n'

# Settings go in as LLAMA_ARG_* environment variables rather than command-line
# flags: the container command is a shell string, and a model filename with
# spaces or non-ASCII characters would otherwise be word-split.
"${DOCKER[@]}" run -d \
  --name "$CONTAINER_NAME" \
  "${GPU_ARGS[@]}" \
  "${ENV_ARGS[@]}" \
  -v "$MODELS_DIR":/models:ro \
  -p "$PORT:$PORT" \
  -e LLAMA_ARG_MODEL="/models/$model" \
  -e LLAMA_ARG_N_GPU_LAYERS="$N_GPU_LAYERS" \
  -e LLAMA_ARG_CTX_SIZE="$CTX_SIZE" \
  -e LLAMA_ARG_THREADS="$THREADS" \
  -e LLAMA_ARG_HOST="0.0.0.0" \
  -e LLAMA_ARG_PORT="$PORT" \
  ${spec_env[@]+"${spec_env[@]}"} \
  ${vision_env[@]+"${vision_env[@]}"} \
  --entrypoint /bin/bash \
  "$IMAGE" \
  -c "$LD_PRELUDE exec /app/llama-server $EXTRA_ARGS" >/dev/null

printf 'Waiting for the model to load'
for _ in $(seq 1 300); do
  if ! container_running; then
    printf '\n\nThe container exited. Last log lines:\n\n'
    "${DOCKER[@]}" logs --tail 40 "$CONTAINER_NAME" 2>&1
    exit 1
  fi
  if curl -fsS "http://localhost:$PORT/health" >/dev/null 2>&1; then
    printf '\n\nServer is up.\n'
    printf '  Web UI : http://localhost:%s\n' "$PORT"
    printf '  API    : http://localhost:%s/v1/chat/completions\n\n' "$PORT"
    # Confirm the SYCL backend initialised. This build does not log the
    # classic "offloading N layers to GPU" line, so the check looks for any
    # SYCL mention (ggml's own messages qualify) rather than that phrasing.
    # Captured first: a `grep -q` on a live pipe would SIGPIPE docker and,
    # under `pipefail`, look like a failure.
    srv_log="$("${DOCKER[@]}" logs "$CONTAINER_NAME" 2>&1 || true)"
    if grep -qi 'sycl' <<<"$srv_log"; then
      printf 'SYCL backend active. Device:\n'
      printf '  %s\n' "$(gpu_device_line)"
      printf '\nThis build does not log per-layer offload; to see the GPU working,\n'
      printf 'run ./scripts/test-chat.sh and watch Task Manager > GPU > Compute.\n'
    else
      printf 'WARNING: no SYCL activity in the logs — the model may be on the CPU.\n'
      printf 'Run ./scripts/gpu-check.sh to diagnose.\n'
    fi
    exit 0
  fi
  printf '.'
  sleep 1
done

printf '\n\nTimed out waiting for /health. Recent logs:\n\n'
"${DOCKER[@]}" logs --tail 40 "$CONTAINER_NAME" 2>&1
exit 1
