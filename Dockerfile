# syntax=docker/dockerfile:1.7

# ============================================================
# Build openclaw from source (cached)
# ============================================================
FROM node:22-bookworm AS openclaw-build

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git ca-certificates curl python3 make g++ \
  && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"
RUN corepack enable

WORKDIR /openclaw
ARG OPENCLAW_GIT_REF=v2026.2.9

RUN git clone --depth 1 --branch "${OPENCLAW_GIT_REF}" https://github.com/openclaw/openclaw.git .

RUN set -eux; \
  find ./extensions -name 'package.json' -type f | while read -r f; do \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*">=[^"]+"/"openclaw": "*"/g' "$f"; \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*"workspace:[^"]+"/"openclaw": "*"/g' "$f"; \
  done

# pnpm store cache = huge speedup on rebuilds
RUN --mount=type=cache,target=/root/.local/share/pnpm/store \
    pnpm install --no-frozen-lockfile

RUN pnpm build
ENV OPENCLAW_PREFER_PNPM=1

# If you don't need the Control UI, you can remove the next line to save build time.
RUN --mount=type=cache,target=/root/.local/share/pnpm/store \
    pnpm ui:install && pnpm ui:build


# ============================================================
# Runtime (fast rebuilds)
# ============================================================
FROM node:22-bookworm
ENV NODE_ENV=production

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates proxychains4 wget \
  && rm -rf /var/lib/apt/lists/*

# Install Go (needed to build wacli)
RUN cd /tmp && \
    wget -q https://go.dev/dl/go1.25.7.linux-amd64.tar.gz && \
    tar -C /usr/local -xzf go1.25.7.linux-amd64.tar.gz && \
    rm go1.25.7.linux-amd64.tar.gz

ENV GOPATH=/root/go
ENV PATH="/usr/local/go/bin:/root/go/bin:/usr/local/bin:${PATH}"

# Persist wacli state on Railway volume
ENV WACLI_STORE=/data/.wacli

# Install wacli with Go module cache
RUN --mount=type=cache,target=/root/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go install github.com/steipete/wacli/cmd/wacli@latest

# Rename real binary (start.sh creates /usr/local/bin/wacli wrapper)
RUN mv /root/go/bin/wacli /root/go/bin/wacli-real

# Optional (not required if you use npx clawhub):
RUN --mount=type=cache,target=/root/.npm \
    npm install -g clawhub

# `openclaw update` expects pnpm
RUN corepack enable && corepack prepare pnpm@10.23.0 --activate

WORKDIR /app

# Wrapper deps (cache npm)
COPY package.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm install --omit=dev && npm cache clean --force

# Copy built openclaw
COPY --from=openclaw-build /openclaw /openclaw

# Provide openclaw executable
RUN printf '%s\n' '#!/usr/bin/env bash' 'exec node /openclaw/dist/entry.js "$@"' > /usr/local/bin/openclaw \
  && chmod +x /usr/local/bin/openclaw

# App code last (fast rebuilds when you edit wrapper only)
COPY src ./src
COPY start.sh /start.sh
RUN chmod +x /start.sh

ENV OPENCLAW_PUBLIC_PORT=8080
ENV PORT=8080
EXPOSE 8080
CMD ["/start.sh"]
