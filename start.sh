#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------
# Build a proxychains config ONLY for wacli (not for the gateway)
# ------------------------------------------------------------
if [ -n "${PROXY_URL:-}" ]; then
    PROXY_HOST="$(echo "$PROXY_URL" | sed -E 's|https?://[^@]+@([^:]+):.*|\1|')"
    PROXY_PORT="$(echo "$PROXY_URL" | sed -E 's|.*:([0-9]+)$|\1|')"
    PROXY_USER="$(echo "$PROXY_URL" | sed -E 's|https?://([^:]+):.*|\1|')"
    PROXY_PASS="$(echo "$PROXY_URL" | sed -E 's|https?://[^:]+:([^@]+)@.*|\1|')"

    # Prefer IPv4 (proxychains config expects an IP; your Decodo hostname may round-robin)
    PROXY_IP="$(getent ahostsv4 "$PROXY_HOST" 2>/dev/null | awk '{print $1; exit}' || true)"
    if [ -z "${PROXY_IP}" ]; then
        PROXY_IP="$(getent hosts "$PROXY_HOST" | awk '{print $1; exit}' || true)"
    fi
    if [ -z "${PROXY_IP}" ]; then
        PROXY_IP="$PROXY_HOST"
    fi

    cat > /etc/proxychains4-wacli.conf << EOF
strict_chain
quiet_mode
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000

# Never proxy local traffic
localnet 127.0.0.0/255.0.0.0
localnet 10.0.0.0/255.0.0.0
localnet 172.16.0.0/255.240.0.0
localnet 192.168.0.0/255.255.0.0

[ProxyList]
http $PROXY_IP $PROXY_PORT $PROXY_USER $PROXY_PASS
EOF

    echo "✓ wacli proxychains configured: $PROXY_IP:$PROXY_PORT"
else
    echo "⚠ PROXY_URL not set; wacli will run without proxy"
fi

# ------------------------------------------------------------
# Provide a wacli wrapper:
# * always uses persistent store (/data)
# * uses proxychains ONLY when config exists
# ------------------------------------------------------------
cat > /usr/local/bin/wacli << 'WACLIEOF'
#!/bin/bash
set -euo pipefail

STORE="${WACLI_STORE:-/data/.wacli}"

if [ -f /etc/proxychains4-wacli.conf ]; then
    exec proxychains4 -q -f /etc/proxychains4-wacli.conf /root/go/bin/wacli-real --store "$STORE" "$@"
else
    exec /root/go/bin/wacli-real --store "$STORE" "$@"
fi
WACLIEOF
chmod +x /usr/local/bin/wacli

# ------------------------------------------------------------
# Start the Railway wrapper normally (NO proxychains here)
# ------------------------------------------------------------
exec node src/server.js
