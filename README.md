# llama.cpp server on the Intel Arc 140V (WSL2)

Serves a local GGUF model over an OpenAI-compatible HTTP API, running
inference on this laptop's integrated **Intel Arc 140V** GPU via the
llama.cpp **SYCL / Level Zero** backend, inside Docker.

Verified working on this machine — see [What was verified](#what-was-verified).

## Quick start

```bash
# 1. put a .gguf in ./models/   (one file; or set MODEL in .env)
# 2. confirm the GPU is visible inside the container
./scripts/gpu-check.sh
# 3. start the server
./scripts/start.sh
# 4. send a prompt
./scripts/test-chat.sh "Why is the sky blue?"
# 5. optional: send an image, and compare speculative-decoding modes
./scripts/test-vision.sh
./scripts/bench.sh
```

Web UI: <http://localhost:8080> · API: `http://localhost:8080/v1/chat/completions`

## Why the setup looks the way it does

This is the part that is specific to **Intel GPU + WSL2**, and the reason a
stock `docker run` from the llama.cpp docs does not work here.

On native Linux, Intel GPU containers get `--device /dev/dri`. **Under WSL2
there is no `/dev/dri` at all.** The GPU is reached through `/dev/dxg`, and the
translation to the real hardware is done by `libdxcore.so`, which WSL mounts
from the Windows driver store at `/usr/lib/wsl`. So three things are required:

| Requirement | Why |
|---|---|
| `--device=/dev/dxg` | the only GPU device node WSL2 exposes |
| `-v /usr/lib/wsl:/usr/lib/wsl:ro` | provides `libdxcore.so` **and** the Windows driver store |
| `LD_LIBRARY_PATH=/usr/lib/wsl/lib:$LD_LIBRARY_PATH` | so the loader finds `libdxcore.so` ahead of the image's oneAPI libs |

Two failure modes worth knowing, both found by testing here:

- **Mounting only `/usr/lib/wsl/lib` is not enough.** The `drivers/`
  subdirectory is needed too. Without it `sycl-ls` reports *only* the CPU —
  no error, and llama.cpp then quietly runs on the CPU at a fraction of the speed.
- **Overwriting `LD_LIBRARY_PATH` breaks oneAPI.** The image sets a long
  oneAPI library path. The scripts *prepend* via a shell prelude
  (`export LD_LIBRARY_PATH=/usr/lib/wsl/lib:$LD_LIBRARY_PATH; exec ...`)
  rather than passing `-e LD_LIBRARY_PATH=...`, so the setup keeps working
  when the image's oneAPI versions change.

The Level Zero GPU driver itself (`libze_intel_gpu.so`) ships **inside** the
`server-intel` image, so nothing needs installing in WSL.

`ONEAPI_DEVICE_SELECTOR=level_zero:0` pins execution to the GPU — the image
also exposes an OpenCL CPU device that SYCL could otherwise select.

## Files

```
.env                  configuration (model, port, context size, GPU layers)
docker-compose.yml    optional declarative alternative to start.sh
models/               put your .gguf files here
scripts/
  common.sh           shared config, GPU flags, model auto-detection
  dockerd-up.sh       start or restart the Docker daemon (no systemd here)
  gpu-check.sh        confirm the Arc GPU is visible to SYCL in-container
  start.sh            start the server, wait for /health, confirm GPU offload
  status.sh           loading / ready / stuck, plus memory and last logs
  stop.sh             stop and remove the container
  logs.sh             follow the container logs
  test-chat.sh        send a prompt, print the reply and tok/s
  test-vision.sh      send an image and check the model read it
  bench.sh            A/B throughput across speculative-decoding modes
  bench.py            the measurement harness bench.sh drives
  make_test_image.py  generates a PNG with known text (no image libraries)
  vision_request.py   helper: builds an image request
  build_request.py    helper: builds the chat request body
  show_response.py    helper: formats the reply and timings
```

## Configuration

Edit `.env`. The defaults suit this laptop.

| Variable | Default | Notes |
|---|---|---|
| `MODEL` | *(auto)* | filename in `models/`; auto-detects when exactly one `.gguf` is present |
| `PORT` | `8080` | host port for API and web UI |
| `N_GPU_LAYERS` | `99` | `99` offloads everything; lower to share with the CPU |
| `CTX_SIZE` | `4096` | context window; competes with weights for memory |
| `THREADS` | `4` | CPU threads for non-offloaded work |
| `EXTRA_ARGS` | *(empty)* | passed verbatim to `llama-server` |
| `SPEC_TYPE` | `draft-mtp` | speculative decoding mode; `none` disables |
| `SPEC_DRAFT_MODEL` | `mtp-…gguf` | draft model, for `draft-*` modes |
| `SPEC_DRAFT_NGL` | `99` | GPU layers for the draft model |
| `SPEC_DRAFT_N_MAX` | *(3)* | tokens speculated per step |
| `MMPROJ` | `mmproj-F16.gguf` | vision projector; empty for text-only |

Useful `EXTRA_ARGS`: `--jinja` (use the model's own chat template; needed for
tool calling), `--api-key <secret>` (require an `Authorization` header),
`-fa on` (force flash attention).

## Memory budget — the main constraint

The Arc 140V has **no dedicated VRAM**; it shares system memory. This WSL
instance has **~15 GiB total**, and the model weights plus the KV cache must
fit in it alongside everything else.

Rough guidance at Q4_K_M: a 4B model needs ~2.5 GB, an 8B ~5 GB, a 14B ~9 GB.
A 14B is close to the ceiling once the KV cache is included; raising
`CTX_SIZE` materially increases KV cache size. If the server is killed during
load or throughput collapses, reduce `CTX_SIZE` first, then `N_GPU_LAYERS`.

To give WSL more memory, set `memory=24GB` under `[wsl2]` in
`C:\Users\<you>\.wslconfig` on Windows and run `wsl --shutdown`.

## Two environment quirks on this machine

**Docker does not start automatically.** This WSL distro runs WSL's own init
rather than systemd, so there is no `docker.service` — `systemctl restart
docker` and `service docker restart` both fail, and `docker compose` reports
`failed to connect to the docker API at unix:///var/run/docker.sock`.

The `./scripts/*.sh` entry points start `dockerd` themselves (logging to
`/tmp/dockerd.log`), but `docker compose` does not, so run this once per WSL
session first:

```bash
./scripts/dockerd-up.sh              # start if not running
./scripts/dockerd-up.sh --restart    # stop and start again
```

By hand, the equivalents are:

```bash
sudo nohup dockerd > /tmp/dockerd.log 2>&1 &     # start
sudo pkill dockerd && sudo nohup dockerd > /tmp/dockerd.log 2>&1 &   # restart
```

Restarting the daemon stops running containers; bring the server back with
`sudo docker compose up -d`.

**Permanent fix — enable systemd.** Add this to `/etc/wsl.conf`:

```ini
[boot]
systemd=true
```

Then `wsl --shutdown` from PowerShell, reopen the terminal, and
`sudo systemctl enable --now docker`. Docker then starts at boot and the
usual `systemctl restart docker` works. This is worth doing on any machine
that will run the server regularly.

**Running it on another PC.** `models/` is git-ignored, so the ~6.2 GB of
weights must be copied across separately. On a second WSL2 machine with an
Intel GPU:

```bash
sudo apt install -y docker.io docker-compose-v2   # once
sudo nohup dockerd > /tmp/dockerd.log 2>&1 &      # no systemd under WSL
cd <this directory>                               # with models/ populated
sudo docker compose up -d
```

**Docker needs `sudo`.** `devuser` is not in the `docker` group, so the scripts
prefix `sudo` automatically. They skip it if the user is ever added to the group
(`sudo usermod -aG docker $USER`, then restart WSL) — note that group membership
is broadly equivalent to passwordless root, so it is left as your call.

## Speculative decoding

Speculation drafts several tokens cheaply, then the target model verifies them
in one batched pass. On this iGPU, generation is memory-bandwidth-bound, so
verifying a batch costs little more than generating one token — which is why
the wins below are large. The catch is that only *accepted* drafts help.

This build (`b10868`) offers two families:

- **`draft-mtp`** — uses `mtp-gemma-4-E4B-it.gguf`, a 98 MB Multi-Token
  Prediction head trained for this exact checkpoint. Tokenizer compatibility
  is guaranteed, which is normally the hard part of pairing a draft model.
- **n-gram modes** (`ngram-simple`, `ngram-mod`, `ngram-map-k`, `ngram-cache`)
  — draft from text already in the context. No draft model, no extra memory,
  but they only help when the output echoes the input.

Measured here (greedy sampling, 200-token generations, tok/s):

| mode | open prose | echo/edit | code edit |
|---|---|---|---|
| `none` | 22.2 | 22.5 | 22.3 |
| **`draft-mtp`** | **32.5** (+46%) | **50.9** (+126%) | **40.5** (+82%) |
| `ngram-simple` | 22.9 (+3%) | 32.1 (+43%) | 28.8 (+29%) |

Draft acceptance under `draft-mtp` was 46% / 91% / 75% respectively.

Draft length (`SPEC_DRAFT_N_MAX`) was swept; the default of 3 is the best of
those measured, because acceptance falls off as drafts get longer:

| `n_max` | open | edit | code | acceptance (open) |
|---|---|---|---|---|
| **3** (default) | **32.6** | **50.0** | **40.2** | 46% |
| 6 | 24.1 | 48.4 | 37.6 | 30% |

`draft-mtp` is the default in `.env` because it wins in every scenario. The
n-gram modes are worth knowing about for a model with no MTP head: they cost
nothing to try, but note they gave only +3% on open-ended prose, since there
is no repeated text to draft from.

Re-run the comparison at any time — each mode restarts the server, so a full
run takes several minutes:

```bash
./scripts/bench.sh                          # default set
./scripts/bench.sh none draft-mtp           # specific modes
BENCH_TOKENS=400 ./scripts/bench.sh         # longer generations
```

## Vision (multimodal)

`mmproj-F16.gguf` is the vision projector for this model; setting `MMPROJ` in
`.env` enables image input and costs ~1 GB of memory. Images are sent as
standard OpenAI-style `image_url` content parts (a base64 `data:` URI works,
so no server-side file access is needed).

```bash
./scripts/test-vision.sh                       # generated known-text image
./scripts/test-vision.sh photo.jpg "Describe this."
```

With no argument the script generates a PNG containing known text and checks
the reply for it, so the result is pass/fail rather than a judgement call.
Verified: the model read `ARC 742` from a generated image correctly.

## Talking to the server

The API is OpenAI-compatible, so existing clients work by pointing them at
the base URL. Any non-empty API key is accepted unless `--api-key` is set.

```bash
curl -s http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Hello"}],"max_tokens":100}'
```

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8080/v1", api_key="not-needed")
print(client.chat.completions.create(
    model="local",
    messages=[{"role": "user", "content": "Hello"}],
).choices[0].message.content)
```

Useful endpoints: `/health`, `/v1/models`, `/v1/chat/completions`,
`/v1/completions`, `/v1/embeddings`, `/props`, and `/metrics`
(Prometheus-format).

## A noisy warning you can ignore

The log fills with:

```
Warning: zesInit failed [ggml_check_sycl] with code 2013265921.
Sysman free-memory query may be unavailable.
```

The Level Zero *sysman* interface is unavailable through WSL's `/dev/dxg`, so
ggml cannot query free GPU memory. It is cosmetic — inference is unaffected —
but ggml repeats it for nearly every operation: on one run, 1194 of 1211 log
lines. It appears regardless of `ZES_ENABLE_SYSMAN`, so it cannot be switched
off. `./scripts/logs.sh` filters it out; use `--raw` to see everything.

## Confirming inference really used the GPU

`start.sh` checks this and prints the device line. To inspect manually:

```bash
./scripts/logs.sh | grep -iE 'sycl|device|offload'
```

Look for a `SYCL0` device named `Intel(R) Graphics [0x64a0]` and a line showing
layers offloaded to GPU. If you instead see all layers on CPU, re-run
`./scripts/gpu-check.sh`.

While generating, `Task Manager → Performance → GPU` on Windows should show
activity on the **Compute** engine (not 3D).

## Troubleshooting

**`/dev/dxg is missing`** — update the Intel Arc driver on Windows, then
`wsl --shutdown` in PowerShell and reopen the terminal.

**`gpu-check.sh` shows only CPU devices** — the `/usr/lib/wsl` mount or the
`LD_LIBRARY_PATH` prefix is not being applied; both are required.

**Server killed while loading, or the WSL session dies** — out of memory.
Lower `CTX_SIZE`, or raise the WSL memory limit in `.wslconfig`.

**Very slow generation** — the model is probably on the CPU. Confirm GPU
offload as above; also check `N_GPU_LAYERS` is high enough for the layer count.

**Port already in use** — change `PORT` in `.env`.

**Web UI spins on "loading model", or shows `Server Error: Loading model`** —
the server returns HTTP 503 with that text until the weights finish loading,
which takes ~80 s from cold here. The UI presents that as an error rather
than a wait, and it looks identical whether the load is progressing or wedged.
Check before killing anything:

```bash
./scripts/status.sh
```

It reports how long the container has been up, whether `/health` returns 503
(still loading) or 200 (ready), free memory, and the last log lines. If it
says READY, just reload the page.

To kill it — either works, whether it was started by `start.sh` or compose:

```bash
./scripts/stop.sh            # remove the container
sudo docker compose down     # same, and removes the compose network
sudo docker kill llamacpp-arc   # last resort if it ignores the above
```

Then start it again with `./scripts/start.sh` or `sudo docker compose up -d`.

If it never reaches READY, the usual causes are memory (exit code 137 — see
`status.sh`) and a benchmark running: `./scripts/bench.sh` restarts the server
for every mode, so the UI is unusable while it runs.

**`curl http://localhost:8080/` returns HTTP 415 "gzip is not supported by
this browser"** — expected, not a fault. The web UI is served gzip-compressed
and llama.cpp requires the client to advertise it. Browsers do; plain `curl`
does not. Use `curl --compressed` to fetch it from the shell.

## What was verified

On this machine (Intel Core Ultra 7 268V, Arc 140V, driver 32.0.101.8508,
Ubuntu 26.04 on WSL2 kernel 6.18.40.1, Docker 29.1.3, llama.cpp `b10868`)
with `gemma-4-E4B-it-UD-Q4_K_XL.gguf` (7.5B, 5.1 GB):

- **GPU is genuinely in use.** `sycl-ls` in-container reports
  `[level_zero:gpu] Intel(R) Graphics [0x64a0]`; `llama-server --list-devices`
  reports `SYCL0: Intel(R) Graphics [0x64a0] (16823 MiB)`; and during
  generation the Windows GPU **Compute** engine peaked at **90.8%**.
  Without the `/usr/lib/wsl` mount, only the CPU appears.
- **Generation works end to end**, ~22 tok/s unaccelerated.
- **Speculative decoding via the MTP head** raised this to 32.5–50.9 tok/s
  (+46% to +126%) — see [Speculative decoding](#speculative-decoding).
- **Vision works**: the model read `ARC 742` from a generated PNG.
- Model load takes roughly 75 seconds (5.1 GB, plus the 1 GB projector).

### Notes on this build

- `llama-server --help` **segfaults unless the GPU flags are present** — it
  initialises the SYCL backend while parsing arguments and aborts with
  "can not find preferred GPU platform". Pass the usual
  `--device`/`-v`/`LD_LIBRARY_PATH` arguments to read the help text.
- This build does **not** log the classic `offloading N layers to GPU` line,
  so its absence is not evidence of CPU fallback. `start.sh` reports the SYCL
  device from `--list-devices` instead.
