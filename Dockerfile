FROM ubuntu:24.04

ARG TARGETARCH
ARG TARGETOS

ENV DEBIAN_FRONTEND=noninteractive

# Runtime dependencies for the bundled llmster runtime + helpers we need
# in the entrypoint:
#   - libatomic1 / libgomp1   required by the llmster Node/llama.cpp runtime
#   - ca-certificates / curl  install script + healthcheck + lms get
#   - tini                    proper PID-1 / signal handling
#   - gosu                    drop privileges to PUID/PGID at runtime
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gosu \
        libatomic1 \
        libgomp1 \
        tini \
 && rm -rf /var/lib/apt/lists/*

# Stage a full LM Studio install at /opt/lmstudio-stage. The entrypoint
# copies this into $HOME/.lmstudio on first boot when the persistent /data
# volume is empty. We can't install directly into /data (that's the volume
# mount point — bind-mounting a host path shadows whatever was baked in),
# but we *do* need the install rooted at $HOME/.lmstudio at runtime: the
# `lms` CLI hard-codes that layout when it looks up the llmster daemon.
RUN set -eux; \
    mkdir -p /opt/lmstudio-stage; \
    HOME=/opt/lmstudio-stage \
        sh -c "curl -fsSL https://lmstudio.ai/install.sh | sh -s -- --no-modify-path --quiet"; \
    test -x /opt/lmstudio-stage/.lmstudio/bin/lms; \
    /opt/lmstudio-stage/.lmstudio/bin/lms --version

# TrueNAS SCALE Apps default to UID/GID 568 ("apps" user). Override with
# PUID/PGID env vars at runtime to match your dataset ownership.
ENV PUID=568 \
    PGID=568 \
    LMS_PORT=1234 \
    LMS_HOST=0.0.0.0

# Models, config, conversations, and the JIT cache all live under /data.
# Mount a single host dataset here for persistence.
VOLUME ["/data"]

EXPOSE 1234

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${LMS_PORT}/v1/models" >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD []
