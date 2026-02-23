# Windows Native Support for Dev Container Mode

## Problem

Windows-native developers who use PowerShell, Docker Desktop (WSL2 backend), and keep their repos/tools on the Windows filesystem cannot use the current bash-only sandbox scripts. They need both CLI and VS Code Dev Container workflows that work without touching WSL directly.

## Scope

- **In scope**: Docker container mode (`claude-sandbox.ps1`), VS Code Dev Containers template
- **Out of scope**: Bubblewrap mode (Linux-only, documented as such)

## Approach

Native PowerShell script (`claude-sandbox.ps1`) that reimplements `claude-sandbox.sh` logic, plus cross-platform fixes to the VS Code Dev Container template. Shared Docker images remain unchanged (except a small entrypoint extension).

## Design

### 1. Claude Binary Discovery & Mounting

The container entrypoint (`trust-proxy-ca.sh`) expects Claude at `/home/developer/.local/share/claude/versions/<version>/`. On Windows, Claude is typically installed via npm with a different directory structure.

**Discovery order** (PowerShell script):
1. Shell installer layout: `$env:USERPROFILE\.local\share\claude\versions\` — mount as-is (matches existing container expectation)
2. npm global install: run `npm root -g`, check for `@anthropic-ai\claude-code` — mount to `/home/developer/.local/share/claude-npm:ro`
3. Error with setup guidance if neither found

**Entrypoint extension** (`trust-proxy-ca.sh`): Add a second branch after the existing `versions/` check. When `CLAUDE_INSTALL_TYPE=npm` is set, create a wrapper script at `/home/developer/.local/bin/claude` that runs `node /home/developer/.local/share/claude-npm/cli.mjs`. The container's `node:22-slim` base already provides Node.js.

This is backward-compatible — existing Linux/WSL users hit the first branch unchanged.

### 2. Credential & Config Path Resolution

Convention-based discovery from `$env:USERPROFILE`:

| Item | Windows Path | Container Mount | Mode | Required |
|------|-------------|----------------|------|----------|
| Claude config | `$env:USERPROFILE\.claude\` | `/home/developer/.claude/` | RW | Yes |
| Claude settings | `$env:USERPROFILE\.claude.json` | `/home/developer/.claude.json` | RW | Yes |
| Git config | `$env:USERPROFILE\.gitconfig` | `/home/developer/.gitconfig` | RO | Yes |
| Git credentials | `$env:USERPROFILE\.git-credentials` | `/home/developer/.git-credentials` | RO | No |

Script validates required paths exist, errors with setup instructions if missing. Optional paths silently skipped. Docker Desktop handles Windows-to-Linux path translation for volume mounts.

### 3. PowerShell Script (`claude-sandbox.ps1`)

Parameters: `-Repo <path>`, `-Status`, `-Stop`, `-StopAll`, `-List`, `-Help`

Flow:
1. Resolve target repo to absolute path
2. Generate project name: hash via `[System.Security.Cryptography.MD5]`, sanitize name
3. Detect image source (local-compose -> local-images -> ghcr)
4. Discover Claude binary (shell installer -> npm global)
5. Resolve whitelist (repo -> dev-env local -> image default)
6. Resolve credentials (convention-based from `$env:USERPROFILE`)
7. Generate `docker-compose.yml` + `.env` to `$env:TEMP\claude-sandbox-<hash>\`
8. `docker compose up -d`, wait for healthy
9. `docker compose exec` into sandbox with `claude --dangerously-skip-permissions`

Platform-specific equivalents:
- Hashing: `[System.Security.Cryptography.MD5]` instead of `md5sum`
- Temp dir: `$env:TEMP\claude-sandbox-<hash>\` instead of `/tmp/`
- Colors: `Write-Host -ForegroundColor` instead of ANSI escapes

### 4. Compose File Generation

Generated compose file is nearly identical to what `claude-sandbox.sh` produces, with two differences:

1. **Claude binary mount** varies by install method:
   - Shell installer: `$env:USERPROFILE\.local\share\claude:/home/developer/.local/share/claude:ro`
   - npm global: `<npm-root>\@anthropic-ai\claude-code:/home/developer/.local/share/claude-npm:ro`

2. **Environment variable** `CLAUDE_INSTALL_TYPE=npm` set when using npm layout (omitted for shell installer to preserve default behavior)

### 5. VS Code Dev Container Template

**Problem**: `${HOME}` in docker-compose.yml volume mounts doesn't resolve on Windows (PowerShell uses `$env:USERPROFILE`, not `$HOME`).

**Solution**: Replace the `initializeCommand` bash one-liner with a cross-platform Node.js script (`setup-env.js`). Node is available on both platforms (required for Claude Code).

`setup-env.js` uses `os.homedir()` to detect the correct home directory on any OS and writes it to `.env` as `HOME=<path>`. Docker Compose reads `.env` and substitutes `${HOME}` in volume paths correctly regardless of platform.

The compose file itself stays unchanged — it keeps using `${HOME}`.

### 6. Entrypoint Changes (`trust-proxy-ca.sh`)

Extend the Claude binary setup block to handle npm layout:

```sh
# Existing: shell installer layout
if [ -d "$CLAUDE_DIR/versions" ]; then
    LATEST=$(ls -t "$CLAUDE_DIR/versions" 2>/dev/null | head -1)
    # ... existing symlink logic ...

# New: npm global install layout
elif [ "${CLAUDE_INSTALL_TYPE:-}" = "npm" ] && [ -d "/home/developer/.local/share/claude-npm" ]; then
    NPM_DIR="/home/developer/.local/share/claude-npm"
    cat > "$CLAUDE_BIN" <<'WRAPPER'
#!/bin/sh
exec node "/home/developer/.local/share/claude-npm/cli.mjs" "$@"
WRAPPER
    chmod +x "$CLAUDE_BIN"
    chown "$TARGET_USER:$TARGET_USER" "$CLAUDE_BIN"
fi
```

### 7. Unchanged Components

- Docker images (proxy, base, base-podman, netjail) — no image rebuilds needed
- `claude-sandbox.sh` — untouched
- `claude-sandbox-bwrap.sh` — untouched, Linux-only
- Makefile — unchanged (may add `test-windows` later)

## File Summary

**New files:**
- `claude-sandbox.ps1` — PowerShell equivalent of `claude-sandbox.sh`
- `template/setup-env.js` — Cross-platform env setup for VS Code Dev Containers

**Modified files:**
- `images/base/trust-proxy-ca.sh` — Add npm install layout handling
- `template/devcontainer.json` — Update `initializeCommand` to use `setup-env.js`
- `template/README.md` — Windows setup instructions
- `README.md` — Add Windows section
- `CLAUDE.md` — Reference new files
