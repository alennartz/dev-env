# Claude Code Sandboxed Development Environment

This repository provides a secure, sandboxed Docker development container for running Claude Code with `--dangerously-skip-permissions` safely.

## Repository Organization

The repo is organized into three main areas:

- **`images/`** - Published to GHCR (reusable by other repos)
- **`template/`** - Files users copy to their project's `.devcontainer/`
- **`local/`** - Personal full dev environment (not published)

The `.devcontainer/` folder is minimal and references the local builds.

## Project Structure

```text
dev-env/
├── images/                    # Published to GHCR
│   ├── proxy/
│   │   ├── Dockerfile         # Squid proxy with SSL bump
│   │   ├── squid.conf         # Transparent proxy config
│   │   ├── whitelist.txt      # MINIMAL: only .anthropic.com
│   │   └── proxy-entrypoint.sh
│   └── base/
│       ├── Dockerfile         # Minimal sandbox (Claude + git only)
│       └── trust-proxy-ca.sh
├── template/                  # Users copy this to their .devcontainer/
│   ├── devcontainer.json
│   ├── docker-compose.yml     # References GHCR images
│   ├── whitelist.txt          # Example with common domains
│   └── README.md
├── local/                     # Personal dev environment (not published)
│   ├── Dockerfile             # Full sandbox with many runtimes
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
- Alpine-based, minimal footprint
- SSL bump for HTTPS inspection
- iptables to redirect all traffic
- Ships with MINIMAL whitelist (only `.anthropic.com`)

**`images/base/`** - Minimal sandbox:
- Debian Bookworm slim
- Node.js (for Claude Code)
- Claude Code, git, ripgrep, jq
- Non-root `developer` user with **NO SUDO**

### Template (template/)

Files for users to copy to their project's `.devcontainer/`:
- References GHCR images
- Includes example whitelist with common domains
- Users customize by editing `whitelist.txt` or extending base image

### Local Development (local/)

Personal opinionated dev environment with:
- Python, .NET, Go, Rust runtimes
- Build tools, debuggers
- Extended whitelist
- **Not published** - for this repo only

## Security Model

- **Network isolation**: All traffic forced through proxy via iptables
- **Domain whitelist**: Only explicitly allowed domains accessible
- **No sudo**: Claude runs as unprivileged `developer` user
- **Capability separation**: Only proxy has NET_ADMIN
- **Transparent**: No proxy env vars needed
- **Read-only credentials**: Host auth files mounted read-only

## Credentials

The sandbox mounts two files from the host (both read-only):

| File | Purpose |
|------|---------|
| `~/.claude/.credentials.json` | OAuth tokens for Anthropic API |
| `~/.claude/settings.json` | Must contain `bypassPermissionsModeAccepted: true` |

**Setup**: Users must run `claude login` on host, then set:
```bash
echo '{"bypassPermissionsModeAccepted": true}' > ~/.claude/settings.json
```

This enables `--dangerously-skip-permissions` without interactive prompts.

## Development Workflow

### Build Commands

```bash
make build-all     # Build all images
make build-proxy   # Build proxy only
make build-base    # Build base sandbox only
make build-local   # Build full local sandbox
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

### Adding a tool to local sandbox

Edit `local/Dockerfile`, then rebuild:
```bash
docker compose -f .devcontainer/docker-compose.yml build sandbox
```

### Updating published base image

Edit `images/base/Dockerfile`, commit, push to main.

## Notes

- First run generates SSL CA certificate (persisted in Docker volume)
- Sandbox trusts proxy's CA via `trust-proxy-ca.sh` entrypoint
- Tools with certificate pinning may fail (rare)
- DNS is allowed; filtering happens at HTTP/HTTPS layer
