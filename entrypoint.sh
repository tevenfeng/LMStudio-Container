#!/usr/bin/env bash
set -euo pipefail

LMS_PORT="${LMS_PORT:-1234}"

log() { printf '[lmstudio] %s\n' "$*"; }

# The image symlinks /root/.lmstudio/{models,conversations} to
# /data/<subdir>. Make sure the targets exist on first boot — without them
# `lms` would resolve to dangling symlinks and fail to write.
mkdir -p /data/models /data/conversations /data/credentials /data/.internal
touch /data/.internal/lms-key-2 /data/.internal/user-profile.json /data/.internal/lm-link-account-status-cache.json /data/.internal/lm-link-config.json /data/.internal/local-identity.json

log "Starting LM Studio headless ($(lms --version 2>/dev/null || echo 'unknown version'))"

# NB: do not call `lms bootstrap` here — it's only an interactive helper
# that writes `export PATH=...` into ~/.profile/~/.bashrc, which we already
# bake into the image. On amd64 hosts without AVX (or under QEMU) it spins
# at 99% CPU forever waiting on a TTY prompt that never arrives, hanging
# the whole entrypoint. We don't need it.

# Start the llmster daemon in the background. Idempotent — if a previous
# instance is already running this is a no-op.
lms daemon up || true

# Wait for the daemon socket to be ready before issuing commands.
for _ in $(seq 1 60); do
    if lms server status >/dev/null 2>&1; then break; fi
    sleep 1
done

# Start the OpenAI-compatible REST API. We pass --bind explicitly because
# `lms server start` defaults to 127.0.0.1, which silently makes the docker
# port mapping useless. LMS_SERVER_HOST is the upstream-documented env var
# name for this. CORS is on so web UIs (Open WebUI, LobeChat, etc.) on
# other origins can talk to it.
lms server start --port "${LMS_PORT}" --bind "${LMS_SERVER_HOST:-0.0.0.0}" --cors

log "API listening on ${LMS_SERVER_HOST:-0.0.0.0}:${LMS_PORT}"
log "Models directory: /data/models"

# Optional: prefetch one or more models on first boot.
# Space-separated list, e.g. LMS_PREFETCH="qwen/qwen3-4b lmstudio/llama-3.2-3b"
if [ -n "${LMS_PREFETCH:-}" ]; then
    for model in ${LMS_PREFETCH}; do
        log "Prefetching model: ${model}"
        lms get --yes "${model}" || log "WARN: prefetch failed for ${model}"
    done
fi

# Optional: load a model into memory at startup so the first request is fast.
# If unset, JIT loading handles model load on first API call.
if [ -n "${LMS_LOAD:-}" ]; then
    log "Loading model into memory: ${LMS_LOAD}"
    lms load "${LMS_LOAD}" || log "WARN: failed to load ${LMS_LOAD}"
fi

# Keep PID 1 alive by tailing the daemon's log stream. tini will reap zombies
# and forward SIGTERM/SIGINT, so `docker stop` shuts down cleanly.
exec lms log stream
