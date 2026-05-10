# LM Studio Headless Container

Run [LM Studio](https://lmstudio.ai/) as a headless OpenAI-compatible API server in Docker. Designed for painless deployment on **TrueNAS SCALE**, Unraid, Synology, or any Docker host.

Powered by [`llmster`](https://lmstudio.ai/docs/developer/core/headless), LM Studio's official server-native daemon — no virtual X server, no AppImage extraction, no GUI dependencies.

## Features

- **OpenAI-compatible REST API** on port `1234` — `/v1/chat/completions`, `/v1/completions`, `/v1/embeddings`, `/v1/models`
- **JIT model loading** — request a model that's been downloaded and it loads on demand; idle models auto-unload
- **Single persistent volume** at `/data` for models, config, and conversation history
- **NVIDIA GPU** support via the standard NVIDIA Container Toolkit (`--gpus all`)
- **Multi-arch** images: `linux/amd64` + `linux/arm64`
- **TrueNAS-friendly** defaults — runs as UID/GID `568` (the SCALE `apps` user), overridable via `PUID`/`PGID`
- **Self-updating** — weekly automated rebuilds pick up upstream LM Studio releases

---

## Quick start

### docker run

```bash
docker run -d --name lmstudio \
  -p 1234:1234 \
  -v lmstudio-data:/data \
  --restart unless-stopped \
  ghcr.io/CHANGE-ME/lmstudio-container:latest
```

With NVIDIA GPU:

```bash
docker run -d --name lmstudio \
  --gpus all \
  -p 1234:1234 \
  -v lmstudio-data:/data \
  --restart unless-stopped \
  ghcr.io/CHANGE-ME/lmstudio-container:latest
```

### docker compose

Copy `docker-compose.yml` from this repo, edit the image and host path, then:

```bash
docker compose up -d
docker compose logs -f
```

### Verify it's up

```bash
curl http://localhost:1234/v1/models
```

You should get a JSON response listing any models you've downloaded (empty `data` array on first start — see [Downloading models](#downloading-models)).

---

## TrueNAS SCALE deployment

Tested on TrueNAS SCALE 24.10+ (the Docker-based release).

### 1. Create a dataset for model storage

In the TrueNAS UI: **Datasets** → pick a pool → **Add Dataset**.

- **Name**: `lmstudio` (or whatever you like)
- **Dataset Preset**: `Apps`

This automatically sets ownership to UID/GID `568` (the `apps` user), which is what the container expects by default. Put it on an SSD/NVMe pool — model files are large and slow disks make first-load painful.

### 2. Install as a Custom App

**Apps** → **Discover Apps** → **Custom App** (top right).

#### Application Name
`lmstudio`

#### Image Configuration
| Field | Value |
| --- | --- |
| Image repository | `ghcr.io/CHANGE-ME/lmstudio-container` |
| Image tag | `latest` |
| Image pull policy | `Always` (so weekly rebuilds get picked up on app restart) |

#### Container Environment Variables
Add as needed:

| Name | Example | Purpose |
| --- | --- | --- |
| `PUID` | `568` | Match dataset owner. Default is `568`. |
| `PGID` | `568` | Match dataset group. Default is `568`. |
| `LMS_PORT` | `1234` | Internal API port (default `1234`). |
| `LMS_PREFETCH` | `qwen/qwen3-4b` | Optional. Space-separated models to download on first boot. |
| `LMS_LOAD` | `qwen/qwen3-4b` | Optional. Pre-load this model into memory at startup. |

#### Networking → Port Forwarding
| Container Port | Node Port | Protocol |
| --- | --- | --- |
| `1234` | `1234` (or any free port) | `TCP` |

#### Storage → Add Storage
| Type | Mount Path | Host Path |
| --- | --- | --- |
| `Host Path` | `/data` | the dataset you created in step 1, e.g. `/mnt/tank/lmstudio` |

#### Resources (optional, for NVIDIA GPU)
Toggle **GPU Resources** and assign your NVIDIA GPU to the container. TrueNAS SCALE injects the NVIDIA driver libraries automatically — the container itself doesn't need a CUDA base image.

#### Resources → Resource Limits
Bump the memory limit. LLMs are memory-hungry — give it at least `8 GiB`, more for larger models. CPU limits can stay at default unless you have specific isolation needs.

### 3. Install and verify

Click **Install**. Once the app is running, hit it from another machine on your network:

```bash
curl http://<truenas-ip>:1234/v1/models
```

---

## Downloading models

Once the container is up, you can either let `LMS_PREFETCH` handle it on first boot, or download manually with `lms get`:

```bash
docker exec -it lmstudio lms get qwen/qwen3-4b
docker exec -it lmstudio lms ls
```

Browse the catalog at <https://lmstudio.ai/models>. Use the slug (e.g. `qwen/qwen3-4b`, `lmstudio/llama-3.2-3b-instruct`) as the argument.

JIT loading means you don't need to pre-load — once a model is downloaded, it's available via the API and loads on the first request.

---

## Using the API

The API is OpenAI-compatible, so any tool that talks to OpenAI works against `http://<host>:1234/v1`:

```bash
curl http://<host>:1234/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen/qwen3-4b",
    "messages": [{"role": "user", "content": "What is the capital of France?"}]
  }'
```

Drop-in clients:

| Tool | Where to point it |
| --- | --- |
| Open WebUI | `OPENAI_API_BASE_URL=http://<host>:1234/v1`, any non-empty key |
| Continue.dev / Cline | `apiBase: http://<host>:1234/v1`, `provider: openai` |
| Anything-LLM | LLM provider: "Generic OpenAI", base URL `http://<host>:1234/v1` |
| Python SDK | `OpenAI(base_url="http://<host>:1234/v1", api_key="not-needed")` |

---

## Environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `PUID` | `568` | UID the lms process runs as. Match the owner of your `/data` mount. |
| `PGID` | `568` | GID the lms process runs as. |
| `LMS_PORT` | `1234` | Port the API listens on inside the container. |
| `LMS_HOST` | `0.0.0.0` | Bind address (informational). |
| `LMS_PREFETCH` | _(unset)_ | Space-separated list of model slugs to download on startup. |
| `LMS_LOAD` | _(unset)_ | Single model slug to load into memory at startup (optional). |

---

## Volumes

| Path | Contents |
| --- | --- |
| `/data` | LM Studio's full state directory: `.lmstudio/models/`, config, conversations, JIT cache. |

A single mount is intentional — keeps your TrueNAS app config simple and lets you snapshot/replicate the dataset as one unit.

---

## GPU support

### NVIDIA

Requires the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) on the host. TrueNAS SCALE has this preinstalled — just toggle the GPU resource on the app.

For raw Docker:

```bash
docker run --gpus all ...
```

### AMD / ROCm, Apple Silicon

LM Studio's bundled runtime supports ROCm on Linux and Metal on macOS, but Linux Docker GPU passthrough for AMD is fragile and depends on host driver versions. CPU-only mode works everywhere — performance scales with RAM bandwidth and core count.

### CPU-only

Just don't pass `--gpus`. Works on any host. Pick smaller quantized models (4-bit, ≤8B parameters) for usable throughput.

---

## Updating

Pull the new image and recreate the container — your `/data` volume is preserved:

```bash
docker compose pull && docker compose up -d
```

On TrueNAS SCALE, the `Always` pull policy plus a manual **Stop** → **Start** of the app does the same thing.

> **First-time setup gotcha:** GHCR creates new packages as **private** by default. After the workflow pushes the first image, go to your GitHub profile → **Packages** → `lmstudio-container` → **Package settings** → **Change visibility** → **Public**. Otherwise TrueNAS pulls will fail with `401 Unauthorized`.

---

## Troubleshooting

**`/v1/models` returns connection refused**
The daemon takes ~30–60s on first start while it bootstraps. Check `docker logs lmstudio`. The healthcheck has a 120s grace period for this.

**Permission denied writing to `/data`**
Your dataset is owned by a different UID than the container. Either re-chown the dataset (`chown -R 568:568 /mnt/tank/lmstudio`) or set `PUID`/`PGID` to whatever owns it.

**Model downloads fail or hang**
`lms get` pulls from Hugging Face. Verify the container has outbound HTTPS, and that your model slug is correct (`docker exec lmstudio lms get --help` lists usage).

**GPU not detected**
Inside the container: `docker exec lmstudio bash -c 'ls -la /dev/nvidia* 2>&1; nvidia-smi 2>&1 || true'`. If nothing shows, the host's NVIDIA Container Toolkit isn't wired through. Check the TrueNAS GPU resource toggle, or `--gpus all` for raw Docker.

**Container restarts in a loop**
Check `docker logs lmstudio` for the underlying error. Most common: out-of-memory because a model larger than your RAM was set in `LMS_LOAD`. Remove `LMS_LOAD` and let JIT loading handle it (it'll fail gracefully on a single request instead of crash-looping).

---

## Building locally

```bash
docker build -t lmstudio-container:dev .
docker run --rm -p 1234:1234 -v $PWD/data:/data lmstudio-container:dev
```

For multi-arch local builds:

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t lmstudio-container:dev .
```

---

## Repository layout

```
.
├── Dockerfile               # Image definition
├── entrypoint.sh            # PUID/PGID handling + daemon/server start
├── docker-compose.yml       # Reference compose file
├── .github/workflows/
│   └── build.yml            # Multi-arch build & push to GHCR
└── README.md
```

---

## License

MIT — see [LICENSE](LICENSE). This covers the container packaging only; **LM Studio itself is governed by its own terms** at <https://lmstudio.ai/>. Make sure your usage of LM Studio and the models you run complies with their respective licenses.

Not affiliated with LM Studio / Element Labs.
