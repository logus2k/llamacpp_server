# Setting this up on another PC

For a Windows laptop with an Intel Arc GPU, running Ubuntu under WSL2.

## 1. Prerequisites on the Windows side

- A current **Intel Arc graphics driver**. This is what makes the GPU visible
  to WSL; an outdated driver is the most common cause of failure.
- WSL2 with an Ubuntu distro.

## 2. One-time setup inside WSL

```bash
# Docker and the compose plugin
sudo apt update && sudo apt install -y docker.io docker-compose-v2

# Make Docker start automatically. WSL distros normally run WSL's own init
# rather than systemd, so without this there is no docker.service and you
# get "failed to connect to the docker API" on every new session.
echo -e '[boot]\nsystemd=true' | sudo tee -a /etc/wsl.conf
```

Then, from **PowerShell** on Windows (not inside WSL):

```powershell
wsl --shutdown
```

Reopen the terminal and run once:

```bash
sudo systemctl enable --now docker
```

## 3. Check it

```bash
sudo docker info | grep "Server Version"   # daemon is up
ls -l /dev/dxg                             # GPU is visible to WSL
```

`/dev/dxg` missing means the Windows graphics driver needs updating, followed
by another `wsl --shutdown`.

## 4. Get the code and the models

```bash
git clone <this repo>
cd llamacpp_server
```

`models/` is **git-ignored**, so the weights are not in the clone. Copy these
across separately (~6.2 GB total) into `models/`:

| File | Size | Purpose |
|---|---|---|
| `gemma-4-E4B-it-UD-Q4_K_XL.gguf` | 5.1 GB | the model |
| `mmproj-F16.gguf` | 990 MB | vision (optional) |
| `mtp-gemma-4-E4B-it.gguf` | 99 MB | speculative decoding (large speedup) |

Keep them on the Linux filesystem (`~/...`), **not** under `/mnt/c`. Reads
from the Windows drive are several times slower, which shows up directly as a
slower model load.

## 5. Run it

```bash
./scripts/gpu-check.sh        # confirm the GPU is visible inside the container
sudo docker compose up -d     # start (first run pulls a 13.6 GB image)
./scripts/status.sh           # loading / ready / stuck
```

First load takes ~80 seconds. Then open <http://localhost:8080>.

## If something goes wrong

```bash
./scripts/status.sh                  # the single most useful command
sudo docker compose logs --tail 30   # why it failed
./scripts/dockerd-up.sh              # daemon not running (if you skipped systemd)
```

The web UI shows "loading model" both while it is genuinely loading and when
it is stuck — `./scripts/status.sh` distinguishes the two. Full troubleshooting
is in [README.md](README.md).
