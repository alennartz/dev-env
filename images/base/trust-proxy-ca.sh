#!/bin/bash
# Trust the squid proxy CA certificate
# This script runs as entrypoint wrapper in the sandbox container

# Certificate-only PEM file (world-readable)
CA_CERT=/etc/squid/ssl/squid-ca-cert.pem

# Wait for CA cert to be available (proxy generates it)
MAX_WAIT=30
WAITED=0
while [ ! -f "$CA_CERT" ] && [ $WAITED -lt $MAX_WAIT ]; do
    echo "Waiting for proxy CA certificate..."
    sleep 1
    WAITED=$((WAITED + 1))
done

if [ -f "$CA_CERT" ]; then
    echo "Installing proxy CA certificate..."
    # Copy the PEM certificate (update-ca-certificates needs .crt extension)
    sudo cp "$CA_CERT" /usr/local/share/ca-certificates/squid-proxy-ca.crt
    sudo update-ca-certificates

    # Set Node.js to trust the CA
    export NODE_EXTRA_CA_CERTS="$CA_CERT"
    echo "export NODE_EXTRA_CA_CERTS=$CA_CERT" >> ~/.bashrc

    echo "Proxy CA certificate installed."
else
    echo "WARNING: Proxy CA certificate not found at $CA_CERT"
    echo "HTTPS connections may fail with certificate errors."
fi

# Execute the original command
exec "$@"
