# Claude Code Sandboxed Development Environment

This repository defines a secure, sandboxed Docker development container for running Claude Code with `--dangerously-skip-permissions` safely.

This repo also has a .devcontainer folder and uses itself (inception style) to develop itself. HOWEVER you have a tendency to accidentally put things that belong in the root of the repo in side the .devcontainer folder, getting confused about what goes where. the .devcontainer folder should be minimal and just use locally pre-built images from the current repo.

Esers of this project should be able to add the smallest simplest, vanilaest possible .devcontainers setup to their repos to use this claude sandbox devcontainer in their project.

## Project Structure

```text
dev-env/
├── Dockerfile              # Sandbox container with runtimes and tools
├── Dockerfile.proxy        # Squid proxy with SSL bump
├── proxy-entrypoint.sh     # Proxy startup (iptables + squid)
├── squid.conf              # Squid transparent proxy config
├── whitelist.txt           # Allowed domains
├── trust-proxy-ca.sh       # Script to trust proxy's SSL certificate
├── CLAUDE.md               # This file
├── README.md               # User documentation
├── .devcontainer/
│   ├── devcontainer.json   # VS Code Dev Containers configuration
│   └── docker-compose.yml  # Two-container orchestration (minimal)
└── .vscode/
    └── tasks.json          # Build/run tasks
```

## Architecture

```text
┌─────────────────────────────────────────────────────────┐
│ Docker Compose                                          │
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │ Shared Network Namespace                         │   │
│  │                                                  │   │
│  │  ┌───────────────┐    ┌───────────────┐        │   │
│  │  │    proxy      │    │    sandbox    │        │   │
│  │  │  (NET_ADMIN)  │    │  (no caps)    │        │   │
│  │  │               │    │               │        │   │
│  │  │  - squid      │    │  - claude     │        │   │
│  │  │  - iptables   │    │  - dev tools  │        │   │
│  │  └───────────────┘    └───────────────┘        │   │
│  │         │                     │                 │   │
│  │         └─────────┬───────────┘                 │   │
│  │                   │                             │   │
│  │           iptables rules redirect               │   │
│  │           all HTTP/HTTPS to squid               │   │
│  └─────────────────────┼───────────────────────────┘   │
│                        │                               │
│                   [ Internet ]                         │
│              (whitelisted domains only)                │
└─────────────────────────────────────────────────────────┘
```

## Key Files

### Dockerfile

Defines the sandbox container with:

- Base: Debian Bookworm
- Language runtimes: .NET, Go, Rust, Python 3
- Node.js (required for Claude Code)
- Development tools: ripgrep, fd, fzf, jq, yq, git, etc.
- Non-root `developer` user with passwordless sudo
- Claude Code installed globally via npm

### Dockerfile.proxy

Squid proxy container:

- Alpine-based for minimal footprint
- Squid configured for transparent HTTP/HTTPS interception
- SSL bump to inspect HTTPS traffic
- iptables rules to redirect all traffic

### whitelist.txt

Domain whitelist for allowed outbound connections:

- Claude API (.anthropic.com)
- Git hosting (.github.com, .githubusercontent.com)
- Package managers (npm, PyPI, NuGet, Go, Rust)
- Cloud providers (AWS, Azure, GCP)

## Security Model

- **Network isolation**: All HTTP/HTTPS traffic forced through squid proxy via iptables
- **Domain whitelist**: Squid only allows connections to whitelisted domains
- **SSL bump**: HTTPS traffic is intercepted and inspected (proxy generates certs)
- **Capability separation**: Only proxy has NET_ADMIN; sandbox has no special capabilities
- **Transparent**: No proxy env vars needed; all tools work normally
- **Sandbox cannot bypass**: It shares proxy's network namespace but cannot modify iptables

## Development Workflow

### Using VS Code (recommended)

1. Open this folder in VS Code
2. Click "Reopen in Container" when prompted
3. Run `claude --dangerously-skip-permissions`

### Using Docker Compose directly

```bash
# Build
docker compose -f .devcontainer/docker-compose.yml build

# Start
docker compose -f .devcontainer/docker-compose.yml up -d

# Enter sandbox
docker compose -f .devcontainer/docker-compose.yml exec sandbox bash

# Stop
docker compose -f .devcontainer/docker-compose.yml down
```

## Common Tasks

### Adding a new whitelisted domain

Edit `whitelist.txt`:

```text
.example.com
```

Then rebuild: `docker compose -f .devcontainer/docker-compose.yml build proxy`

### Adding a new package/tool

Edit `Dockerfile`, add to the appropriate RUN command:

```dockerfile
RUN apt-get install -y <package>
```

### Adding a new language runtime

1. Add installation commands to `Dockerfile`
2. Update PATH in the environment section
3. Add package manager domains to `whitelist.txt`

## Notes

- First container start generates SSL CA certificate (stored in volume)
- Sandbox trusts proxy's CA via `trust-proxy-ca.sh` entrypoint
- Tools with certificate pinning may fail (rare in dev tools)
- DNS is allowed; domain filtering happens at HTTP/HTTPS layer
