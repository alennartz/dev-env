# ADR-007: macOS Sandbox Using FUSE-T Overlay + Seatbelt + pf + Docker Netjail

## Status

Accepted

## Context

The bubblewrap sandbox (`claude-sandbox-bwrap.sh`) provides the ideal developer experience on Linux: Claude runs natively with full access to host tools, ephemeral writes via overlay filesystem, and transparent network isolation via domain whitelist. However, it relies on Linux-specific kernel features (namespaces, `fuse-overlayfs`, `iptables`) that don't exist on macOS.

macOS developers need an equivalent sandbox that preserves the same properties:
- Host tools available (not a container)
- Transparent network interception (no proxy env vars)
- Domain whitelist enforcement
- Automatic sandboxing of child processes (including MCP servers)

### Alternatives Considered

1. **Docker container (like `claude-sandbox.sh`)**: Works but loses access to host tools, Homebrew packages, and native development environment. This is the existing fallback.

2. **Proxy env vars only**: Tools that don't honor `HTTP_PROXY`/`HTTPS_PROXY` silently bypass the whitelist. Not transparent.

3. **Network extension / VPN tunnel**: Requires code signing, notarization, and user approval of a system extension. Too much friction for a development tool.

4. **Little Snitch / LuLu rules**: Per-application, not inherited by child processes. MCP servers would need individual rules.

## Decision

We adopt a three-layer approach for macOS:

### Network + Process Confinement: Seatbelt + pf + Docker Netjail

1. **pf (packet filter)** for transparent network interception — redirects HTTP/HTTPS to localhost Squid, blocks other outbound
2. **Docker netjail container** (same image as Linux) for Squid proxy with SSL bump and domain whitelist, port-mapped to localhost
3. **Seatbelt (`sandbox-exec`)** for process confinement — restricts file access to overlay mount and allowed paths
4. **Environment variables** (`NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`) for proxy CA trust

### Ephemeral Filesystem: FUSE-T Overlay

A Go FUSE overlay filesystem (`cmd/overlay-fuse/`) provides true ephemeral writes:
- **Lower layer**: host `/` (read-only passthrough)
- **Upper layer**: tmpdir (ephemeral, discarded on exit)
- **Bind-through paths**: workspace and `~/.claude` write directly to host
- **Whiteout tracking**: standard overlayfs `.wh.*` convention for deletions
- **Copy-up**: first write to a lower-layer file copies it to upper, then modifies
- Uses hanwen/go-fuse library targeting FUSE-T's libfuse-compatible API on macOS

The overlay can be disabled with `NO_OVERLAY=1` for a Seatbelt-only mode.

### Why pf for Network Isolation

pf (packet filter) is macOS's built-in firewall, equivalent to Linux iptables. It provides:
- **Transparent interception**: `rdr pass` rules redirect traffic without any application awareness
- **Session scoping**: Rules use a named anchor, added on start and removed on exit
- **No redirect loops**: Docker Desktop runs Squid in a Linux VM; its outbound traffic doesn't traverse host pf
- **Child process coverage**: pf operates at the network layer, so all processes (including MCP servers) are covered

### Why Seatbelt for File Confinement

macOS's `sandbox-exec` (Seatbelt) provides:
- **Deny-default policy**: Only explicitly allowed paths are accessible
- **Inherited by children**: Child processes (MCP servers) inherit the sandbox profile
- **No kernel extension needed**: Built into macOS since Leopard

Note: `sandbox-exec` is marked as deprecated by Apple but remains functional and is used internally by macOS system services. There is no replacement API that provides equivalent functionality without requiring a signed/notarized application.

### Why Docker Netjail Instead of Native Squid

- Reuses the existing `images/netjail/` image with no modifications
- Squid SSL bump configuration is complex; keeping it in Docker avoids Homebrew Squid version drift
- Docker Desktop is a common prerequisite for macOS developers
- The netjail container persists between sandbox sessions for fast startup

## Architecture

```
macOS Host
 |
 |-- sudo pfctl -a claude-sandbox -ef <rules>    # Transparent network interception
 |     |-- rdr HTTP/HTTPS -> localhost:3128/3129
 |     |-- Allow DNS (port 53) and localhost
 |     |-- Block all other outbound
 |
 |-- Docker netjail container                     # Same image as Linux
 |     |-- Squid with SSL bump + domain whitelist
 |     |-- -p 127.0.0.1:3128:3128 -p 127.0.0.1:3129:3129
 |
 |-- overlay-fuse (Go binary via FUSE-T)          # Ephemeral filesystem
 |     |-- Lower: host / (read-only passthrough)
 |     |-- Upper: /tmp/claude-sandbox-XXXX/upper (ephemeral)
 |     |-- Bind-through: workspace, ~/.claude (persistent)
 |     |-- Mount: /tmp/claude-sandbox-XXXX/merged
 |     |-- Proxy CA cert injected into overlay /etc/ssl/certs/
 |
 |-- sandbox-exec -f '<seatbelt-profile>'         # Process confinement
       |-- Allow read/write: overlay mount
       |-- Allow read: /usr, /System, /Library, Homebrew
       |-- Allow network: localhost only (backup to pf)
       |-- claude --dangerously-skip-permissions "$@"
             |-- MCP servers inherit all constraints
```

## Consequences

### Positive

- Native macOS experience: host tools, Homebrew packages, shell config all available
- Ephemeral writes: changes outside workspace/config are discarded on exit
- Transparent network isolation: no proxy env vars needed
- Child processes (MCP servers) automatically sandboxed
- Reuses existing Docker netjail image
- Same whitelist format as Linux bwrap mode
- pf rules scoped to named anchor, clean removal on exit
- Graceful fallback: `NO_OVERLAY=1` disables overlay for Seatbelt-only mode

### Negative

- Requires `sudo` for `pfctl` (same as Linux requiring sudo for overlayfs/nsenter)
- Requires Docker Desktop (common for developers, but an additional dependency)
- Requires FUSE-T (`brew install fuse-t`) for ephemeral filesystem
- `sandbox-exec` is deprecated (no replacement exists; still functional)
- pf rules are system-wide during sandbox session (scoped to anchor, but affect all processes matching the rules)
- FUSE overhead on I/O-intensive operations (mitigated by bind-through for workspace)

### Security Model

| Layer | What it prevents |
|-------|-----------------|
| FUSE-T overlay | Persistent writes to host filesystem (writes go to tmpdir) |
| pf rules | Unwhitelisted network access from any process |
| Squid whitelist | Access to domains not in whitelist |
| Squid SSL bump | HTTPS traffic inspection for domain filtering |
| Seatbelt profile | File access outside overlay mount + allowed paths |
| Seatbelt network | Direct network access bypassing pf (defense in depth) |

### Comparison with Linux Bwrap

| Property | Linux (bwrap) | macOS |
|----------|--------------|-------|
| Filesystem isolation | fuse-overlayfs + mount namespace | FUSE-T overlay + Seatbelt |
| Ephemeral writes | Yes (tmpfs upper) | Yes (tmpdir upper) |
| Network interception | iptables in network namespace | pf rules (system-wide anchor) |
| Proxy | Squid in Docker netjail | Same image, port-mapped |
| Host tools available | Yes | Yes |
| Child process sandbox | Namespace inheritance | Seatbelt + pf inheritance |
| Sudo required | Yes | Yes |
| Extra dependencies | bubblewrap, fuse-overlayfs | FUSE-T (Homebrew) |

## References

- [Apple Sandbox Guide (reverse-engineered)](https://reverse.put.as/wp-content/uploads/2011/09/Apple-Sandbox-Guide-v1.0.pdf)
- [pf.conf(5) man page](https://man.openbsd.org/pf.conf)
- [FUSE-T](https://www.fuse-t.org/)
- [hanwen/go-fuse](https://github.com/hanwen/go-fuse) — Go FUSE bindings
- Related ADRs: [001](./001-reject-host-docker-socket.md), [006](./006-adopt-podman-rootless.md)
