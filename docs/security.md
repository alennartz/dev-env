# Security Model

Understanding what this sandbox protects against and its limitations.

## Threat Model

This sandbox is designed for running Claude Code with `--dangerously-skip-permissions` in a way that limits potential damage from:

- **Unintended network access** - Claude can't exfiltrate data to arbitrary servers
- **Supply chain attacks** - Malicious packages can't phone home to non-whitelisted domains
- **Accidental mistakes** - Typos or misconfigurations won't leak data

## What's Protected

### Network Isolation

✅ **All HTTP/HTTPS traffic is filtered**

- Only whitelisted domains are accessible
- Enforced at kernel level via iptables
- Cannot be bypassed from sandbox container

✅ **All other outbound ports are blocked**

- SSH, FTP, custom protocols - all blocked by default
- Only DNS (port 53) and HTTP/HTTPS (80/443) to proxy are allowed

✅ **No direct internet access**

- Sandbox shares proxy's network namespace
- All traffic must go through squid
- No way to bypass from userspace

### Capability Separation

✅ **Sandbox has no special privileges**

- Cannot modify iptables rules
- Cannot access host network
- Cannot escalate privileges (no sudo in base image)

✅ **NET_ADMIN isolated to proxy**

- Only proxy container can modify network rules
- Compromised sandbox cannot disable filtering

## What's NOT Protected

### Local File Access

❌ **Sandbox has full access to mounted workspace**

- Claude can read, write, delete any file in your project
- This is intentional - you want Claude to edit code
- Don't mount sensitive directories

### DNS Exfiltration

❌ **DNS queries are allowed to any domain**

- Required for domain resolution before filtering
- Theoretically possible to encode data in DNS queries
- Low bandwidth, but possible

### Certificate Pinning Bypass

❌ **Some tools may fail with certificate errors**

- Tools that pin specific certificates won't trust proxy's CA
- Rare in development tools, common in banking/security apps

### Side Channels

❌ **Timing attacks, cache analysis, etc.**

- If an attacker is sophisticated enough to use side channels, this sandbox won't stop them
- This is a development convenience tool, not a high-security isolation boundary

### Container Escapes

❌ **Kernel vulnerabilities could allow escape**

- Docker containers share the host kernel
- A kernel exploit could escape the container
- For maximum isolation, use a VM

## Security Boundaries

```text
┌─────────────────────────────────────────────┐
│ Host Machine                                 │
│  ┌────────────────────────────────────────┐ │
│  │ Docker                                  │ │
│  │  ┌──────────────────────────────────┐  │ │
│  │  │ Shared Network Namespace          │  │ │
│  │  │  ┌─────────┐  ┌─────────────────┐│  │ │
│  │  │  │ Proxy   │  │ Sandbox         ││  │ │
│  │  │  │ ✓ NET_  │  │ ✗ No caps       ││  │ │
│  │  │  │   ADMIN │  │ ✗ Can't change  ││  │ │
│  │  │  │         │  │   network rules ││  │ │
│  │  │  └─────────┘  └─────────────────┘│  │ │
│  │  └──────────────────────────────────┘  │ │
│  │            ↓                            │ │
│  │     [iptables + squid]                  │ │
│  │            ↓                            │ │
│  │     [whitelist filter]                  │ │
│  │            ↓                            │ │
│  └────────────────────────────────────────┘ │
│                    ↓                         │
│             [ Internet ]                     │
└─────────────────────────────────────────────┘
```

## Why This Approach?

### vs. Running Claude directly

| Risk | Direct | Sandboxed |
|------|--------|-----------|
| Data exfiltration | Any server | Whitelisted only |
| Malicious packages | Unrestricted | Filtered |
| Network scanning | Possible | Blocked |

### vs. VM-based isolation

| Aspect | Container | VM |
|--------|-----------|-----|
| Startup time | Seconds | Minutes |
| Resource usage | Low | High |
| Integration | Seamless | Awkward |
| Isolation | Good | Better |

### vs. HTTP_PROXY only

| Aspect | Env vars | iptables |
|--------|----------|----------|
| Enforced | No | Yes |
| Bypassable | Yes | No (from sandbox) |
| Transparent | No | Yes |

## Recommendations

### For Personal Use

The default configuration is appropriate. Add domains to whitelist as needed.

### For Team/Enterprise Use

1. **Audit the whitelist** - Remove domains you don't need
2. **Pin image versions** - Don't use `:latest` in production
3. **Consider egress logging** - Monitor proxy access logs
4. **Regular updates** - Keep base images updated for security patches

### For High-Security Environments

Consider additional measures:

1. **VM isolation** - Run Docker inside a VM
2. **Network segmentation** - Isolate the Docker host
3. **Read-only workspace** - If you don't need writes
4. **Audit logging** - Log all proxy requests to SIEM
