# Claude Code Sandboxed Development Environment

This repository provides a secure, sandboxed Docker development container for running Claude Code with `--dangerously-skip-permissions` safely.

## Repository Organization

The repo is organized into these main areas:

- **`claude-sandbox.sh`** - Launch script to sandbox Claude in any repository
- **`images/`** - Published to GHCR (reusable by other repos)
- **`template/`** - Files users copy to their project's `.devcontainer/`
- **`local/`** - Extended whitelist for this repo's development

The `.devcontainer/` folder is minimal and references the local builds.

## Project Structure

```text
dev-env/
├── claude-sandbox.sh          # Launch script - sandbox Claude in any repo
├── images/                    # Published to GHCR
│   ├── proxy/
│   │   ├── Dockerfile         # Squid proxy with SSL bump
│   │   ├── squid.conf         # Transparent proxy config
│   │   ├── whitelist.txt      # MINIMAL: only .anthropic.com
│   │   └── proxy-entrypoint.sh
│   └── base/
│       ├── Dockerfile         # Debian slim (~418MB)
│       └── trust-proxy-ca.sh
├── template/                  # Users copy this to their .devcontainer/
│   ├── devcontainer.json
│   ├── docker-compose.yml     # References GHCR images
│   ├── whitelist.txt          # Example with common domains
│   └── README.md
├── local/                     # Local development files
│   └── whitelist.txt          # Extended whitelist for this repo
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
make build-all     # Build all images
make build-proxy   # Build proxy only
make build-base    # Build base sandbox only
make test          # Test the setup
make clean         # Clean up
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

## Notes

- First run generates SSL CA certificate (persisted in Docker volume)
- Sandbox trusts proxy's CA via `trust-proxy-ca.sh` entrypoint
- Tools with certificate pinning may fail (rare)
- DNS is allowed; filtering happens at HTTP/HTTPS layer
- Auto-updates are disabled in the container; update Claude on your host to get new versions
