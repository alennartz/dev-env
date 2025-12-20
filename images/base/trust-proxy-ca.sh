#!/bin/sh
# Trust the squid proxy CA certificate
# This script runs as entrypoint wrapper in the sandbox container
# Runs as root, installs CA, then drops privileges to developer user
#
# Compatible with both Debian (glibc) and Alpine (musl) images

set -e

CA_CERT="/etc/squid/ssl/squid-ca-cert.pem"
TARGET_USER="${TARGET_USER:-developer}"

# Wait for CA cert to be available (proxy generates it)
i=1
while [ $i -le 30 ]; do
    [ -f "$CA_CERT" ] && break
    echo "Waiting for proxy CA certificate... ($i/30)"
    sleep 1
    i=$((i + 1))
done

if [ -f "$CA_CERT" ]; then
    # Running as root - install system-wide trust
    if [ "$(id -u)" = "0" ]; then
        echo "Installing proxy CA certificate..."
        cp "$CA_CERT" /usr/local/share/ca-certificates/squid-proxy-ca.crt
        update-ca-certificates
        echo "Proxy CA certificate installed."
    fi
else
    echo "WARNING: Proxy CA certificate not found at $CA_CERT"
    echo "HTTPS connections may fail with certificate errors."
fi

# Set Node.js CA environment variable
export NODE_EXTRA_CA_CERTS="$CA_CERT"

# Drop privileges and exec command
if [ "$(id -u)" = "0" ]; then
    # Persist NODE_EXTRA_CA_CERTS for interactive shells
    # Use .profile for POSIX compatibility (works on both bash and sh)
    echo "export NODE_EXTRA_CA_CERTS=$CA_CERT" >> /home/$TARGET_USER/.profile

    # Copy credentials from staging location if present
    CREDS_STAGING="/tmp/claude-creds"
    CLAUDE_DIR="/home/$TARGET_USER/.claude"
    if [ -d "$CREDS_STAGING" ]; then
        mkdir -p "$CLAUDE_DIR"
        # Copy all files including hidden ones
        cp -a "$CREDS_STAGING"/. "$CLAUDE_DIR"/
        chown -R "$TARGET_USER:$TARGET_USER" "$CLAUDE_DIR"
    fi

    # Use gosu (Debian) or su-exec (Alpine) for privilege drop
    if command -v gosu >/dev/null 2>&1; then
        exec gosu "$TARGET_USER" "$@"
    elif command -v su-exec >/dev/null 2>&1; then
        exec su-exec "$TARGET_USER" "$@"
    else
        echo "ERROR: Neither gosu nor su-exec found for privilege drop"
        exit 1
    fi
else
    exec "$@"
fi
