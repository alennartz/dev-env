# Claude Code Sandboxed Dev Environment

A secure, network-isolated container for running Claude Code with `--dangerously-skip-permissions`.

## Published Images

| Image | Size | Purpose |
|-------|------|---------|
| `ghcr.io/alennartz/claude-sandbox-proxy` | ~22MB | Squid proxy with SSL bump + iptables (minimal whitelist) |
| `ghcr.io/alennartz/claude-sandbox-base` | ~418MB | Debian slim + Claude Code + git + essentials |
| `ghcr.io/alennartz/claude-sandbox-base-podman` | ~550MB | Base + Podman for Docker-in-Docker (elevated capabilities) |

## Quick Start

### Option 1: Use the Sandbox Script (Recommended)

The easiest way to sandbox Claude for any repository:

1. **Clone this repo** (one-time):
   ```bash
   git clone https://github.com/alennartz/dev-env.git ~/dev-env
   ```

2. **Set up an alias** (add to your `~/.bashrc` or `~/.zshrc`):
   ```bash
   alias claude-sandbox='~/dev-env/claude-sandbox.sh'
   ```

3. **Run Claude in any project**:
   ```bash
   cd ~/your-project
   claude-sandbox
   ```

The script automatically:
- Detects and uses local `.devcontainer/` setups if present
- Falls back to GHCR images if no local setup exists
- Resolves whitelists from target repo, this repo, or image defaults
- Manages container lifecycle (start, stop, status)

### Option 2: Copy Template to Your Project

For projects that need a permanent `.devcontainer/` setup:

1. **Copy the template** to your project:
   ```bash
   cp -r template/ your-project/.devcontainer/
   ```

2. **Configure credentials** (one-time setup on host):
   ```bash
   claude login
   echo '{"bypassPermissionsModeAccepted": true}' > ~/.claude/settings.json
   ```

3. **Customize `whitelist.txt`** with domains your project needs

4. **Open in VS Code** → "Reopen in Container"

5. **Run Claude Code**:
   ```bash
   claude --dangerously-skip-permissions
   ```

See [template/README.md](template/README.md) for customization options.

## Architecture

```text
┌─────────────────────────────────────────┐
│  proxy (NET_ADMIN)  │  sandbox (no caps)│
└─────────────────────┴───────────────────┘
           │
    iptables ──► squid ──► whitelist ──► internet
```

- **Network isolation**: All traffic forced through proxy
- **Domain whitelist**: Only explicitly allowed domains accessible
- **No sudo**: Claude runs as unprivileged user
- **Capability separation**: Only proxy has NET_ADMIN
- **Read-only credentials**: Host auth files mounted as read-only

## Docker-in-Docker Support

For workflows requiring container operations (building images, running containers), use the Podman-enabled variant:

```yaml
# In docker-compose.yml, use sandbox-podman instead of sandbox
services:
  sandbox-podman:
    image: ghcr.io/alennartz/claude-sandbox-base-podman:latest
```

**Security trade-off**: The Podman variant requires `CAP_SYS_ADMIN` for user namespace UID mapping. This is an elevated capability that increases attack surface. Mitigations include:

- Custom seccomp profile blocking kernel modules, BPF, kexec
- Explicit capability dropping (only 9 capabilities vs Docker's 14 defaults)
- Network isolation preserved (all traffic through proxy)
- Non-root user execution

See [ADR-006](docs/adr/006-adopt-podman-rootless.md) for the full security analysis.

**Default recommendation**: Use the base image unless you specifically need Docker-in-Docker.

## Credentials

The sandbox mounts credentials directly from your host as read-only files:

| Host File | Mounted To | Purpose |
|-----------|------------|---------|
| `~/.claude/.credentials.json` | `/home/developer/.claude/.credentials.json:ro` | OAuth tokens for Anthropic API |
| `~/.claude/settings.json` | `/home/developer/.claude/settings.json:ro` | Contains `bypassPermissionsModeAccepted: true` |

## Repository Structure

```text
├── claude-sandbox.sh          # Launch script - sandbox Claude in any repo
├── images/                    # Published to GHCR
│   ├── proxy/                 # Squid proxy with iptables
│   │   ├── Dockerfile
│   │   ├── squid.conf
│   │   ├── whitelist.txt      # Minimal: only .anthropic.com
│   │   └── proxy-entrypoint.sh
│   ├── base/                  # Minimal sandbox
│   │   ├── Dockerfile
│   │   ├── trust-proxy-ca.sh
│   │   └── seccomp-podman.json  # Security profile for Podman
│   └── base-podman/           # Podman-enabled variant
│       ├── Dockerfile
│       ├── podman-wrapper.sh
│       └── containers.conf
├── template/                  # Copy to your project's .devcontainer/
│   ├── devcontainer.json
│   ├── docker-compose.yml
│   ├── whitelist.txt          # Example with common domains
│   └── README.md
├── local/                     # Local development files
│   └── whitelist.txt          # Extended whitelist for this repo
├── docs/
│   ├── adr/                   # Architecture Decision Records
│   ├── security.md            # Security model documentation
│   └── future-directions.md   # Alternative approaches for DinD
├── .devcontainer/             # Uses local builds for this repo
├── .github/workflows/         # CI/CD for publishing images
├── Makefile                   # Build helpers
└── CLAUDE.md                  # Context for Claude
```

## Development

### Building Locally

```bash
make build-all     # Build all images
make test          # Test the setup
make clean         # Clean up
```

### Using VS Code

Open this folder in VS Code and "Reopen in Container" to develop with the full local sandbox.

### Publishing Images

Images are automatically published to GHCR on push to main or release:

```bash
# Manual push (requires docker login to ghcr.io)
make push
```

## Whitelist Strategy

- **Proxy image** ships with minimal whitelist (just `.anthropic.com`)
- **Users must mount their own whitelist** to allow git, npm, etc.
- **Template** provides a starting point with common domains

## License

MIT
