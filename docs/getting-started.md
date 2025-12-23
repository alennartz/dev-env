# Getting Started

Add a secure Claude Code sandbox to your project in under 5 minutes.

## Prerequisites

- Docker Desktop (or Docker Engine + Compose)
- VS Code with [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)

## Add to Your Project

Create a `.devcontainer/` folder in your project with two files:

### `.devcontainer/devcontainer.json`

```json
{
  "name": "Claude Code Sandbox",
  "dockerComposeFile": "docker-compose.yml",
  "service": "sandbox",
  "workspaceFolder": "/workspaces/${localWorkspaceFolderBasename}",
  "remoteUser": "developer"
}
```

> **Important**: The `remoteUser` setting ensures VS Code runs as the `developer` user, which has proper access to credentials.

### `.devcontainer/docker-compose.yml`

```yaml
services:
  proxy:
    image: ghcr.io/alennartz/claude-sandbox-proxy:latest
    cap_add:
      - NET_ADMIN
    volumes:
      - squid-ssl:/etc/squid/ssl
      # Mount your whitelist (proxy only allows .anthropic.com by default)
      - ./whitelist.txt:/etc/squid/whitelist.txt:ro

  sandbox:
    image: ghcr.io/alennartz/claude-sandbox-base:latest
    network_mode: "service:proxy"
    depends_on:
      proxy:
        condition: service_healthy
    environment:
      - NODE_EXTRA_CA_CERTS=/etc/squid/ssl/squid-ca-cert.pem
      - WORKSPACE_FOLDER=${LOCAL_WORKSPACE_FOLDER_BASENAME:-project}
    volumes:
      - squid-ssl:/etc/squid/ssl:ro
      - ..:/workspaces/${LOCAL_WORKSPACE_FOLDER_BASENAME:-project}:cached
      # Mount Claude binary directory (entrypoint creates symlink in ~/.local/bin)
      - ${HOME}/.local/share/claude:/home/developer/.local/share/claude:ro
      # Mount Claude config directly (RW)
      - ${HOME}/.claude:/home/developer/.claude:cached
      - ${HOME}/.claude.json:/home/developer/.claude.json:cached
      # Mount git config for commits
      - ${HOME}/.gitconfig:/home/developer/.gitconfig:ro
      - ${HOME}/.git-credentials:/home/developer/.git-credentials:ro
    entrypoint: ["/bin/sh", "/usr/local/bin/trust-proxy-ca.sh"]
    command: ["sleep", "infinity"]
    healthcheck:
      test: ["CMD", "test", "-x", "/home/developer/.local/bin/claude"]
      interval: 2s
      timeout: 5s
      retries: 15
      start_period: 5s

volumes:
  squid-ssl:
```

You'll also need a `whitelist.txt` file - copy from `template/whitelist.txt` or create your own.

## Open in Container

1. Open your project in VS Code
2. Press `Ctrl+Shift+P` (or `Cmd+Shift+P` on Mac)
3. Select "Dev Containers: Reopen in Container"
4. Wait for containers to build (first time takes a few minutes)

## Setup Credentials (One-Time)

Before using the sandbox, set up Claude Code on your **host machine**:

```bash
# On your host (not in the container)
# 1. Install Claude Code
curl -fsSL https://claude.ai/install.sh | sh

# 2. Authenticate
claude login

# 3. Create config file if missing
touch ~/.claude.json
```

Your host's `~/.claude/` and `~/.local/share/claude/` directories are mounted directly into the container.

## Run Claude Code

Once inside the container, just run:

```bash
claude
```

To enable bypass permissions mode (so you don't need `--dangerously-skip-permissions`), add this to your host's `~/.claude/settings.json`:

```json
{
  "bypassPermissionsModeAccepted": true,
  "permissions": {
    "defaultMode": "bypassPermissions"
  }
}
```

This is safe because:
- The sandbox network restricts access to whitelisted domains only
- Claude binary and credentials are mounted from your host
- The container runs as a non-root user with no sudo

## What You Get

- **Network isolation**: Only whitelisted domains (Claude API, GitHub, npm, etc.) are accessible
- **Full Claude Code**: All features work, including file editing and shell commands
- **Your code stays local**: Workspace is mounted read-write

## Next Steps

- [How It Works](how-it-works.md) - Understand the security architecture
- [Configuration](configuration.md) - Customize the whitelist and settings
- [Troubleshooting](troubleshooting.md) - Common issues and solutions
