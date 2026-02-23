# Claude Code Sandbox Template

Copy this folder to your project's `.devcontainer/` to run Claude Code in a secure, network-isolated sandbox.

## Quick Start

1. Copy to `.devcontainer/` in your project
2. Edit `whitelist.txt` with domains your project needs
3. Open in VS Code → "Reopen in Container"
4. Run `claude --dangerously-skip-permissions`

**One-time host setup:**
```bash
claude login
echo '{"bypassPermissionsModeAccepted": true}' > ~/.claude/settings.json
```

### Windows Setup

If you're on Windows with Docker Desktop:

1. Install Claude Code: `npm install -g @anthropic-ai/claude-code`
2. Run `claude login` to authenticate
3. Create settings file: `New-Item -Path "$env:USERPROFILE\.claude.json" -ItemType File -Force`
4. Ensure git is configured: `git config --global user.name` and `git config --global user.email`

The template uses a cross-platform `setup-env.js` script that detects your home directory automatically.

**Important:** The template `docker-compose.yml` mounts Claude from `~/.local/share/claude/` (the shell installer layout). If you installed Claude via `npm install -g`, use `claude-sandbox.ps1` instead — it detects your npm install automatically. For VS Code Dev Containers, the shell installer layout is required.

**Note:** The `claude-sandbox-bwrap.sh` script is Linux-only. On Windows, use `claude-sandbox.ps1` or this template (with the shell installer).

## Extensibility

### Adding Tools

Create a `Dockerfile` in `.devcontainer/`:

```dockerfile
FROM ghcr.io/alennartz/claude-sandbox-base:latest

USER root
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*
USER developer
```

Update `docker-compose.yml`:
```yaml
sandbox:
  build:
    context: .
    dockerfile: Dockerfile
  # Comment out or remove the 'image:' line
```

### Adding Whitelisted Domains

Edit `whitelist.txt`. Common additions:

```text
# Python
.pypi.org
.pythonhosted.org
files.pythonhosted.org

# Go
.golang.org
proxy.golang.org
sum.golang.org

# Rust
.crates.io
static.crates.io

# .NET
.nuget.org
api.nuget.org

# Ruby
.rubygems.org

# Container registries
.docker.io
.docker.com
registry-1.docker.io
production.cloudflare.docker.com
```

After editing, rebuild: `docker compose build proxy`

### Enabling Docker-in-Docker

If Claude needs to build or run containers, use the Podman-enabled variant.

In `docker-compose.yml`, change the sandbox service to use `sandbox-podman`:
```yaml
services:
  sandbox-podman:
    image: ghcr.io/alennartz/claude-sandbox-base-podman:latest
    # ... rest of config
```

Or extend the Podman base in your Dockerfile:
```dockerfile
FROM ghcr.io/alennartz/claude-sandbox-base-podman:latest
# Your additions...
```

**Security note:** The Podman variant requires `CAP_SYS_ADMIN`. Only use if you need container operations.

### Extension Patterns

**Python development:**
```dockerfile
FROM ghcr.io/alennartz/claude-sandbox-base:latest
USER root
RUN apt-get update && apt-get install -y python3 python3-pip python3-venv
USER developer
```

**Node.js (already included):**
The base image includes Node.js 22.

**Go development:**
```dockerfile
FROM ghcr.io/alennartz/claude-sandbox-base:latest
USER root
RUN curl -fsSL https://go.dev/dl/go1.22.0.linux-amd64.tar.gz | tar -C /usr/local -xzf -
ENV PATH="/usr/local/go/bin:${PATH}"
USER developer
```

**Rust development:**
```dockerfile
FROM ghcr.io/alennartz/claude-sandbox-base:latest
USER root
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"
USER developer
```

## How It Works

- All network traffic goes through a Squid proxy with domain whitelisting
- Only domains in `whitelist.txt` are accessible
- Claude runs as unprivileged `developer` user (no sudo)
- Host credentials mounted read-only

## Troubleshooting

**Connection refused / timeouts:**
Add the domain to `whitelist.txt` and rebuild: `docker compose build proxy`

**Certificate errors:**
The proxy intercepts HTTPS. Tools with certificate pinning may fail (rare).

**Claude not found:**
Ensure Claude Code is installed on your host:
- Linux/macOS: `curl -fsSL https://claude.ai/install.sh | sh`
- Windows: `npm install -g @anthropic-ai/claude-code`

## Files

| File | Purpose |
|------|---------|
| `devcontainer.json` | VS Code container configuration |
| `docker-compose.yml` | Container orchestration |
| `whitelist.txt` | Allowed network domains |
