# Claude Code Sandboxed Dev Environment

A secure, sandboxed development container for running Claude Code with `--dangerously-skip-permissions` without compromising your host machine.

## Security Model

- **Network isolation**: Firewall blocks all outbound traffic except whitelisted domains
- **Filesystem isolation**: Container cannot access host filesystem except mounted ~/repos
- **Ephemeral environment**: System changes don't persist (only ~/repos is permanent)

## Quick Start

### Using VS Code
1. Install the "Dev Containers" extension
2. Open this folder in VS Code
3. Click "Reopen in Container"
4. Run `claude --dangerously-skip-permissions`

### Using Docker CLI
```bash
# Build
cd .devcontainer && docker build -t claude-sandbox .

# Run
docker run -it --cap-add=NET_ADMIN -v ~/repos:/home/developer/repos claude-sandbox

# Inside container
claude login  # First time only
claude --dangerously-skip-permissions
```

## What's Included

**Runtimes:**
- .NET SDK (latest LTS)
- Go (latest stable)
- Rust (latest stable)
- Python 3 + poetry, ruff
- Node.js (for Claude Code)

**Tools:**
- git, curl, wget
- ripgrep, fd, fzf, jq, yq
- gdb, strace, htop
- build-essential

## Customization

### Adding Whitelisted Domains

Edit `.devcontainer/init-firewall.sh`:
```bash
iptables -A OUTPUT -d example.com -j ACCEPT
```

### Adding System Packages

Edit `.devcontainer/Dockerfile`:
```dockerfile
RUN apt-get install -y <package>
```

### Rebuild After Changes
```bash
cd .devcontainer && docker build -t claude-sandbox .
```

## Files

| File | Purpose |
|------|---------|
| `.devcontainer/devcontainer.json` | VS Code devcontainer config |
| `.devcontainer/Dockerfile` | Container image definition |
| `.devcontainer/init-firewall.sh` | Network firewall rules |
| `.devcontainer/CLAUDE.md` | Context instructions for Claude CLI |
| `CLAUDE.md` | Context for Claude when editing this repo |
