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
    volumes:
      - squid-ssl:/etc/squid/ssl:ro
      # Mount credentials to staging location (entrypoint copies with correct ownership)
      - ${HOME}/.claude/.credentials.json:/tmp/claude-creds/.credentials.json:ro
      - ${HOME}/.claude/settings.json:/tmp/claude-creds/settings.json:ro
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

## Run Claude Code

Once inside the container:

```bash
# First time: authenticate
claude login

# Run Claude Code with full permissions (safe in sandbox)
claude --dangerously-skip-permissions
```

## What You Get

- **Network isolation**: Only whitelisted domains (Claude API, GitHub, npm, etc.) are accessible
- **Full Claude Code**: All features work, including file editing and shell commands
- **Your code stays local**: Workspace is mounted read-write

## Next Steps

- [How It Works](how-it-works.md) - Understand the security architecture
- [Configuration](configuration.md) - Customize the whitelist and settings
- [Troubleshooting](troubleshooting.md) - Common issues and solutions
