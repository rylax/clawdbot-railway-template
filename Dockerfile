# ============================================================
# Build OpenClaw from source (keeps Railway builds reliable)
# ============================================================
FROM node:22-bookworm AS openclaw-build

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git ca-certificates curl python3 make g++ \
  && rm -rf /var/lib/apt/lists/*

# Bun (OpenClaw build uses it)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /openclaw
ARG OPENCLAW_GIT_REF=v2026.2.9
RUN git clone --depth 1 --branch "${OPENCLAW_GIT_REF}" https://github.com/openclaw/openclaw.git .

# Patch: relax version requirements for workspace/unpublished refs
RUN set -eux; \
  find ./extensions -name 'package.json' -type f | while read -r f; do \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*">=[^"]+"/"openclaw": "*"/g' "$f"; \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*"workspace:[^"]+"/"openclaw": "*"/g' "$f"; \
  done

RUN pnpm install --no-frozen-lockfile
RUN pnpm build
ENV OPENCLAW_PREFER_PNPM=1

# OPTIONAL: comment these 2 lines out if you don't need the Control UI (saves minutes)
RUN pnpm ui:install
RUN pnpm ui:build


# ============================================================
# Runtime image (your Railway wrapper + wacli installed)
# ============================================================
FROM node:22-bookworm
ENV NODE_ENV=production

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates proxychains4 wget \
  && rm -rf /var/lib/apt/lists/*

# Install Go 1.25.7 (wacli needs >= 1.25)
RUN cd /tmp && \
    wget -q https://go.dev/dl/go1.25.7.linux-amd64.tar.gz && \
    tar -C /usr/local -xzf go1.25.7.linux-amd64.tar.gz && \
    rm go1.25.7.linux-amd64.tar.gz

ENV GOPATH=/root/go
ENV PATH="/usr/local/go/bin:/root/go/bin:/usr/local/bin:${PATH}"

# Persist wacli state on the Railway volume
ENV WACLI_STORE=/data/.wacli

# Install wacli and rename to wacli-real (start.sh will create the wrapper "wacli")
RUN go install github.com/steipete/wacli/cmd/wacli@latest \
  && mv /root/go/bin/wacli /root/go/bin/wacli-real

# Optional: ClawHub CLI (you can also use `npx clawhub ...` if you want to skip this)
RUN npm install -g clawhub

# `openclaw update` expects pnpm
RUN corepack enable && corepack prepare pnpm@10.23.0 --activate

WORKDIR /app

# Install wrapper deps first (better layer caching)
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force

# Copy built OpenClaw from builder
COPY --from=openclaw-build /openclaw /openclaw

# Provide openclaw executable
RUN printf '%s\n' '#!/usr/bin/env bash' 'exec node /openclaw/dist/entry.js "$@"' > /usr/local/bin/openclaw \
  && chmod +x /usr/local/bin/openclaw

# Copy your wrapper last (fast rebuilds when you only change wrapper/start.sh)
COPY src ./src
COPY start.sh /start.sh
RUN chmod +x /start.sh

ENV OPENCLAW_PUBLIC_PORT=8080
ENV PORT=8080
EXPOSE 8080

CMD ["/start.sh"]