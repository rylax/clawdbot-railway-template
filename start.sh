#!/bin/bash

# Generate proxychains config from env var if set
if [ -n "$PROXY_URL" ]; then
  # Parse proxy URL
  PROXY_HOST=$(echo "$PROXY_URL" | sed -E 's|https?://[^@]+@([^:]+):.*|\1|')
  PROXY_PORT=$(echo "$PROXY_URL" | sed -E 's|.*:([0-9]+)$|\1|')
  PROXY_USER=$(echo "$PROXY_URL" | sed -E 's|https?://([^:]+):.*|\1|')
  PROXY_PASS=$(echo "$PROXY_URL" | sed -E 's|https?://[^:]+:([^@]+)@.*|\1|')
  
  # Resolve hostname to IP
  PROXY_IP=$(getent hosts "$PROXY_HOST" | awk '{print $1}' | head -1)
  if [ -z "$PROXY_IP" ]; then
    PROXY_IP="$PROXY_HOST"
  fi

  cat > /etc/proxychains4.conf << 'EOF'
strict_chain
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000

# ============================================================
# LOCALHOST & PRIVATE NETWORKS (Always exclude)
# ============================================================
localnet 127.0.0.0/255.0.0.0
localnet 10.0.0.0/255.0.0.0
localnet 172.16.0.0/255.240.0.0
localnet 192.168.0.0/255.255.0.0

# ============================================================
# LLM API PROVIDERS (Exclude for speed)
# ============================================================

# Anthropic Claude API
localnet 160.79.104.0/255.255.248.0

# Cloudflare (used by OpenRouter, many AI services)
localnet 104.16.0.0/255.248.0.0
localnet 104.24.0.0/255.252.0.0
localnet 108.162.192.0/255.255.192.0
localnet 172.64.0.0/255.248.0.0
localnet 173.245.48.0/255.255.240.0
localnet 162.158.0.0/255.254.0.0

# Google Cloud (Gemini, Google AI APIs)
localnet 34.64.0.0/255.192.0.0
localnet 35.185.0.0/255.255.0.0
localnet 35.186.0.0/255.255.0.0
localnet 35.187.0.0/255.255.0.0
localnet 35.188.0.0/255.252.0.0
localnet 142.250.0.0/255.254.0.0
localnet 172.217.0.0/255.255.0.0

# Telegram Bot API
localnet 149.154.160.0/255.255.224.0
localnet 91.108.4.0/255.255.252.0

# Microsoft Azure (used by some AI services)
localnet 13.64.0.0/255.192.0.0
localnet 20.33.0.0/255.255.0.0
localnet 40.64.0.0/255.192.0.0

# AWS (various AI services)
localnet 52.94.0.0/255.254.0.0
localnet 54.231.0.0/255.255.0.0

[ProxyList]
EOF

  echo "http $PROXY_IP $PROXY_PORT $PROXY_USER $PROXY_PASS" >> /etc/proxychains4.conf

  echo "Proxychains configured: $PROXY_IP:$PROXY_PORT"
  echo "Excluded: Localhost, Anthropic, Google, Cloudflare, Telegram, Azure, AWS"
  exec proxychains4 node src/server.js
else
  echo "No PROXY_URL set, running without proxy"
  exec node src/server.js
fi
