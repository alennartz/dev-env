#!/bin/sh
# Trust the squid proxy CA certificate
# This script runs as entrypoint wrapper in the sandbox container
# Runs as root, installs CA, then drops privileges to developer user

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

# Create Claude symlink from mounted versions directory
# Host symlink uses absolute path with wrong username, so we create a new one
CLAUDE_DIR="/home/developer/.local/share/claude"
CLAUDE_BIN="/home/developer/.local/bin/claude"

if [ -d "$CLAUDE_DIR/versions" ] && [ "$(id -u)" = "0" ]; then
    LATEST=$(ls -t "$CLAUDE_DIR/versions" 2>/dev/null | head -1)
    if [ -n "$LATEST" ]; then
        echo "Setting up Claude binary (version $LATEST)..."
        ln -sf "$CLAUDE_DIR/versions/$LATEST" "$CLAUDE_BIN"
        chown -h "$TARGET_USER:$TARGET_USER" "$CLAUDE_BIN"
    else
        echo "WARNING: No Claude versions found in $CLAUDE_DIR/versions"
    fi
# npm global install layout (Windows / npm i -g @anthropic-ai/claude-code)
elif [ "${CLAUDE_INSTALL_TYPE:-}" = "npm" ] && [ "$(id -u)" = "0" ]; then
    NPM_DIR="/home/developer/.local/share/claude-npm"
    if [ -d "$NPM_DIR" ]; then
        # Discover entry point from package.json bin field
        ENTRY=$(node -e "const p=require('$NPM_DIR/package.json'); const b=Object.values(p.bin||{})[0]||p.main||'cli.mjs'; console.log(b)" 2>/dev/null || echo "cli.mjs")
        # Validate entry point - reject path traversal and shell metacharacters
        case "$ENTRY" in
            *..* | *\;* | *\|* | *\&* | *\`* | *\$*)
                echo "WARNING: Suspicious entry point '$ENTRY' in package.json, falling back to cli.mjs"
                ENTRY="cli.mjs"
                ;;
        esac
        echo "Setting up Claude binary (npm package, entry: $ENTRY)..."
        # Generate wrapper script - $NPM_DIR and $ENTRY expand now, \$@ stays literal
        cat > "$CLAUDE_BIN" <<WRAPPER
#!/bin/sh
exec node "$NPM_DIR/$ENTRY" "\$@"
WRAPPER
        chmod +x "$CLAUDE_BIN"
        chown "$TARGET_USER:$TARGET_USER" "$CLAUDE_BIN"
    else
        echo "WARNING: CLAUDE_INSTALL_TYPE=npm but no package found at $NPM_DIR"
    fi
fi

# Drop privileges and exec command
if [ "$(id -u)" = "0" ]; then
    # Persist NODE_EXTRA_CA_CERTS for interactive shells
    # Use .profile for POSIX compatibility (works on both bash and sh)
    echo "export NODE_EXTRA_CA_CERTS=$CA_CERT" >> /home/$TARGET_USER/.profile

    exec gosu "$TARGET_USER" "$@"
else
    exec "$@"
fi
