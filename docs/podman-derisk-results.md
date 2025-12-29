# Podman-in-Sandbox De-risk Experiment Results

**Date:** 2025-12-29
**Status:** All phases PASSED - Podman is viable with documented trade-offs

## Executive Summary

We successfully validated that rootless Podman can run inside the Claude sandbox container, enabling Docker-in-Docker functionality while preserving network isolation through the proxy. All five phases of the de-risk plan passed, but the solution requires elevated capabilities that weaken the container's security boundary.

**Key Finding:** Podman works, but requires `CAP_SYS_ADMIN` and `seccomp:unconfined`, which significantly reduces isolation from the host. This is a meaningful security trade-off that should be opt-in for users who need container functionality.

---

## Test Results Summary

| Phase | Result | Configuration Required |
|-------|--------|----------------------|
| 1. User Namespace Nesting | PASS | `CAP_SYS_ADMIN`, `seccomp:unconfined` |
| 2. Rootless Podman Execution | PASS | `crun` runtime, `--cgroups=disabled`, `--network=host` |
| 3. Storage Driver | PASS | Native `overlay` (no changes needed) |
| 4. Network Isolation | PASS | Child containers inherit sandbox network, proxy enforced |
| 5. Compose Compatibility | PASS | Wrapper script to inject `--cgroups=disabled` |

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
| `seccomp:unconfined` | Allow unshare, clone syscalls | **HIGH** |
| `CAP_MKNOD` | Device node creation for fuse | Medium |
| `/dev/fuse` device | Fuse filesystem support | Low |

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

### seccomp:unconfined Risks

Docker's default seccomp profile blocks ~44 dangerous syscalls. Disabling it allows:

1. **unshare:** Create new namespaces (required for Podman, but also useful for escapes)
2. **clone with CLONE_NEWUSER:** User namespace creation
3. **mount:** Filesystem mounting (combined with SYS_ADMIN)
4. **ptrace:** Process tracing (debugging, but also exploitation)
5. **finit_module/init_module:** Kernel module loading

**Historical CVEs blocked by seccomp:**
- CVE-2022-0185: Exploited via `unshare` syscall
- Various kernel exploits requiring specific syscalls

References:
- [Docker Seccomp Documentation](https://docs.docker.com/engine/security/seccomp/)
- [Breakout from Seccomp Unconfined Container](https://tbhaxor.com/breakout-from-seccomp-unconfined-container/)
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
| Container escape to host | Very Difficult | Possible | CAP_SYS_ADMIN + seccomp:unconfined |
| Kernel exploitation | Blocked | Possible | seccomp:unconfined allows more syscalls |
| Privilege escalation in sandbox | Limited | Elevated | More attack surface |

### Comparison: Podman Config vs --privileged

Our configuration is NOT equivalent to `--privileged`:

| Feature | Our Config | --privileged |
|---------|-----------|--------------|
| All capabilities | No (only SYS_ADMIN, MKNOD) | Yes |
| All devices | No (only /dev/fuse) | Yes |
| Seccomp | Disabled | Disabled |
| AppArmor | Disabled | Disabled |
| Read-only paths | Preserved | Removed |
| Masked paths | Preserved | Removed |
| Host network | No | Optional |
| Host PID | No | Optional |

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
  cap_add:
    - SYS_ADMIN
    - MKNOD
  devices:
    - /dev/fuse:/dev/fuse
  security_opt:
    - seccomp:unconfined
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

Podman-in-sandbox is technically viable and preserves the critical network isolation property. However, the required capabilities (`CAP_SYS_ADMIN`, `seccomp:unconfined`) meaningfully weaken container isolation and should be treated as an opt-in feature for users who understand the trade-offs.

The proxy-based network isolation remains effective: child containers cannot bypass the whitelist, and volume mounts come from the sandbox filesystem rather than the host. This satisfies the core security requirement that Claude cannot exfiltrate data to arbitrary destinations.

For users who don't need Docker functionality, the current security model should remain the default.
