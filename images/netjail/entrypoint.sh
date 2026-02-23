#!/bin/sh
set -e

SSL_DIR=/etc/squid/ssl

# Generate CA cert if not exists (persisted in volume)
if [ ! -f "$SSL_DIR/squid-ca.pem" ]; then
    echo "[netjail] Generating Squid CA certificate..."
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -subj "/CN=Claude Sandbox Proxy CA" \
        -keyout "$SSL_DIR/squid-ca.pem" \
        -out "$SSL_DIR/squid-ca.pem"
    # Extract certificate-only in PEM format (for clients to trust)
    openssl x509 -in "$SSL_DIR/squid-ca.pem" -out "$SSL_DIR/squid-ca-cert.pem"
    chmod 644 "$SSL_DIR/squid-ca-cert.pem"
    chown squid:squid "$SSL_DIR/squid-ca.pem"
    echo "[netjail] CA certificate generated."
fi

# Initialize SSL db
if [ ! -d "$SSL_DIR/ssl_db" ]; then
    echo "[netjail] Initializing SSL certificate database..."
    /usr/lib/squid/security_file_certgen -c -s "$SSL_DIR/ssl_db" -M 16MB
    chown -R squid:squid "$SSL_DIR/ssl_db"
fi

echo "[netjail] Configuring iptables..."

# Allow loopback
iptables -A OUTPUT -o lo -j ACCEPT

# Allow connections to local squid ports
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

echo "[netjail] Network jail ready. Starting Squid..."

exec squid -N
