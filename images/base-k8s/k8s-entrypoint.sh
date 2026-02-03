#!/bin/bash
# K8s sandbox entrypoint
# Starts K3s server, then drops privileges to developer user for Claude
#
# Flow:
#   1. Install proxy CA certificate (from base entrypoint)
#   2. Create Claude binary symlink
#   3. Start K3s server in background (as root)
#   4. Wait for K3s API server to be ready
#   5. Copy kubeconfig to developer user
#   6. Drop privileges via gosu and exec command

set -e

CA_CERT="/etc/squid/ssl/squid-ca-cert.pem"
TARGET_USER="${TARGET_USER:-developer}"
K3S_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
USER_KUBECONFIG="/home/developer/.kube/config"

# =============================================================================
# 1. Wait for and install proxy CA certificate
# =============================================================================
i=1
while [ $i -le 30 ]; do
    [ -f "$CA_CERT" ] && break
    echo "Waiting for proxy CA certificate... ($i/30)"
    sleep 1
    i=$((i + 1))
done

if [ -f "$CA_CERT" ]; then
    if [ "$(id -u)" = "0" ]; then
        echo "Installing proxy CA certificate..."
        cp "$CA_CERT" /usr/local/share/ca-certificates/squid-proxy-ca.crt
        update-ca-certificates
        echo "Proxy CA certificate installed."
    fi
else
    echo "WARNING: Proxy CA certificate not found at $CA_CERT"
    echo "K3s image pulls may fail with certificate errors."
fi

export NODE_EXTRA_CA_CERTS="$CA_CERT"

# =============================================================================
# 2. Create Claude symlink from mounted versions directory
# =============================================================================
CLAUDE_DIR="/home/developer/.local/share/claude"
CLAUDE_BIN="/home/developer/.local/bin/claude"

if [ -d "$CLAUDE_DIR/versions" ] && [ "$(id -u)" = "0" ]; then
    LATEST=$(ls -t "$CLAUDE_DIR/versions" 2>/dev/null | head -1)
    if [ -n "$LATEST" ]; then
        echo "Setting up Claude binary (version $LATEST)..."
        ln -sf "$CLAUDE_DIR/versions/$LATEST" "$CLAUDE_BIN"
        chown -h "$TARGET_USER:$TARGET_USER" "$CLAUDE_BIN"
    fi
fi

# =============================================================================
# 3. Add iptables rules for K8s networking
# =============================================================================
# The proxy container's iptables REJECT rule blocks non-whitelisted traffic.
# We need to allow traffic to K8s pod and service networks BEFORE the REJECT.
if [ "$(id -u)" = "0" ]; then
    echo "Adding iptables rules for K8s networking..."
    # Insert rules at position 1 (before REJECT) for pod and service networks
    # Pod network: 10.42.0.0/16 (flannel default)
    # Service network: 10.43.0.0/16 (K3s default)
    iptables -I OUTPUT 1 -d 10.42.0.0/16 -j ACCEPT 2>/dev/null || true
    iptables -I OUTPUT 1 -d 10.43.0.0/16 -j ACCEPT 2>/dev/null || true
    echo "K8s network rules added."
fi

# =============================================================================
# 4. Start K3s server in background (must run as root)
# =============================================================================
if [ "$(id -u)" = "0" ]; then
    echo "Starting K3s server..."

    # Start K3s in background, log to file
    k3s server --config /etc/rancher/k3s/config.yaml >> /var/log/k3s.log 2>&1 &
    K3S_PID=$!
    echo "K3s started with PID $K3S_PID"

    # =============================================================================
    # 5. Wait for K3s API server to be ready
    # =============================================================================
    echo "Waiting for K3s API server..."

    for i in $(seq 1 90); do
        if [ -f "$K3S_KUBECONFIG" ]; then
            if k3s kubectl --kubeconfig="$K3S_KUBECONFIG" get nodes >/dev/null 2>&1; then
                echo "K3s API server is ready"
                break
            fi
        fi

        # Check if K3s process died
        if ! kill -0 $K3S_PID 2>/dev/null; then
            echo "ERROR: K3s process died. Check /var/log/k3s.log"
            tail -50 /var/log/k3s.log
            exit 1
        fi

        echo "Waiting for K3s... ($i/90)"
        sleep 2
    done

    # Final check
    if ! k3s kubectl --kubeconfig="$K3S_KUBECONFIG" get nodes >/dev/null 2>&1; then
        echo "ERROR: K3s failed to start within 180 seconds. Check /var/log/k3s.log"
        tail -100 /var/log/k3s.log
        exit 1
    fi

    # =============================================================================
    # 6. Copy kubeconfig to developer user
    # =============================================================================
    echo "Setting up kubeconfig for developer user..."
    cp "$K3S_KUBECONFIG" "$USER_KUBECONFIG"
    chown "$TARGET_USER:$TARGET_USER" "$USER_KUBECONFIG"
    chmod 600 "$USER_KUBECONFIG"

    echo "K3s is ready. kubectl available for developer user."

    # Show node status
    k3s kubectl --kubeconfig="$K3S_KUBECONFIG" get nodes

    # =============================================================================
    # 6.5 Add FORWARD chain rules for pod network interception
    # =============================================================================
    # K8s pods use flannel CNI (10.42.0.0/16). Their egress traffic goes through
    # FORWARD chain. We DNAT it to squid on the cni0 bridge IP.
    if ip link show cni0 >/dev/null 2>&1; then
        echo "Adding FORWARD chain rules for pod network interception..."
        CNI_IP=$(ip -4 addr show cni0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

        if [ -n "$CNI_IP" ]; then
            # DNAT pod HTTP/HTTPS to squid intercept ports
            iptables -t nat -A PREROUTING -i cni0 -s 10.42.0.0/16 \
                -p tcp --dport 80 -j DNAT --to-destination $CNI_IP:3128
            iptables -t nat -A PREROUTING -i cni0 -s 10.42.0.0/16 \
                -p tcp --dport 443 -j DNAT --to-destination $CNI_IP:3129

            # Allow FORWARD for pod traffic to/from squid
            iptables -I FORWARD 1 -s 10.42.0.0/16 -d $CNI_IP -j ACCEPT
            iptables -I FORWARD 1 -d 10.42.0.0/16 -m state --state ESTABLISHED,RELATED -j ACCEPT

            # Block direct pod internet access (force through proxy)
            iptables -A FORWARD -s 10.42.0.0/16 ! -d 10.42.0.0/16 -j REJECT

            echo "Pod network interception enabled (CNI IP: $CNI_IP)"
        else
            echo "WARNING: Could not determine cni0 IP address"
        fi
    else
        echo "WARNING: cni0 interface not found, pod network interception not configured"
    fi
fi

# =============================================================================
# 7. Persist environment and drop privileges
# =============================================================================
if [ "$(id -u)" = "0" ]; then
    # Persist environment for interactive shells
    cat >> /home/$TARGET_USER/.profile <<EOF
export NODE_EXTRA_CA_CERTS=$CA_CERT
export KUBECONFIG=$USER_KUBECONFIG
EOF

    exec gosu "$TARGET_USER" "$@"
else
    exec "$@"
fi
