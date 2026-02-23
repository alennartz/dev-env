# Claude Code Sandboxed Development Environment

This repository provides a secure, sandboxed Docker development container for running Claude Code with `--dangerously-skip-permissions` safely.

## Repository Organization

The repo is organized into these main areas:

- **`claude-sandbox-bwrap.sh`** - Bubblewrap sandbox using host tools directly + network jail
- **`claude-sandbox.sh`** - Docker container sandbox for any repository
- **`images/`** - Published to GHCR (reusable by other repos)
- **`template/`** - Files users copy to their project's `.devcontainer/`
- **`local/`** - Extended whitelist for this repo's development
- **`docs/adr/`** - Architecture Decision Records for key design choices

The `.devcontainer/` folder is minimal and references the local builds.

## Project Structure

```text
dev-env/
├── claude-sandbox-bwrap.sh    # Bubblewrap sandbox - host tools + network jail
├── claude-sandbox.ps1         # PowerShell sandbox - Windows + Docker Desktop
├── claude-sandbox.sh          # Docker container sandbox - any repo
├── images/                    # Published to GHCR
│   ├── proxy/
│   │   ├── Dockerfile         # Squid proxy with SSL bump
│   │   ├── squid.conf         # Transparent proxy config
│   │   ├── whitelist.txt      # MINIMAL: only .anthropic.com
│   │   └── proxy-entrypoint.sh
│   ├── netjail/
│   │   ├── Dockerfile         # Minimal network jail (Alpine + squid + iptables)
│   │   ├── entrypoint.sh      # CA cert gen, iptables setup, squid launch
│   │   ├── squid.conf         # Transparent proxy config
│   │   └── whitelist.txt      # MINIMAL: only .anthropic.com
│   ├── base/
│   │   ├── Dockerfile         # Debian slim (~418MB)
│   │   ├── trust-proxy-ca.sh
│   │   └── seccomp-podman.json  # Custom seccomp for Podman
│   └── base-podman/
│       ├── Dockerfile         # Base + Podman for DinD (~550MB)
│       ├── podman-wrapper.sh  # Injects --cgroups=disabled
│       └── containers.conf    # Podman configuration
├── template/                  # Users copy this to their .devcontainer/
│   ├── devcontainer.json
│   ├── docker-compose.yml     # References GHCR images
│   ├── setup-env.js           # Node helper: resolves Claude paths cross-platform
│   ├── whitelist.txt          # Example with common domains
│   └── README.md
├── local/                     # Local development files
│   └── whitelist.txt          # Extended whitelist for this repo
├── docs/
│   ├── adr/                   # Architecture Decision Records
│   │   ├── 001-reject-host-docker-socket.md
│   │   ├── 002-reject-sysbox-envbox.md
│   │   ├── 003-reject-privileged-flag.md
│   │   ├── 004-replace-seccomp-unconfined.md
│   │   ├── 005-no-new-privileges-incompatible.md
│   │   └── 006-adopt-podman-rootless.md
│   └── security.md            # Security model documentation
├── tests/
│   ├── test-npm-layout.sh     # Verify npm-global Claude mount layout
│   └── test-setup-env.js      # Unit tests for setup-env.js
├── .devcontainer/             # Uses local builds
│   ├── devcontainer.json
│   └── docker-compose.yml
├── .github/workflows/
│   └── publish-images.yml     # CI/CD for GHCR
├── Makefile                   # Build helpers
├── CLAUDE.md                  # This file
└── README.md
```

## Key Concepts

### Published Images (images/)

**`images/proxy/`** - Squid proxy container:
- Minimal Alpine-based footprint
- SSL bump for HTTPS inspection
- iptables to redirect all traffic
- Ships with MINIMAL whitelist (only `.anthropic.com`)

**`images/base/`** - Minimal sandbox:
- Based on `node:22-slim` (Debian)
- Includes: git, ripgrep, jq, gosu (Claude Code mounted from host)
- Non-root `developer` user with **NO SUDO**
- PATH includes `~/.local/bin` for mounted Claude binary

**`images/netjail/`** - Network jail for bubblewrap mode:
- Minimal Alpine image (~22MB) with squid, iptables, openssl
- Provides a network namespace with transparent Squid proxy
- Host processes join this namespace via `nsenter`
- iptables redirect HTTP/HTTPS to Squid, reject all other outbound
- CA certificate generated on first run (persisted in Docker volume)

**`images/base-podman/`** - Docker-in-Docker variant:
- Extends base image with Podman, crun, fuse-overlayfs
- Requires elevated capabilities (CAP_SYS_ADMIN) - see ADR-006
- Includes podman-wrapper.sh for compose compatibility
- Docker CLI alias (`docker` → `podman`)

### Bubblewrap Sandbox (claude-sandbox-bwrap.sh)

An alternative to the Docker container approach that runs Claude directly on the host with full access to all host tools and configurations. Uses bubblewrap for filesystem isolation and a minimal Docker container (network jail) for network isolation.

**Architecture**:
- `fuse-overlayfs` on `/` with ephemeral tmpfs upper layer (writes don't affect host)
- Workspace and `~/.claude` bind-mounted through the overlay for persistence
- `nsenter --net` joins the network jail's namespace for transparent proxy
- All host environment variables passed through
- Proxy CA certificate injected into overlay's system CA bundle

**Requirements**: bubblewrap, fuse-overlayfs, docker, nsenter (util-linux)

**sudo usage**: The overlay mount on `/` requires `sudo fuse-overlayfs` due to copy-up operations on WSL2/ext4. The `nsenter` also requires sudo to access `/proc/PID/ns/net`. Inside the sandbox, Claude runs as the regular user.

### Windows Support (claude-sandbox.ps1)

PowerShell equivalent of `claude-sandbox.sh` for Windows-native developers using Docker Desktop. Discovers Claude installed via npm (`npm root -g`) or the shell installer, resolves credentials from `$env:USERPROFILE`, and generates compose files in `$env:TEMP`.

The container entrypoint (`trust-proxy-ca.sh`) handles both install layouts:
- Shell installer: symlinks from `versions/<ver>/` (existing behavior)
- npm global: creates a wrapper script that runs `node <package>/cli.mjs`

### Template (template/)

Files for users to copy to their project's `.devcontainer/`:
- References GHCR images
- Includes example whitelist with common domains
- Users customize by editing `whitelist.txt` or extending base image

### Sandbox Script (claude-sandbox.sh)

The recommended way to sandbox Claude for any repository. Run from any project directory:

```bash
/path/to/dev-env/claude-sandbox.sh              # Current directory
/path/to/dev-env/claude-sandbox.sh --repo PATH  # Specific repo
/path/to/dev-env/claude-sandbox.sh --status     # Check status
/path/to/dev-env/claude-sandbox.sh --stop       # Stop containers
```

The script automatically:
- Detects local `.devcontainer/` setups and uses them if present
- Falls back to locally-built images, then GHCR images
- Resolves whitelists from target repo → `local/whitelist.txt` → image default
- Generates docker-compose files on the fly for repos without `.devcontainer/`

### Local Development (local/)

Files for this repo's development (not published):
- `whitelist.txt` - Extended domain whitelist

## Security Model

- **Network isolation**: All traffic forced through proxy via iptables
- **Domain whitelist**: Only explicitly allowed domains accessible
- **Privilege drop**: Container starts as root to install CA cert, then permanently drops to `developer` user via gosu
- **No sudo**: sudo is not installed in base image; gosu only works if already root
- **Capability separation**: Only proxy has NET_ADMIN
- **Transparent**: No proxy env vars needed
- **Direct mounts**: Host Claude binary (RO) and config (RW) mounted directly

### Why gosu instead of sudo?

The `trust-proxy-ca.sh` entrypoint needs root to install the proxy's CA certificate. We use `gosu` to drop privileges permanently after init:

```
root (PID 1) → trust-proxy-ca.sh → exec gosu developer "$@" → developer (PID 1)
```

Unlike sudo, gosu cannot be used to regain root later - it requires `setuid()` which only root can call. See `docs/security.md` for details.

### Docker-in-Docker Security (Podman Variant)

The `base-podman` image requires elevated capabilities for user namespace UID mapping:

```yaml
cap_drop:
  - ALL
cap_add:
  - SYS_ADMIN     # Required for Podman UID mapping
  - MKNOD         # Required for /dev/fuse
  - CHOWN, DAC_OVERRIDE, FOWNER  # Required for gosu
  - SETUID, SETGID, SETFCAP, KILL  # Required for operations
security_opt:
  - seccomp=seccomp-podman.json  # Custom profile
```

**Mitigations:**
- Custom seccomp profile blocks kernel modules, BPF, kexec
- Only 9 capabilities vs Docker's 14 defaults
- Network isolation preserved (all traffic through proxy)
- Non-root user execution

See [ADR-006](docs/adr/006-adopt-podman-rootless.md) for the full security analysis.

## Credentials and Permissions

The host's Claude installation and git config are mounted directly into the container:

| Host | Container | Mode |
|------|-----------|------|
| `~/.local/share/claude/` | `/home/developer/.local/share/claude/` | RO |
| `~/.claude/` | `/home/developer/.claude/` | RW |
| `~/.claude.json` | `/home/developer/.claude.json` | RW |
| `~/.gitconfig` | `/home/developer/.gitconfig` | RO |
| `~/.git-credentials` | `/home/developer/.git-credentials` | RO |

The entrypoint script:
1. Installs the proxy CA certificate for HTTPS inspection
2. Creates a symlink from `~/.local/bin/claude` to the latest version in the mounted versions directory
3. Drops privileges to the `developer` user

**Setup**: Users must:
1. Install Claude Code natively on host: `curl -fsSL https://claude.ai/install.sh | sh`
2. Run `claude login` on host
3. Create `~/.claude.json` if missing: `touch ~/.claude.json`
4. Ensure git is configured: `git config --global user.name` and `git config --global user.email`
5. (Optional) For HTTPS credentials: `touch ~/.git-credentials` and configure `git config --global credential.helper store`

### Bypass Permissions Mode

Host settings are used directly (not overridden by the container). To enable bypass mode, add to your host's `~/.claude/settings.json`:

```json
{
  "bypassPermissionsModeAccepted": true,
  "permissions": {
    "defaultMode": "bypassPermissions"
  }
}
```

**Important**: The `devcontainer.json` must include `"remoteUser": "developer"` so VS Code sessions run as the correct user.

## Development Workflow

### Build Commands

```bash
make build-all      # Build all images (proxy, base, base-podman, netjail)
make build-proxy    # Build proxy only
make build-base     # Build base sandbox only
make build-base-podman  # Build Podman variant only
make build-netjail  # Build network jail only (for bwrap mode)
make test           # Test Docker container setup
make test-bwrap     # Test bubblewrap sandbox mode
make clean          # Clean up
```

### Using VS Code

Open this folder in VS Code → "Reopen in Container"

### Publishing

Images publish automatically via GitHub Actions on push to main.

Manual: `make push` (requires `docker login ghcr.io`)

## Common Tasks

### Adding a whitelisted domain (for this repo)

Edit `local/whitelist.txt`, then rebuild:
```bash
docker compose -f .devcontainer/docker-compose.yml build proxy
```

### Updating published base images

Edit `images/base/Dockerfile`, commit, push to main. The image is built and published automatically via GitHub Actions.

## Architecture Decision Records

Key design decisions are documented in `docs/adr/`:

- [ADR-001](docs/adr/001-reject-host-docker-socket.md): Why host Docker socket approaches were rejected
- [ADR-002](docs/adr/002-reject-sysbox-envbox.md): Why Sysbox/Envbox don't work in WSL2
- [ADR-003](docs/adr/003-reject-privileged-flag.md): Why we don't use `--privileged`
- [ADR-004](docs/adr/004-replace-seccomp-unconfined.md): Why we use a custom seccomp profile
- [ADR-005](docs/adr/005-no-new-privileges-incompatible.md): Why `no-new-privileges` can't be used
- [ADR-006](docs/adr/006-adopt-podman-rootless.md): Why Podman rootless is the chosen DinD approach

## Notes

- First run generates SSL CA certificate (persisted in Docker volume)
- Sandbox trusts proxy's CA via `trust-proxy-ca.sh` entrypoint
- Tools with certificate pinning may fail (rare)
- DNS is allowed; filtering happens at HTTP/HTTPS layer
- Auto-updates are disabled in the container; update Claude on your host to get new versions
