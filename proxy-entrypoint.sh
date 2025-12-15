#!/bin/sh
set -e

# Remove stale PID file from previous runs (prevents "already running" errors)
rm -f /var/run/squid.pid

SSL_DIR=/etc/squid/ssl

# Generate CA cert if not exists (persisted in volume)
if [ ! -f "$SSL_DIR/squid-ca.pem" ]; then
    echo "Generating Squid CA certificate..."
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -subj "/CN=Squid Proxy CA" \
        -keyout "$SSL_DIR/squid-ca.pem" \
        -out "$SSL_DIR/squid-ca.pem"
    # Extract certificate-only in PEM format (world-readable, for clients to trust)
    openssl x509 -in "$SSL_DIR/squid-ca.pem" -out "$SSL_DIR/squid-ca-cert.pem"
    chmod 644 "$SSL_DIR/squid-ca-cert.pem"
    chown squid:squid "$SSL_DIR/squid-ca.pem"
    echo "CA certificate generated."
fi

# Initialize SSL db
if [ ! -d "$SSL_DIR/ssl_db" ]; then
    echo "Initializing SSL certificate database..."
    /usr/lib/squid/security_file_certgen -c -s "$SSL_DIR/ssl_db" -M 16MB
    chown -R squid:squid "$SSL_DIR/ssl_db"
    echo "SSL database initialized."
fi

echo "Setting up iptables rules..."

# Note: Do NOT flush nat OUTPUT chain - Docker's DNS DNAT rules are there
# Only flush the filter OUTPUT chain
iptables -F OUTPUT 2>/dev/null || true

# Allow loopback
iptables -A OUTPUT -o lo -j ACCEPT

# Allow connections to local squid ports (needed after NAT redirect)
iptables -A OUTPUT -d 127.0.0.1 -p tcp --dport 3127 -j ACCEPT
iptables -A OUTPUT -d 127.0.0.1 -p tcp --dport 3128 -j ACCEPT
iptables -A OUTPUT -d 127.0.0.1 -p tcp --dport 3129 -j ACCEPT

# Allow established connections
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow DNS (needed for domain resolution)
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# Allow squid process to connect anywhere (it enforces whitelist)
iptables -A OUTPUT -m owner --uid-owner squid -j ACCEPT

# Redirect HTTP to squid transparent port
iptables -t nat -A OUTPUT -p tcp --dport 80 -m owner ! --uid-owner squid -j REDIRECT --to-port 3128

# Redirect HTTPS to squid SSL bump port
iptables -t nat -A OUTPUT -p tcp --dport 443 -m owner ! --uid-owner squid -j REDIRECT --to-port 3129

# Drop all other outbound traffic
iptables -A OUTPUT -j REJECT

echo "Firewall configured. Starting Squid proxy..."

# Start squid in foreground
exec squid -N
