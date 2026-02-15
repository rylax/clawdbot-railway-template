#!/bin/bash

# PROXY_URL format: http://user:pass@host:port
if [ -n "$PROXY_URL" ]; then
  # Resolve hostname to IP (proxychains needs numeric IP)
  PROXY_HOST=$(echo "$PROXY_URL" | sed -E 's|https?://[^@]+@([^:]+):.*|\1|')
  PROXY_PORT=$(echo "$PROXY_URL" | sed -E 's|.*:([0-9]+)$|\1|')
  PROXY_USER=$(echo "$PROXY_URL" | sed -E 's|https?://([^:]+):.*|\1|')
  PROXY_PASS=$(echo "$PROXY_URL" | sed -E 's|https?://[^:]+:([^@]+)@.*|\1|')
  
  # Resolve hostname to IP
  PROXY_IP=$(getent hosts "$PROXY_HOST" | awk '{print $1}' | head -1)
  if [ -z "$PROXY_IP" ]; then
    PROXY_IP="$PROXY_HOST"
  fi

  cat > /etc/proxychains4.conf << EOF
strict_chain
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000
[ProxyList]
http $PROXY_IP $PROXY_PORT $PROXY_USER $PROXY_PASS
EOF

  echo "Proxychains configured: $PROXY_IP:$PROXY_PORT"
  exec proxychains4 node src/server.js
else
  echo "No PROXY_URL set, running without proxy"
  exec node src/server.js
fi
