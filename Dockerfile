FROM ubuntu:24.04

ARG TARGETARCH
ARG TARGETOS

ENV DEBIAN_FRONTEND=noninteractive

# Runtime dependencies for the bundled llmster runtime + helpers we need:
#   - libatomic1 / libgomp1   required by the llmster Node/llama.cpp runtime
#   - ca-certificates / curl  install script + healthcheck + lms get
#   - tini                    proper PID-1 / signal handling
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        libatomic1 \
        libgomp1 \
        tini \
 && rm -rf /var/lib/apt/lists/*

# Install LM Studio using the upstream one-liner. Runs as root with the
# default $HOME=/root, so files land at /root/.lmstudio — the installer's
# standard layout, no path tricks.
RUN curl -fsSL https://lmstudio.ai/install.sh | sh -s -- --no-modify-path --quiet \
 && /root/.lmstudio/bin/lms --version

# Point the heavy/user-owned dirs at /data so they survive image rebuilds.
# We deliberately keep .internal/ in the image: the installer drops
# llmster-install-location.json there pointing at /root/.lmstudio/llmster/...,
# and `lms daemon up` errors with "no valid installation could be found"
# if that pointer is missing. Putting it on a bind-mounted volume would
# also break the daemon's unix socket on NFS/SMB hosts.
RUN cd /root/.lmstudio \
 && rm -rf models conversations credentials \
 && rm -f .internal/lms-key-2 .internal/user-profile.json .internal/lm-link-account-status-cache.json .internal/lm-link-config.json .internal/local-identity.json \
 && ln -sf /data/models models \
 && ln -sf /data/conversations conversations \
 && ln -sf /data/credentials credentials \
 && ln -sf /data/.internal/lms-key-2 .internal/lms-key-2 \
 && ln -sf /data/.internal/user-profile.json .internal/user-profile.json \
 && ln -sf /data/.internal/lm-link-account-status-cache.json .internal/lm-link-account-status-cache.json \
 && ln -sf /data/.internal/lm-link-config.json .internal/lm-link-config.json \
 && ln -sf /data/.internal/local-identity.json .internal/local-identity.json

# LMS_SERVER_HOST is the variable name `lms server start --bind` reads.
# Default to 0.0.0.0 in-container so the published port is reachable from
# outside Docker (the upstream `lms` default is 127.0.0.1, which silently
# breaks `docker run -p` mapping).
ENV HOME=/root \
    PATH=/root/.lmstudio/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LMS_PORT=1234 \
    LMS_SERVER_HOST=0.0.0.0

# Models, config, and conversations live under /data via the symlinks
# created above. Mount a single host dataset here for persistence.
VOLUME ["/data"]

EXPOSE 1234

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${LMS_PORT}/v1/models" >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD []
