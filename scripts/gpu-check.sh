#!/usr/bin/env bash
# Verify the Intel Arc GPU is visible to SYCL *inside* the container.
# Run this first — without a level_zero gpu device, llama.cpp silently
# falls back to the CPU.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ensure_gpu_node
ensure_dockerd

printf '== Windows host GPU ==\n'
if [[ -x /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe ]]; then
  /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile \
    -Command "Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion | Format-Table -AutoSize" 2>/dev/null \
    | sed '/^[[:space:]]*$/d'
else
  printf '  (Windows interop unavailable — skipped)\n'
fi

# Enumerate every device, so the CPU fallback is visible for comparison.
# ONEAPI_DEVICE_SELECTOR is deliberately omitted here.
printf '\n== SYCL devices inside the container ==\n'
devices="$(
  "${DOCKER[@]}" run --rm "${GPU_ARGS[@]}" \
    --entrypoint /bin/bash "$IMAGE" \
    -c "$LD_PRELUDE sycl-ls" 2>&1
)" || die "could not run sycl-ls in the container"

printf '%s\n\n' "$devices"

# grep against the captured text, never a live pipe: under `pipefail` a
# `grep -q` short-circuit would otherwise SIGPIPE docker and fake a failure.
if grep -q 'level_zero:gpu' <<<"$devices"; then
  printf 'OK — the Arc GPU is reachable through Level Zero.\n'
else
  printf 'FAILED — no Level Zero GPU device; llama.cpp would run on the CPU.\n'
  printf 'Confirm /dev/dxg exists and the Intel driver on Windows is current,\n'
  printf 'then run "wsl --shutdown" from PowerShell and retry.\n'
  exit 1
fi
