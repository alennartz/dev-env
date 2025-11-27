# Claude Code Sandboxed Dev Environment

A secure, network-isolated container for running Claude Code with `--dangerously-skip-permissions`.

**→ [User Documentation](docs/getting-started.md)**

## For Contributors

This repo provides:

1. **Sandbox container** (`Dockerfile`) - Development environment with Claude Code and common runtimes
2. **Proxy container** (`Dockerfile.proxy`) - Squid proxy with SSL bump and domain whitelist
3. **Orchestration** (`.devcontainer/`) - Docker Compose setup for VS Code Dev Containers

### Architecture

```text
┌─────────────────────────────────────────┐
│  proxy (NET_ADMIN)  │  sandbox (no caps)│
└─────────────────────┴───────────────────┘
           │
    iptables ──► squid ──► whitelist ──► internet
```

The sandbox shares the proxy's network namespace. All traffic is forced through squid via iptables. Sandbox has no capabilities to modify network rules.

### Repository Structure

```text
├── Dockerfile              # Sandbox image (runtimes, tools, Claude Code)
├── Dockerfile.proxy        # Proxy image (squid, iptables)
├── proxy-entrypoint.sh     # Sets up iptables, starts squid
├── squid.conf              # Squid transparent proxy config
├── whitelist.txt           # Allowed domains
├── trust-proxy-ca.sh       # Imports proxy CA into sandbox trust store
├── .devcontainer/          # Minimal VS Code devcontainer config
│   ├── devcontainer.json
│   └── docker-compose.yml
├── docs/                   # User-facing documentation
└── CLAUDE.md               # Context for Claude when editing this repo
```

### Development

This repo uses itself for development:

```bash
# Open in VS Code and "Reopen in Container"
# Or manually:
docker compose -f .devcontainer/docker-compose.yml build
docker compose -f .devcontainer/docker-compose.yml up -d
docker compose -f .devcontainer/docker-compose.yml exec sandbox bash
```

### Key Design Decisions

- **Two containers** - Capability separation (NET_ADMIN only on proxy)
- **Shared network namespace** - Proxy's iptables rules apply to sandbox
- **SSL bump** - Full HTTPS inspection without proxy env vars
- **Root files, minimal .devcontainer/** - Users copy minimal config, reference images

### Testing Changes

1. Edit files in root (`Dockerfile`, `squid.conf`, `whitelist.txt`, etc.)
2. Rebuild: `docker compose -f .devcontainer/docker-compose.yml build`
3. Test: `docker compose -f .devcontainer/docker-compose.yml up`

### Publishing Images

TODO: Set up GitHub Actions to publish to `ghcr.io`.

## License

MIT
