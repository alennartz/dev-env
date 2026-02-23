# Claude Code Sandboxed Dev Environment

A secure, network-isolated container for running Claude Code with `--dangerously-skip-permissions`.

## Published Images

| Image | Size | Purpose |
|-------|------|---------|
| `ghcr.io/alennartz/claude-sandbox-proxy` | ~22MB | Squid proxy with SSL bump + iptables (minimal whitelist) |
| `ghcr.io/alennartz/claude-sandbox-base` | ~418MB | Debian slim + Claude Code + git + essentials |
| `ghcr.io/alennartz/claude-sandbox-base-podman` | ~550MB | Base + Podman for Docker-in-Docker (elevated capabilities) |

## Quick Start

### Option 1: Bubblewrap Sandbox (Recommended — Linux only)

Runs Claude directly on the host with full access to your tools and configs, sandboxed via bubblewrap + overlay filesystem. Network is isolated through a minimal Docker container running Squid.

This is the lightweight option: instead of rebuilding your entire dev environment inside a container, it overlays the host root filesystem so all your existing tools, language runtimes, shell configs, and credentials work out of the box. The only Docker container involved is a ~22MB network jail for proxy enforcement.

> **Linux only.** This mode depends on Linux kernel namespaces (mount, PID, network), `bubblewrap`, `fuse-overlayfs`, and `nsenter` — none of which are available on macOS or Windows. On those platforms, use the [Docker Container Sandbox](#option-2-docker-container-sandbox) instead.

**Requirements**: `bubblewrap`, `fuse-overlayfs`, `docker`, `nsenter` (util-linux)

```bash
sudo apt install bubblewrap fuse-overlayfs util-linux
```

**Usage**:

```bash
./claude-sandbox-bwrap.sh ~/myproject              # Sandbox a project
./claude-sandbox-bwrap.sh ~/myproject -- --resume   # Pass args to Claude
./claude-sandbox-bwrap.sh --status                  # Check network jail status
./claude-sandbox-bwrap.sh --stop                    # Stop network jail
```

**How it works**:

```text
┌──────────────────────────────────────────────────────────────┐
│  Host (your machine)                                         │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐     │
│  │  bwrap sandbox                                      │     │
│  │  - Overlay of entire / (writes are ephemeral)       │     │
│  │  - Workspace bind-mount (RW, persists)              │     │
│  │  - ~/.claude bind-mount (RW, persists)              │     │
│  │  - All host tools, configs, shell available         │     │
│  └──────────────────────┬──────────────────────────────┘     │
│                         │ nsenter --net                       │
│  ┌──────────────────────▼──────────────────────────────┐     │
│  │  Network jail (Docker container)                    │     │
│  │  - iptables redirect all traffic to Squid           │     │
│  │  - Squid enforces domain whitelist                  │     │
│  │  - SSL bump for HTTPS inspection                    │     │
│  └─────────────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────────────┘
```

The overlay filesystem means Claude sees the entire host root filesystem but writes go to a temporary layer. Only workspace and `~/.claude` directories persist changes back to the host. The network jail container is reusable across sandbox sessions.

**Whitelist**: Provide a domain whitelist via:
- `$PWD/.devcontainer/whitelist.txt`
- `~/.claude/whitelist.txt`
- `$SCRIPT_DIR/local/whitelist.txt`
- Or set `WHITELIST=/path/to/whitelist.txt`

### Option 2: Docker Container Sandbox (Linux, macOS, Windows)

The cross-platform option. Runs Claude inside a Docker container with a companion Squid proxy container for network isolation. Requires rebuilding your dev toolchain inside the container, but works anywhere Docker runs.

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

### Option 3: Copy Template to Your Project

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

## Choosing an Approach

| | Bubblewrap (Linux only) | Docker Container (any OS) |
|---|---|---|
| **Host tools available** | All — overlays host `/` directly | None — must install in container |
| **Shell/configs** | Your shell, dotfiles, aliases | Minimal bash, no host configs |
| **Setup per project** | Whitelist file only | Dockerfile or image customization |
| **Network isolation** | Transparent proxy (iptables) | Transparent proxy (iptables) |
| **Filesystem isolation** | Overlay — writes are ephemeral | Container — writes are ephemeral |
| **Resource overhead** | ~22MB network jail container | ~418MB+ sandbox container |
| **Platform** | Linux (kernel namespaces required) | Linux, macOS, Windows (via Docker) |

Both approaches enforce the same network security model: all traffic is forced through a Squid transparent proxy that only allows whitelisted domains. The difference is in how the sandbox environment is constructed.

## Architecture

### Bubblewrap Mode

Uses the host filesystem directly via overlay, with network isolation from a minimal Docker container:

- **Full host tools**: All host binaries, libraries, and configs available (no rebuilding dev environment)
- **Ephemeral writes**: fuse-overlayfs on `/` makes all writes temporary except workspace and `~/.claude`
- **Transparent proxy**: iptables in the network jail redirect all traffic through Squid (proxy-unaware tools work)
- **No capabilities**: bwrap sandbox runs as regular user; only the network jail container has NET_ADMIN
- **Same identity**: Runs as your host user with all environment variables preserved

### Docker Container Mode

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
├── claude-sandbox-bwrap.sh    # Bubblewrap sandbox - uses host tools directly
├── claude-sandbox.sh          # Docker container sandbox - any repo
├── images/                    # Published to GHCR
│   ├── proxy/                 # Squid proxy with iptables
│   │   ├── Dockerfile
│   │   ├── squid.conf
│   │   ├── whitelist.txt      # Minimal: only .anthropic.com
│   │   └── proxy-entrypoint.sh
│   ├── netjail/               # Minimal network jail for bwrap mode
│   │   ├── Dockerfile
│   │   ├── entrypoint.sh
│   │   ├── squid.conf
│   │   └── whitelist.txt
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
│   └── security.md            # Security model documentation
├── .devcontainer/             # Uses local builds for this repo
├── .github/workflows/         # CI/CD for publishing images
├── Makefile                   # Build helpers
└── CLAUDE.md                  # Context for Claude
```

## Development

### Building Locally

```bash
make build-all      # Build all images (proxy, base, base-podman, netjail)
make build-netjail  # Build network jail image only (for bwrap mode)
make test           # Test Docker container setup
make test-bwrap     # Test bubblewrap sandbox mode
make clean          # Clean up
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
