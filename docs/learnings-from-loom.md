# Security Learnings from Loom Weavers

Analysis of security approaches used in the [Loom](https://github.com/ghuntley/loom) weaver system that could improve this project.

## Background

Loom weavers are ephemeral Kubernetes pods for running remote REPL sessions. While the deployment model differs (K8s vs Docker Compose), several security patterns are worth adopting.

| Aspect | Loom Weavers | This Project |
|--------|--------------|--------------|
| **Runtime** | Kubernetes (K3s) | Docker Compose |
| **Network model** | Direct internet (no filtering) | Transparent proxy with whitelist |
| **Audit** | eBPF syscall tracing | Proxy access logs only |
| **Escape detection** | Active monitoring | Seccomp blocks (no visibility) |

---

## 1. eBPF Audit Sidecar

### What Loom Does

Loom runs an eBPF-based audit sidecar alongside each weaver that captures syscall-level events:

| Event Type | What's Captured |
|------------|-----------------|
| `WeaverProcessExec` | Every command executed with full argv, cwd, uid/gid |
| `WeaverFileWrite` | All file modifications (open with O_WRONLY, write, rename, unlink) |
| `WeaverFileRead` | Reads of sensitive paths |
| `WeaverNetworkConnect` | Outbound connections with resolved hostnames |
| `WeaverDnsQuery` | DNS queries (for hostname correlation) |
| `WeaverPrivilegeChange` | setuid/setgid/capset/ptrace calls |
| `WeaverSandboxEscape` | Attempts to call unshare, setns, mount, bpf |

### Gap in This Project

Currently we only have proxy access logs, which show:
- HTTP/HTTPS requests that reached the proxy
- Nothing about local file operations
- Nothing about commands executed
- No visibility into blocked syscalls

### Proposed Architecture

```
┌─────────────────────────────────────────────────────┐
│  Docker Compose                                     │
│  ┌─────────┐  ┌─────────────┐  ┌─────────────────┐ │
│  │ proxy   │  │ sandbox     │  │ audit-sidecar   │ │
│  │NET_ADMIN│  │ no caps     │  │ CAP_BPF         │ │
│  │ squid   │  │ claude code │  │ CAP_PERFMON     │ │
│  └─────────┘  └─────────────┘  └─────────────────┘ │
│     shared network namespace    shared PID namespace│
└─────────────────────────────────────────────────────┘
```

Docker Compose equivalent:
```yaml
services:
  audit-sidecar:
    pid: "service:sandbox"  # Share PID namespace
    cap_add:
      - BPF
      - PERFMON
    cap_drop:
      - ALL
    read_only: true
    volumes:
      - /sys/kernel/tracing:/sys/kernel/tracing:ro
      - /sys/fs/bpf:/sys/fs/bpf:rw
```

### Implementation Considerations

- Requires CAP_BPF and CAP_PERFMON (adds attack surface)
- Need custom seccomp to allow `bpf()` syscall for sidecar only
- Events should be buffered locally and batched to reduce overhead
- Consider [Aya](https://aya-rs.dev/) (Rust) or [libbpf](https://github.com/libbpf/libbpf) (C)

---

## 2. Sandbox Escape Detection

### What Loom Monitors

Loom flags these syscalls as `WeaverSandboxEscape` critical events:

| Syscall | Why It's Dangerous |
|---------|-------------------|
| `unshare` | Create new namespaces (escape container isolation) |
| `setns` | Join existing namespaces (escape to host) |
| `mount`, `umount2` | Mount operations (access host filesystems) |
| `init_module`, `finit_module` | Load kernel modules |
| `bpf` | Load eBPF programs (from non-sidecar processes) |
| `perf_event_open` | Performance monitoring (information disclosure) |

### Current State

Our seccomp profile blocks many of these, but we have **no visibility** when attempts are made. Even a blocked syscall returning `EPERM` is a valuable signal that something suspicious happened.

### Quick Win

Even without full eBPF audit, we could add a simple tracepoint monitor for these specific syscalls:

```bash
# Log sandbox escape attempts via ftrace
echo 1 > /sys/kernel/debug/tracing/events/syscalls/sys_enter_unshare/enable
echo 1 > /sys/kernel/debug/tracing/events/syscalls/sys_enter_setns/enable
echo 1 > /sys/kernel/debug/tracing/events/syscalls/sys_enter_mount/enable
```

---

## 3. DNS Query Logging and Correlation

### What Loom Does

Loom captures DNS queries and correlates them with subsequent connections:

```
Event 1: DNS query for "api.github.com" → 140.82.112.6
Event 2: Connect to 140.82.112.6:443 → enriched as "api.github.com"
```

This enables:
- Detection of DNS exfiltration (data encoded in query names)
- Human-readable connection logs (hostnames instead of IPs)
- Correlation of suspicious DNS patterns

### Gap in This Project

We allow DNS queries (required for resolution) but don't log them. This is a blind spot:
- Can't detect DNS tunneling/exfiltration
- Proxy logs show hostnames, but we can't correlate with non-HTTP traffic

### Implementation Options

1. **CoreDNS with query logging** - Run CoreDNS in the proxy container, log all queries
2. **eBPF DNS capture** - Part of the audit sidecar, capture UDP port 53 traffic
3. **Squid DNS logging** - Squid already resolves domains; configure detailed logging

---

## 4. Secret Redaction in Audit Logs

### What Loom Does

Environment variables and file paths in audit events are automatically redacted:

```json
{
  "event_type": "WeaverProcessExec",
  "details": {
    "path": "/usr/bin/git",
    "argv": ["git", "clone", "https://github.com/org/repo"],
    "envp": ["HOME=/home/loom", "PATH=...", "[REDACTED:github-pat]"]
  }
}
```

Redaction patterns include:
- Known environment variables: `GITHUB_TOKEN`, `ANTHROPIC_API_KEY`, `AWS_SECRET_ACCESS_KEY`
- Sensitive file paths: `/etc/shadow`, credentials files
- Pattern matching: anything matching `*_TOKEN`, `*_SECRET`, `*_KEY`, `*_PASSWORD`

### Relevance for This Project

If we add audit logging, we need this. Currently:
- Proxy logs might contain OAuth tokens in URLs
- Any future command logging would expose environment variables

### Implementation

```python
REDACT_PATTERNS = [
    r'(?i)(api[_-]?key|token|secret|password|credential)',
    r'(?i)(GITHUB|ANTHROPIC|OPENAI|AWS)_[A-Z_]+',
]

def redact_env(env_list):
    return [redact(e) if matches_pattern(e) else e for e in env_list]
```

---

## 5. SPIFFE-Style Workload Identity

### What Loom Does

Each weaver gets a cryptographic identity (SVID - SPIFFE Verifiable Identity Document):

```
Identity: spiffe://loom.dev/weaver/{weaver-id}

Claims:
  - org_id: "acme-corp"
  - owner_user_id: "user-123"
  - repo: "github.com/acme/project"
  - weaver_id: "weaver-456"
  - pod_uid: "k8s-pod-789"
```

Benefits:
- Zero-trust secret access (identity-based, not network-based)
- Audit trail tied to specific workload identity
- Short-lived credentials (15-minute TTL)

### Relevance for This Project

Less critical for single-user local use, but valuable if:
- Running multiple sandboxes simultaneously
- Implementing secret management (vault-style)
- Need to audit which sandbox performed which action

### Future Consideration

If we add multi-sandbox support, consider lightweight identity:
```yaml
# Per-sandbox identity
sandbox:
  environment:
    SANDBOX_ID: "${SANDBOX_UUID}"
    SANDBOX_PROJECT: "${PROJECT_NAME}"
```

---

## What This Project Does Better

### Domain Whitelisting

Loom weavers have **unrestricted network access**. Our proxy-based filtering is a significant security advantage:

| Threat | Loom | This Project |
|--------|------|--------------|
| Data exfiltration | Possible to any server | Blocked (whitelist only) |
| C2 communication | Possible | Blocked |
| Supply chain callback | Possible | Blocked |

### Minimal Attack Surface

Our base image is smaller with fewer privileged components:

| Component | Loom | This Project |
|-----------|------|--------------|
| Audit sidecar | CAP_BPF + CAP_PERFMON | None (yet) |
| Host mounts | /sys/kernel/tracing, /sys/fs/bpf | None |
| Seccomp | Default | Custom hardened |

Adding eBPF audit would increase attack surface. The trade-off is visibility vs. exposure.

---

## Prioritized Recommendations

| Priority | Feature | Effort | Value | Risk |
|----------|---------|--------|-------|------|
| **High** | Sandbox escape detection (ftrace) | Low | Alert on escape attempts | Minimal |
| **High** | DNS query logging | Low | Detect exfiltration | Minimal |
| **Medium** | eBPF audit sidecar | High | Full syscall visibility | Adds CAP_BPF |
| **Medium** | Secret redaction | Low | Safe audit logs | None |
| **Low** | Workload identity | High | Multi-sandbox support | Complexity |

### Recommended First Steps

1. **Add ftrace-based escape detection** - Minimal effort, high signal
2. **Enable DNS query logging in Squid** - Already have the proxy
3. **Design audit event schema** - Before implementing eBPF, define what we want to capture

---

## References

- [Loom Weaver eBPF Audit Spec](https://github.com/ghuntley/loom/blob/trunk/specs/weaver-ebpf-audit.md)
- [Loom Weaver Secrets System](https://github.com/ghuntley/loom/blob/trunk/specs/weaver-secrets-system.md)
- [Aya - Rust eBPF library](https://aya-rs.dev/)
- [SPIFFE - Secure Production Identity Framework](https://spiffe.io/)
