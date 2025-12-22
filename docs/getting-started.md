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
    # Or build from source:
    # build:
    #   context: https://github.com/alennartz/dev-env.git#main:images/proxy
    #   dockerfile: Dockerfile
    cap_add:
      - NET_ADMIN
    volumes:
      - squid-ssl:/etc/squid/ssl

  sandbox:
    image: ghcr.io/alennartz/claude-sandbox-base:latest
    # Or build from source:
    # build:
    #   context: https://github.com/alennartz/dev-env.git#main:images/base
    #   dockerfile: Dockerfile
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
      # Mount host Claude config (read-only, copied to writable location at startup)
      - ${HOME}/.claude:/home/developer/.claude-host:ro
    entrypoint: ["/bin/sh", "/usr/local/bin/trust-proxy-ca.sh"]
    command: ["sleep", "infinity"]

volumes:
  squid-ssl:
```

## Open in Container

1. Open your project in VS Code
2. Press `Ctrl+Shift+P` (or `Cmd+Shift+P` on Mac)
3. Select "Dev Containers: Reopen in Container"
4. Wait for containers to build (first time takes a few minutes)

## Setup Credentials (One-Time)

Before using the sandbox, authenticate Claude Code on your **host machine**:

```bash
# On your host (not in the container)
claude login
```

Your credentials at `~/.claude/` are automatically synced into the container at startup.

## Run Claude Code

Once inside the container, just run:

```bash
claude
```

The container is pre-configured to run in bypass permissions mode, so you don't need the `--dangerously-skip-permissions` flag. This is safe because:
- The sandbox network restricts access to whitelisted domains only
- Your host credentials are mounted read-only
- The container runs as a non-root user

## What You Get

- **Network isolation**: Only whitelisted domains (Claude API, GitHub, npm, etc.) are accessible
- **Full Claude Code**: All features work, including file editing and shell commands
- **Your code stays local**: Workspace is mounted read-write

## Next Steps

- [How It Works](how-it-works.md) - Understand the security architecture
- [Configuration](configuration.md) - Customize the whitelist and settings
- [Troubleshooting](troubleshooting.md) - Common issues and solutions
