# syntax=docker/dockerfile:1.7

# ============================================================
# Build OpenClaw from source (cached)
# ============================================================
FROM node:22-bookworm AS openclaw-build

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git ca-certificates curl python3 make g++ \
  && rm -rf /var/lib/apt/lists/*

# Install Bun (OpenClaw build uses it)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /openclaw
ARG OPENCLAW_GIT_REF=v2026.2.9

RUN git clone --depth 1 --branch "${OPENCLAW_GIT_REF}" https://github.com/openclaw/openclaw.git .

# Patch: relax version requirements for packages that may reference unpublished versions.
RUN set -eux; \
  find ./extensions -name 'package.json' -type f | while read -r f; do \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*">=[^"]+"/"openclaw": "*"/g' "$f"; \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*"workspace:[^"]+"/"openclaw": "*"/g' "$f"; \
  done

# pnpm store cache (big speedup on rebuilds)
RUN --mount=type=cache,id=pnpm-store,target=/root/.local/share/pnpm/store \
    pnpm install --no-frozen-lockfile

RUN pnpm build
ENV OPENCLAW_PREFER_PNPM=1

# OPTIONAL: Remove this line if you don't need the Control UI (saves build time)
RUN --mount=type=cache,id=pnpm-store,target=/root/.local/share/pnpm/store \
    pnpm ui:install && pnpm ui:build


# ============================================================
# Runtime image (fast rebuilds)
# ============================================================
FROM node:22-bookworm
ENV NODE_ENV=production

# System deps
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates proxychains4 wget \
  && rm -rf /var/lib/apt/lists/*

# Install Go 1.25.7 (wacli requires >= 1.25)
RUN cd /tmp && \
    wget -q https://go.dev/dl/go1.25.7.linux-amd64.tar.gz && \
    tar -C /usr/local -xzf go1.25.7.linux-amd64.tar.gz && \
    rm go1.25.7.linux-amd64.tar.gz

ENV GOPATH=/root/go
ENV PATH="/usr/local/go/bin:/root/go/bin:/usr/local/bin:${PATH}"

# Persist wacli state on Railway volume
ENV WACLI_STORE=/data/.wacli

# Install wacli (use Go caches)
RUN --mount=type=cache,id=go-mod,target=/root/go/pkg/mod \
    --mount=type=cache,id=go-build,target=/root/.cache/go-build \
    go install github.com/steipete/wacli/cmd/wacli@latest

# Rename real binary (start.sh will create /usr/local/bin/wacli wrapper)
RUN mv /root/go/bin/wacli /root/go/bin/wacli-real

# Install ClawHub CLI (optional but handy)
RUN --mount=type=cache,id=npm-cache,target=/root/.npm \
    npm install -g clawhub

# `openclaw update` expects pnpm
RUN corepack enable && corepack prepare pnpm@10.23.0 --activate

WORKDIR /app

# Wrapper deps (cache npm)
COPY package.json ./
RUN --mount=type=cache,id=npm-cache,target=/root/.npm \
    npm install --omit=dev && npm cache clean --force

# Copy built OpenClaw
COPY --from=openclaw-build /openclaw /openclaw

# Provide an openclaw executable
RUN printf '%s\n' '#!/usr/bin/env bash' 'exec node /openclaw/dist/entry.js "$@"' > /usr/local/bin/openclaw \
  && chmod +x /usr/local/bin/openclaw

# Wrapper source
COPY src ./src

# Startup script (builds wacli-only proxychains config + starts wrapper)
COPY start.sh /start.sh
RUN chmod +x /start.sh

# The wrapper listens on this port.
ENV OPENCLAW_PUBLIC_PORT=8080
ENV PORT=8080
EXPOSE 8080

CMD ["/start.sh"]
