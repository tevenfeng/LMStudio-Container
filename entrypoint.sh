#!/usr/bin/env bash
set -euo pipefail

PUID="${PUID:-568}"
PGID="${PGID:-568}"
LMS_PORT="${LMS_PORT:-1234}"

log() { printf '[lmstudio] %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Privileged setup phase: align the runtime user with PUID/PGID, fix volume
# ownership, then re-exec ourselves as the unprivileged user.
# ---------------------------------------------------------------------------
if [ "$(id -u)" = "0" ]; then
    if ! getent group lmstudio >/dev/null 2>&1; then
        groupadd -o -g "$PGID" lmstudio
    fi
    if ! getent passwd lmstudio >/dev/null 2>&1; then
        useradd -o -u "$PUID" -g "$PGID" -d /data -M -s /bin/bash lmstudio
    fi

    mkdir -p /data/.lmstudio

    # Seed the volume on first boot. The `lms` CLI expects its companion
    # binaries (llmster, etc.) under $HOME/.lmstudio/bin — that's hard-coded,
    # not just $PATH. We staged a full install at /opt/lmstudio-stage during
    # the image build; copy it across only if /data/.lmstudio is empty so we
    # don't clobber user-installed updates from `lms self-update`.
    if [ ! -x /data/.lmstudio/bin/lms ]; then
        log "Seeding /data/.lmstudio from staged install..."
        cp -a /opt/lmstudio-stage/.lmstudio/. /data/.lmstudio/
    fi

    mkdir -p /data/.lmstudio/models

    # Best-effort chown: a host-mounted dataset may already match PUID/PGID
    # (no-op) or may be owned by a different user (fix it). Don't fail the
    # container if the filesystem refuses (e.g. read-only NFS export).
    chown -R "$PUID:$PGID" /data 2>/dev/null || \
        log "WARN: could not chown /data to ${PUID}:${PGID} — continuing"

    exec gosu "$PUID:$PGID" "$0" "$@"
fi

# ---------------------------------------------------------------------------
# Unprivileged process from here on.
# ---------------------------------------------------------------------------
export HOME=/data
export PATH=/data/.lmstudio/bin:${PATH}

log "Starting LM Studio headless ($(lms --version 2>/dev/null || echo 'unknown version'))"
log "HOME=${HOME}  PATH includes /data/.lmstudio/bin"

# `lms bootstrap` is idempotent and ensures the CLI can locate its companion
# binaries. Safe to run on every start.
lms bootstrap >/dev/null 2>&1 || true

# Start the llmster daemon in the background. Idempotent — if a previous
# instance is already running this is a no-op.
lms daemon up || true

# Wait for the daemon socket to be ready before issuing commands.
for _ in $(seq 1 60); do
    if lms server status >/dev/null 2>&1; then break; fi
    sleep 1
done

# Start the OpenAI-compatible REST API. CORS is on so web UIs (Open WebUI,
# LobeChat, etc.) on other origins can talk to it.
lms server start --port "${LMS_PORT}" --cors

log "API listening on 0.0.0.0:${LMS_PORT}"
log "Models directory: ${HOME}/.lmstudio/models"

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
