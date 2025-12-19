# Claude Code Sandbox Template

This template sets up a secure, sandboxed environment for running Claude Code with `--dangerously-skip-permissions`.

## Quick Start

1. **Copy this folder** to your project's `.devcontainer/` directory

2. **Update image references** in `docker-compose.yml`:
   - Replace `OWNER` with the GitHub username/org hosting the images

3. **Configure your host for `--dangerously-skip-permissions`**:
   ```bash
   # Set the bypass flag (one-time setup)
   echo '{"bypassPermissionsModeAccepted": true}' > ~/.claude/settings.json
   ```
   This allows `--dangerously-skip-permissions` to work without prompts.

4. **Customize the whitelist** in `whitelist.txt`:
   - Add domains your project needs (package registries, APIs, etc.)

5. **Open in VS Code** and click "Reopen in Container"

6. **Run Claude Code**:
   ```bash
   claude --dangerously-skip-permissions
   ```

## Customization

### Adding Custom Tools

Create a `Dockerfile` in your `.devcontainer/`:

```dockerfile
FROM ghcr.io/OWNER/claude-sandbox-base:latest

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

The `docker-compose.yml` mounts two files from your host (read-only):

| File | Purpose |
|------|---------|
| `~/.claude/.credentials.json` | OAuth tokens for Anthropic API |
| `~/.claude/settings.json` | Must contain `bypassPermissionsModeAccepted: true` |

Both files are mounted read-only to prevent the container from modifying your host configuration.

**First-time setup**: Run `claude login` on your host machine before using the container.

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
