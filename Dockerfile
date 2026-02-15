# Build openclaw from source to avoid npm packaging gaps
FROM node:22-bookworm AS openclaw-build

# Dependencies needed for openclaw build
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    curl \
    python3 \
    make \
    g++ \
  && rm -rf /var/lib/apt/lists/*

# Install Bun (openclaw build uses it)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /openclaw

# Pin to a known-good ref (tag/branch). Override in Railway template settings if needed.
ARG OPENCLAW_GIT_REF=v2026.2.9
RUN git clone --depth 1 --branch "${OPENCLAW_GIT_REF}" https://github.com/openclaw/openclaw.git .

# Patch: relax version requirements for packages that may reference unpublished versions.
RUN set -eux; \
  find ./extensions -name 'package.json' -type f | while read -r f; do \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*">=[^"]+"/"openclaw": "*"/g' "$f"; \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*"workspace:[^"]+"/"openclaw": "*"/g' "$f"; \
  done

RUN pnpm install --no-frozen-lockfile
RUN pnpm build
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:install && pnpm ui:build


# ============================================================
# Runtime image with all optimizations
# ============================================================
FROM node:22-bookworm
ENV NODE_ENV=production

# Install system dependencies: proxychains + wget
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    proxychains4 \
    wget \
  && rm -rf /var/lib/apt/lists/*

# Install Go 1.25.7 (required for wacli)
RUN cd /tmp && \
    wget -q https://go.dev/dl/go1.25.7.linux-amd64.tar.gz && \
    tar -C /usr/local -xzf go1.25.7.linux-amd64.tar.gz && \
    rm go1.25.7.linux-amd64.tar.gz

# Set Go paths
ENV PATH="/usr/local/go/bin:/root/go/bin:${PATH}"
ENV GOPATH=/root/go

# Install wacli (WhatsApp CLI)
RUN go install github.com/steipete/wacli/cmd/wacli@latest

# Install clawhub CLI (skill manager)
RUN npm install -g clawhub

# Set wacli to use persistent storage on Railway volume
ENV WACLI_STORE=/data/.wacli

# pnpm for openclaw update command
RUN corepack enable && corepack prepare pnpm@10.23.0 --activate

WORKDIR /app

# Install wrapper dependencies
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force

# Copy built openclaw from build stage
COPY --from=openclaw-build /openclaw /openclaw

# Provide openclaw executable in PATH
RUN printf '%s\n' '#!/usr/bin/env bash' 'exec node /openclaw/dist/entry.js "$@"' > /usr/local/bin/openclaw \
  && chmod +x /usr/local/bin/openclaw

# Copy wrapper source
COPY src ./src

# Copy and configure start script (generates proxychains config + starts server)
COPY start.sh /start.sh
RUN chmod +x /start.sh

# Expose wrapper port
ENV OPENCLAW_PUBLIC_PORT=8080
ENV PORT=8080
EXPOSE 8080

# Start via optimized proxychains wrapper
CMD ["/start.sh"]
