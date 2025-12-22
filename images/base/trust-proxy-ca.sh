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

# Sync Claude credentials from read-only host mount
# Only sync specific files - settings.json is baked into the image with bypass mode
CLAUDE_HOST="/home/developer/.claude-host"
CLAUDE_LOCAL="/home/developer/.claude"
CLAUDE_JSON_LOCAL="/home/developer/.claude.json"

if [ -d "$CLAUDE_HOST" ]; then
    echo "Syncing Claude credentials from host..."

    # Copy credentials file (OAuth tokens)
    if [ -f "$CLAUDE_HOST/.credentials.json" ]; then
        cp "$CLAUDE_HOST/.credentials.json" "$CLAUDE_LOCAL/.credentials.json"
        chown "$TARGET_USER:$TARGET_USER" "$CLAUDE_LOCAL/.credentials.json"
    fi

    # Copy projects folder (conversation history)
    if [ -d "$CLAUDE_HOST/projects" ]; then
        cp -r "$CLAUDE_HOST/projects" "$CLAUDE_LOCAL/"
        chown -R "$TARGET_USER:$TARGET_USER" "$CLAUDE_LOCAL/projects"
    fi

    # Do NOT copy settings.json - use the baked-in version with bypass mode
fi

# Build ~/.claude.json with required settings for container
# Don't copy host file - build minimal config with correct values
WORKSPACE_NAME="${WORKSPACE_FOLDER:-dev-env}"
WORKSPACE_PATH="/workspaces/$WORKSPACE_NAME"

if [ ! -f "$CLAUDE_JSON_LOCAL" ]; then
    echo "Creating Claude settings for container..."
    cat > "$CLAUDE_JSON_LOCAL" << EOF
{
  "hasCompletedOnboarding": true,
  "bypassPermissionsModeAccepted": true,
  "installMethod": "npm-global",
  "autoUpdates": false,
  "$WORKSPACE_PATH": {
    "hasTrustDialogAccepted": true,
    "hasUserApprovedProjectSettings": true,
    "allowedTools": [],
    "mcpServers": {}
  }
}
EOF
    chown "$TARGET_USER:$TARGET_USER" "$CLAUDE_JSON_LOCAL"
fi

# Pre-create project folder for /workspaces
WORKSPACES_PROJECT="/home/developer/.claude/projects/-workspaces-$WORKSPACE_NAME"
if [ ! -d "$WORKSPACES_PROJECT" ]; then
    mkdir -p "$WORKSPACES_PROJECT"
    chown -R "$TARGET_USER:$TARGET_USER" "/home/developer/.claude/projects"
fi

# Note: settings.json with bypass permissions mode is baked into the Docker image

# Drop privileges and exec command
if [ "$(id -u)" = "0" ]; then
    # Persist NODE_EXTRA_CA_CERTS for interactive shells
    # Use .profile for POSIX compatibility (works on both bash and sh)
    echo "export NODE_EXTRA_CA_CERTS=$CA_CERT" >> /home/$TARGET_USER/.profile

    exec gosu "$TARGET_USER" "$@"
else
    exec "$@"
fi
