# How It Works

This sandbox uses a two-container architecture to provide network isolation without requiring any host-side configuration.

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
│  │  │  - iptables   │    │  - your code  │        │   │
│  │  └───────────────┘    └───────────────┘        │   │
│  │         │                     │                 │   │
│  │         └─────────┬───────────┘                 │   │
│  │                   │                             │   │
│  │     iptables redirects port 80/443 to squid    │   │
│  └─────────────────────┼───────────────────────────┘   │
│                        │                               │
│                   [ Internet ]                         │
│              (whitelisted domains only)                │
└─────────────────────────────────────────────────────────┘
```

## The Two Containers

### Proxy Container

- **Has NET_ADMIN capability** - can modify network rules
- Runs Squid proxy with SSL bump
- Sets up iptables rules on startup
- Generates CA certificate for HTTPS interception
- Enforces domain whitelist

### Sandbox Container

- **Has NO special capabilities** - cannot modify network
- Shares proxy's network namespace via `network_mode: "service:proxy"`
- Trusts proxy's CA certificate
- Runs Claude Code and your development tools
- VS Code attaches to this container

## Network Flow

1. **Application makes request** (e.g., `curl https://api.anthropic.com`)
2. **iptables intercepts** - redirects port 443 to Squid (port 3129)
3. **Squid checks whitelist** - is `api.anthropic.com` allowed?
4. **If allowed**: Squid connects to real server, generates matching certificate
5. **If denied**: Connection terminated

## SSL Bump (HTTPS Interception)

For HTTPS filtering to work, the proxy must see the destination domain. This requires:

1. **Proxy generates CA certificate** on first run
2. **Sandbox imports CA** into system trust store
3. **When you connect to HTTPS sites**:
   - Squid intercepts the TLS handshake
   - Reads the SNI (Server Name Indication) to see the domain
   - If whitelisted, generates a certificate for that domain signed by its CA
   - Your application sees a valid certificate (trusts the CA)

This is the same technique used by corporate proxies and security tools.

## Why Two Containers?

The key insight: **iptables rules can only be modified with NET_ADMIN capability**.

| Approach | Problem |
|----------|---------|
| Single container with NET_ADMIN | Compromised Claude can flush iptables rules |
| Host-side iptables | Requires host configuration, not portable |
| HTTP_PROXY env vars | Tools can ignore them, not enforced |
| Two containers, shared namespace | Proxy has NET_ADMIN, sandbox doesn't - can't bypass |

## Why Not Just Use HTTP_PROXY?

Many tools respect `HTTP_PROXY` / `HTTPS_PROXY` environment variables, but:

- Some tools ignore them (statically compiled binaries, some native modules)
- A compromised process can unset the variables
- Not all protocols go through HTTP proxy

With iptables interception:

- **Enforced at kernel level** - can't be bypassed from userspace
- **Transparent** - applications don't need to know about proxy
- **All TCP traffic** on port 80/443 is captured

## Volume Sharing

The CA certificate is shared between containers via a Docker volume:

```yaml
volumes:
  squid-ssl:  # Shared volume for CA cert
```

- Proxy writes CA cert to volume
- Sandbox reads CA cert from volume (read-only)
- Certificate persists across container restarts

## Credential Handling

Host Claude installation and configuration are mounted directly into the container:

```yaml
volumes:
  # Claude binary (read-only, entrypoint creates symlink)
  - ${HOME}/.local/share/claude:/home/developer/.local/share/claude:ro
  # Claude config (read-write for session data)
  - ${HOME}/.claude:/home/developer/.claude:cached
  - ${HOME}/.claude.json:/home/developer/.claude.json:cached
  # Git config for commits
  - ${HOME}/.gitconfig:/home/developer/.gitconfig:ro
  - ${HOME}/.git-credentials:/home/developer/.git-credentials:ro
```

The entrypoint script (`trust-proxy-ca.sh`) creates a symlink from `~/.local/bin/claude` to the latest version in the mounted directory.

The base image creates the `developer` user with UID 1000 (matching the common host UID), so mounted files are readable without ownership changes.

## User Configuration

For VS Code Dev Containers, set `remoteUser` in `devcontainer.json`:

```json
{
  "remoteUser": "developer"
}
```

This ensures VS Code sessions run as `developer`, not root. Without this, you'd need to manually specify `-u developer` for `docker exec` commands.
