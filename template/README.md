# Claude Code Sandbox Template

This template sets up a secure, sandboxed environment for running Claude Code with `--dangerously-skip-permissions`.

> **Tip**: For a quicker approach that doesn't require copying files, use the `claude-sandbox.sh` script from the [dev-env repo](https://github.com/alennartz/dev-env). It can sandbox any project without modifying it.

## Quick Start

1. **Copy this folder** to your project's `.devcontainer/` directory

2. **Configure your host for `--dangerously-skip-permissions`**:
   ```bash
   # Set the bypass flag (one-time setup)
   echo '{"bypassPermissionsModeAccepted": true}' > ~/.claude/settings.json
   ```
   This allows `--dangerously-skip-permissions` to work without prompts.

3. **Customize the whitelist** in `whitelist.txt`:
   - Add domains your project needs (package registries, APIs, etc.)

4. **Open in VS Code** and click "Reopen in Container"

5. **Run Claude Code**:
   ```bash
   claude --dangerously-skip-permissions
   ```

## Customization

### Adding Custom Tools

Create a `Dockerfile` in your `.devcontainer/`:

```dockerfile
FROM ghcr.io/alennartz/claude-sandbox-base:latest

USER root
RUN apt-get update && apt-get install -y python3 python3-pip
USER developer
```

Then update `docker-compose.yml`:

```yaml
sandbox:
  build:
    context: .
    dockerfile: Dockerfile
  # Remove or comment out the 'image:' line
```

### Adding Whitelist Domains

Edit `whitelist.txt` to add domains. Common examples:

```text
# Python packages
.pypi.org
.pythonhosted.org
files.pythonhosted.org

# Go modules
.golang.org
proxy.golang.org
sum.golang.org

# Rust crates
.crates.io
static.crates.io

# .NET packages
.nuget.org
api.nuget.org
```

## Credentials

The `docker-compose.yml` mounts two credential files directly from your host as read-only:

| File | Mounted To | Purpose |
|------|------------|---------|
| `~/.claude/.credentials.json` | `/home/developer/.claude/.credentials.json:ro` | OAuth tokens for Anthropic API |
| `~/.claude/settings.json` | `/home/developer/.claude/settings.json:ro` | Must contain `bypassPermissionsModeAccepted: true` |

**First-time setup**: Run `claude login` on your host machine before using the container.

### devcontainer.json Settings

The `devcontainer.json` includes `"remoteUser": "developer"` which ensures VS Code runs as the correct user with access to credentials. Do not remove this setting.

## Security Model

- **Network isolation**: All traffic forced through proxy
- **Domain whitelist**: Only explicitly allowed domains are accessible
- **No sudo**: Claude runs as unprivileged user
- **Transparent**: No proxy configuration needed in tools
- **Read-only credentials**: Container cannot modify host auth files

## Troubleshooting

### Connection refused errors
Check that the domain is in your `whitelist.txt` and rebuild the proxy:
```bash
docker compose build proxy
```

### Certificate errors
The proxy intercepts HTTPS. If a tool does certificate pinning, it may fail.
Most development tools work fine.
