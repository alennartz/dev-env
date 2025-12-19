# Claude Code Sandboxed Dev Environment

A secure, network-isolated container for running Claude Code with `--dangerously-skip-permissions`.

## Published Images

| Image | Purpose |
|-------|---------|
| `ghcr.io/OWNER/claude-sandbox-proxy` | Squid proxy with SSL bump + iptables (minimal whitelist) |
| `ghcr.io/OWNER/claude-sandbox-base` | Minimal sandbox: Claude Code + git + essentials (no sudo) |

## Quick Start (For Your Project)

1. **Copy the template** to your project:
   ```bash
   cp -r template/ your-project/.devcontainer/
   ```

2. **Update image references** in `docker-compose.yml`:
   - Replace `OWNER` with the GitHub username/org

3. **Configure credentials** (one-time setup on host):
   ```bash
   # Login to Claude (if not already)
   claude login

   # Enable --dangerously-skip-permissions without prompts
   echo '{"bypassPermissionsModeAccepted": true}' > ~/.claude/settings.json
   ```

4. **Customize `whitelist.txt`** with domains your project needs

5. **Open in VS Code** → "Reopen in Container"

6. **Run Claude Code**:
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

## Credentials

The sandbox mounts two files from your host machine (both read-only):

| File | Purpose |
|------|---------|
| `~/.claude/.credentials.json` | OAuth tokens for Anthropic API |
| `~/.claude/settings.json` | Contains `bypassPermissionsModeAccepted: true` |

This avoids re-authentication on every container rebuild while preventing the sandbox from modifying your host configuration.

## Repository Structure

```text
├── images/                    # Published to GHCR
│   ├── proxy/                 # Squid proxy with iptables
│   │   ├── Dockerfile
│   │   ├── squid.conf
│   │   ├── whitelist.txt      # Minimal: only .anthropic.com
│   │   └── proxy-entrypoint.sh
│   └── base/                  # Minimal sandbox
│       ├── Dockerfile
│       └── trust-proxy-ca.sh
├── template/                  # Copy to your project's .devcontainer/
│   ├── devcontainer.json
│   ├── docker-compose.yml
│   ├── whitelist.txt          # Example with common domains
│   └── README.md
├── local/                     # Personal full sandbox (not published)
│   ├── Dockerfile             # Full dev environment with many runtimes
│   └── whitelist.txt          # Extended whitelist for this repo
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
