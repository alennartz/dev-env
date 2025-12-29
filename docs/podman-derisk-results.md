# Podman-in-Sandbox De-risk Experiment Results

**Date:** 2025-12-29
**Status:** All phases PASSED - Podman is viable with documented trade-offs

## Executive Summary

We successfully validated that rootless Podman can run inside the Claude sandbox container, enabling Docker-in-Docker functionality while preserving network isolation through the proxy. All five phases of the de-risk plan passed, but the solution requires elevated capabilities that weaken the container's security boundary.

**Key Finding:** Podman works, but requires `CAP_SYS_ADMIN`, which significantly reduces isolation from the host. This is a meaningful security trade-off that should be opt-in for users who need container functionality.

**Update (2025-12-29):** We successfully replaced `seccomp:unconfined` with a custom minimal seccomp profile that blocks dangerous syscalls (kernel modules, BPF, kexec) while allowing Podman operations. See [seccomp-experiment-results.md](./seccomp-experiment-results.md) and [podman-uid-mapping-research.md](./podman-uid-mapping-research.md) for details.

**Update (2025-12-29):** Additional hardening applied:
- Drop ALL default capabilities, explicitly add only required ones (removes `CAP_NET_RAW`, `CAP_AUDIT_WRITE`, etc.)
- Restrict `ptrace` to `PTRACE_TRACEME` only (blocks `PTRACE_ATTACH`)
- Block additional dangerous syscalls: `process_vm_readv`, `userfaultfd`, `kcmp`, `perf_event_open`

---

## Test Results Summary

| Phase | Result | Configuration Required |
|-------|--------|----------------------|
| 1. User Namespace Nesting | PASS | `CAP_SYS_ADMIN`, custom seccomp profile* |
| 2. Rootless Podman Execution | PASS | `crun` runtime, `--cgroups=disabled`, `--network=host` |
| 3. Storage Driver | PASS | Native `overlay` (no changes needed) |
| 4. Network Isolation | PASS | Child containers inherit sandbox network, proxy enforced |
| 5. Compose Compatibility | PASS | Wrapper script to inject `--cgroups=disabled` |

*Originally tested with `seccomp:unconfined`, later improved to use custom profile (`images/base/seccomp-podman.json`)

---

## Phase Details

### Phase 1: User Namespace Nesting

**Test:** Create nested user namespaces inside the sandbox container.

```bash
unshare --user --map-root-user echo "user ns works"
```

**Initial Result:** Failed with "Operation not permitted"

**Root Cause:** Docker's default seccomp profile blocks the `unshare` syscall for unprivileged processes. The kernel supports user namespaces (`max_user_namespaces=63745`), but seccomp filtering prevents their creation.

**Solution:** Add capabilities and disable seccomp:
```yaml
cap_add:
  - SYS_ADMIN
  - MKNOD
security_opt:
  - seccomp:unconfined
  - label:disable
devices:
  - /dev/fuse:/dev/fuse
```

---

### Phase 2: Rootless Podman Execution

**Test:** Run containers as the unprivileged `developer` user.

```bash
podman run --rm docker.io/library/alpine echo "hello"
```

**Issues Encountered:**

1. **Netavark network failure:** Podman's default network stack requires `CAP_NET_ADMIN` for iptables/netlink operations.
   - **Workaround:** Use `--network=host` to inherit sandbox's network stack

2. **Cgroup filesystem read-only:** Cannot create cgroup hierarchies for child containers.
   - **Workaround:** Use `--cgroups=disabled` with `crun` runtime (runc doesn't support this)

**Working Command:**
```bash
podman --runtime=/usr/bin/crun run --rm --network=host --cgroups=disabled alpine echo "hello"
```

---

### Phase 3: Storage Driver Compatibility

**Test:** Verify Podman's storage driver works for image layers.

**Result:** Native `overlay` driver works out of the box. No fuse-overlayfs or vfs fallback needed.

```
graphDriverName: overlay
```

---

### Phase 4: Network Isolation

**Critical Test:** Verify child containers respect the proxy whitelist.

**Whitelisted domain (api.anthropic.com):**
```bash
podman run --rm --network=host alpine wget --no-check-certificate -O- https://api.anthropic.com
# Result: HTTP 404 (reached server, endpoint doesn't exist)
```

**Blocked domain (example.com):**
```bash
podman run --rm --network=host alpine wget -O- http://example.com
# Result: HTTP 403 Forbidden (blocked by proxy)
```

**Volume Mount Test:**
```bash
echo "sandbox-content" > /tmp/test.txt
podman run --rm -v /tmp/test.txt:/test.txt alpine cat /test.txt
# Result: "sandbox-content" (mounts from sandbox, not host)
```

**Conclusion:** Network isolation is preserved. Child containers:
- Cannot bypass the proxy (all traffic goes through squid)
- Can only access whitelisted domains
- Mount volumes from sandbox filesystem, not host

---

### Phase 5: Compose Compatibility

**Test:** Run multi-container applications with podman-compose.

**Issue:** `podman-compose` doesn't respect `containers.conf` settings, so `--cgroups=disabled` isn't applied automatically.

**Solution:** Wrapper script that injects the flag:

```bash
#!/bin/bash
# /usr/bin/podman (wrapper)
if [[ "$1" == "run" || "$1" == "create" ]]; then
    cmd="$1"; shift
    exec /usr/bin/podman.real "$cmd" --cgroups=disabled "$@"
else
    exec /usr/bin/podman.real "$@"
fi
```

**Test Compose File:**
```yaml
version: "3"
services:
  web:
    image: docker.io/library/alpine
    command: echo "web service"
    network_mode: host
  db:
    image: docker.io/library/alpine
    command: echo "db service"
    network_mode: host
```

**Result:** Both services started and completed successfully.

---

## Security Trade-off Analysis

### What We're Adding

| Capability/Option | Purpose | Risk Level |
|-------------------|---------|------------|
| `CAP_SYS_ADMIN` | User namespace creation, mount operations | **HIGH** |
| Custom seccomp profile | Allow namespace syscalls, block dangerous ones | Medium |
| `CAP_MKNOD` | Device node creation for fuse | Medium |
| `CAP_CHOWN`, `CAP_FOWNER` | File ownership operations for gosu | Low |
| `CAP_SETUID`, `CAP_SETGID` | Privilege drop via gosu, newuidmap | Low |
| `CAP_DAC_OVERRIDE` | File access for gosu operations | Low |
| `CAP_SETFCAP` | Capability management | Low |
| `CAP_KILL` | Process signal handling | Low |
| `/dev/fuse` device | Fuse filesystem support | Low |

### What We're Dropping (from Docker defaults)

| Capability | Why Dropped |
|------------|-------------|
| `CAP_NET_RAW` | No raw socket access needed |
| `CAP_NET_BIND_SERVICE` | No privileged port binding needed |
| `CAP_AUDIT_WRITE` | No audit log manipulation |
| `CAP_SYS_CHROOT` | No chroot operations needed |
| `CAP_SETPCAP` | Reduced capability manipulation |

### CAP_SYS_ADMIN Risks

`CAP_SYS_ADMIN` is often called "the new root" because it grants a wide range of administrative operations:

1. **Mount Operations:** Can mount filesystems, potentially including host paths if accessible
2. **Cgroup Manipulation:** Can modify cgroup settings (mitigated by our `--cgroups=disabled`)
3. **Namespace Operations:** Can create and enter namespaces
4. **BPF Programs:** Can load eBPF programs into the kernel
5. **Kernel Module Loading:** Combined with other conditions, could load kernel modules

**Known Escape Vectors with CAP_SYS_ADMIN:**

- **Cgroup Release Agent (CVE-2022-0492):** If cgroup v1 is mounted read-write, an attacker can write to `release_agent` to execute commands on the host. *Mitigated: We use `--cgroups=disabled`.*

- **User Namespace + Mount Escape:** Create user namespace, mount host filesystem. *Partially mitigated: No obvious host paths exposed, but risk exists.*

References:
- [Trail of Bits: Understanding Docker Container Escapes](https://blog.trailofbits.com/2019/07/19/understanding-docker-container-escapes/)
- [OWASP Docker Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Docker_Security_Cheat_Sheet.html)
- [Excessive Capabilities Cheat Sheet](https://0xn3va.gitbook.io/cheat-sheets/container/escaping/excessive-capabilities)

### Custom Seccomp Profile (Replaces seccomp:unconfined)

We use a custom seccomp profile (`images/base/seccomp-podman.json`) instead of disabling seccomp entirely:

**Allowed (required for Podman):**
- `unshare`, `clone`, `clone3`, `setns` - Namespace operations
- `mount`, `umount`, `pivot_root` - Filesystem operations
- `add_key`, `keyctl`, `request_key` - Keyring for crun

**Blocked (attack surface reduction):**
- `init_module`, `finit_module`, `delete_module` - Kernel modules
- `bpf` - eBPF programs
- `kexec_load`, `kexec_file_load` - Kernel replacement
- `process_vm_readv`, `process_vm_writev` - Cross-process memory
- `userfaultfd` - Used in exploits
- `kcmp` - Kernel resource comparison (info leak)
- `perf_event_open` - Performance monitoring (info leak)
- `ptrace` with `PTRACE_ATTACH` - Only `PTRACE_TRACEME` allowed

**Historical CVEs mitigated:**
- CVE-2022-0185: Would require `unshare` + kernel exploit (kernel modules blocked)
- Various BPF exploits: `bpf` syscall blocked

References:
- [Docker Seccomp Documentation](https://docs.docker.com/engine/security/seccomp/)
- [Datadog: Container Security Fundamentals - Seccomp](https://securitylabs.datadoghq.com/articles/container-security-fundamentals-part-6/)

### What We Retain

Despite the elevated capabilities, several security boundaries remain:

1. **Network Isolation:** All traffic forced through proxy via iptables (in proxy container)
2. **Domain Whitelist:** Only explicitly allowed domains accessible
3. **No Host Filesystem:** Volume mounts are from sandbox, not host
4. **No Docker Socket:** Cannot communicate with host Docker daemon
5. **Non-root User:** Still running as `developer` user (not root)
6. **Read-only Mounts:** Claude binary and git config mounted read-only

### Risk Assessment

| Threat | Without Podman | With Podman | Notes |
|--------|---------------|-------------|-------|
| Network exfiltration | Blocked | Blocked | Proxy still enforced |
| Host filesystem access | Blocked | Blocked | No host mounts exposed |
| Container escape to host | Very Difficult | Difficult | CAP_SYS_ADMIN required, but seccomp blocks many vectors |
| Kernel exploitation | Blocked | Limited | Custom seccomp blocks modules, BPF, kexec |
| Privilege escalation in sandbox | Limited | Moderate | Fewer caps than default Docker |
| Raw socket attacks | Blocked | Blocked | CAP_NET_RAW explicitly dropped |
| Cross-process memory access | Blocked | Blocked | process_vm_* syscalls blocked |

### Comparison: Podman Config vs --privileged

Our configuration is NOT equivalent to `--privileged`:

| Feature | Our Config | --privileged |
|---------|-----------|--------------|
| All capabilities | No (9 specific caps) | Yes (all 41) |
| Default caps dropped | Yes (`cap_drop: ALL`) | No |
| All devices | No (only /dev/fuse) | Yes |
| Seccomp | Custom restrictive profile | Disabled |
| AppArmor | Disabled | Disabled |
| Read-only paths | Preserved | Removed |
| Masked paths | Preserved | Removed |
| Host network | No | Optional |
| Host PID | No | Optional |
| CAP_NET_RAW | **Dropped** | Granted |
| Kernel modules | **Blocked by seccomp** | Allowed |
| BPF | **Blocked by seccomp** | Allowed |
| ptrace ATTACH | **Blocked by seccomp** | Allowed |

---

## Recommendations

### Option A: Separate Image for DinD Users (Recommended)

Create an opt-in "podman-enabled" variant:

```
images/
├── base/           # Current secure image (no DinD)
└── base-podman/    # Extended image with Podman + elevated caps
```

Users who need Docker functionality explicitly choose the less-secure image.

**Pros:**
- Default remains maximally secure
- Users make informed choice
- Clear separation of concerns

**Cons:**
- Two images to maintain
- Users might not understand trade-offs

### Option B: Runtime Flag

Add a flag to `claude-sandbox.sh`:

```bash
claude-sandbox.sh --enable-podman  # Adds caps + installs podman
```

**Pros:**
- Single image
- Explicit opt-in

**Cons:**
- Dynamic capability addition is complex
- Podman install adds startup latency

### Option C: Always Include (Not Recommended)

Add Podman capabilities to the default image.

**Pros:**
- Simplest user experience

**Cons:**
- Weakens security for all users
- Violates principle of least privilege

---

## Implementation Checklist

If proceeding with Podman support:

### Base Image Changes (`images/base-podman/Dockerfile`)
```dockerfile
# Additional packages
RUN apt-get update && apt-get install -y \
    podman \
    crun \
    fuse-overlayfs \
    uidmap \
    slirp4netns \
    python3-pip \
    && pip3 install --break-system-packages podman-compose \
    && rm -rf /var/lib/apt/lists/*

# Podman wrapper for cgroups=disabled
COPY podman-wrapper.sh /usr/local/bin/podman-wrapper
RUN mv /usr/bin/podman /usr/bin/podman.real \
    && ln -s /usr/local/bin/podman-wrapper /usr/bin/podman
```

### Docker Compose Changes
```yaml
sandbox:
  # Drop ALL default capabilities, add only what's required
  cap_drop:
    - ALL
  cap_add:
    - SYS_ADMIN     # Required for Podman UID mapping
    - MKNOD         # Required for /dev/fuse
    - CHOWN         # Required for gosu/file ownership
    - DAC_OVERRIDE  # Required for gosu
    - FOWNER        # Required for file operations
    - SETUID        # Required for gosu/newuidmap
    - SETGID        # Required for gosu/newuidmap
    - SETFCAP       # Required for capability operations
    - KILL          # Required for process signals
  devices:
    - /dev/fuse:/dev/fuse
  security_opt:
    - seccomp=../images/base/seccomp-podman.json  # Custom profile with ptrace restriction
    - label:disable
```

### Whitelist Additions
```
# Container registries
.cloudflarestorage.com  # Docker Hub blob storage

# Package repositories (if installing at runtime)
.debian.org
.debian.net
```

### Documentation Updates
- Update README with DinD option
- Add security advisory about elevated capabilities
- Document `--network=host` requirement for child containers

---

## Conclusion

Podman-in-sandbox is technically viable and preserves the critical network isolation property. The required `CAP_SYS_ADMIN` capability is a meaningful security trade-off, but we've significantly reduced the attack surface through:

1. **Capability minimization:** Drop all default caps, add only 9 required ones
2. **Custom seccomp profile:** Block kernel modules, BPF, kexec, unrestricted ptrace
3. **Explicit syscall blocking:** Block `process_vm_*`, `userfaultfd`, `kcmp`, `perf_event_open`

The proxy-based network isolation remains effective: child containers cannot bypass the whitelist, and volume mounts come from the sandbox filesystem rather than the host. This satisfies the core security requirement that Claude cannot exfiltrate data to arbitrary destinations.

For users who don't need Docker functionality, the current security model should remain the default.
