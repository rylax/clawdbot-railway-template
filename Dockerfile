# Build stage
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

RUN pnpm install --no-frozen-lockfile
RUN pnpm build
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:install && pnpm ui:build


# Runtime stage
FROM node:22-bookworm
ENV NODE_ENV=production

# Force IPv4 preference (proxychains localnet doesn't support IPv6)
RUN printf "precedence ::ffff:0:0/96  100\n" >> /etc/gai.conf

# Install system dependencies
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates proxychains4 wget \
  && rm -rf /var/lib/apt/lists/*

# Install Go 1.25.7
RUN cd /tmp && \
    wget -q https://go.dev/dl/go1.25.7.linux-amd64.tar.gz && \
    tar -C /usr/local -xzf go1.25.7.linux-amd64.tar.gz && \
    rm go1.25.7.linux-amd64.tar.gz

ENV PATH="/usr/local/go/bin:/root/go/bin:${PATH}"
ENV GOPATH=/root/go
ENV WACLI_STORE=/data/.wacli

# Install wacli
RUN go install github.com/steipete/wacli/cmd/wacli@latest

# Create wacli wrapper that always uses persistent storage
RUN mv /root/go/bin/wacli /root/go/bin/wacli-real && \
    printf '#!/bin/bash\nexec /root/go/bin/wacli-real --store "${WACLI_STORE:-/data/.wacli}" "$@"\n' > /root/go/bin/wacli && \
    chmod +x /root/go/bin/wacli

# Install clawhub
RUN npm install -g clawhub

# pnpm
RUN corepack enable && corepack prepare pnpm@10.23.0 --activate

WORKDIR /app

# Wrapper deps
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force

# Copy openclaw
COPY --from=openclaw-build /openclaw /openclaw

# openclaw executable
RUN printf '#!/usr/bin/env bash\nexec node /openclaw/dist/entry.js "$@"\n' > /usr/local/bin/openclaw \
  && chmod +x /usr/local/bin/openclaw

COPY src ./src
COPY start.sh /start.sh
RUN chmod +x /start.sh

ENV OPENCLAW_PUBLIC_PORT=8080
ENV PORT=8080
EXPOSE 8080
CMD ["/start.sh"]
