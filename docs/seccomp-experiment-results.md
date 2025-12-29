# Custom Seccomp Profile Experiment Results

**Date:** 2025-12-29
**Goal:** Reduce attack surface by replacing `seccomp:unconfined` with a minimal profile

## Summary

We successfully replaced `seccomp:unconfined` with a custom seccomp profile that allows Podman to function while still blocking dangerous syscalls. However, **CAP_SYS_ADMIN is still required** for user namespace UID mapping operations.

## Findings

### What We Can Improve

| Before | After |
|--------|-------|
| `seccomp:unconfined` (allows ALL syscalls) | Custom profile (allows ~371 syscalls) |
| Blocks nothing | Blocks kernel modules, BPF, kexec, reboot, etc. |

### What We Cannot Remove

**CAP_SYS_ADMIN is required** for rootless Podman because:

1. Writing to `/proc/[pid]/uid_map` requires elevated privileges
2. Even with setuid `newuidmap` helper, the kernel enforces additional checks inside containers
3. Without CAP_SYS_ADMIN: `newuidmap: write to uid_map failed: Operation not permitted`

## Security Comparison

### Dangerous Syscalls BLOCKED by Custom Profile

These are blocked by our profile but would be allowed with `seccomp:unconfined`:

| Category | Syscalls | Risk |
|----------|----------|------|
| Kernel modules | `init_module`, `finit_module`, `delete_module` | Load malicious kernel code |
| BPF | `bpf` | Kernel-level packet filtering, tracing, potential exploits |
| Raw I/O | `ioperm`, `iopl` | Direct hardware access |
| Kexec | `kexec_load`, `kexec_file_load` | Replace running kernel |
| Power | `reboot` | System disruption |
| Swap | `swapon`, `swapoff` | Resource manipulation |
| Time | `settimeofday`, `clock_settime` | Time-based attack vectors |
| Accounting | `acct` | Process accounting manipulation |

### Syscalls ALLOWED for Podman

The custom profile allows:
- **Standard syscalls** (~350): File I/O, networking, memory management, process control
- **Namespace syscalls**: `clone`, `clone3`, `setns`, `unshare`
- **Mount syscalls**: `mount`, `umount`, `umount2`, `pivot_root`
- **Keyring syscalls**: `add_key`, `keyctl`, `request_key`
- **Container runtime**: `sethostname`, `setdomainname`
- **Debugging**: `ptrace` (for same-user debugging)

## Remaining Risk: CAP_SYS_ADMIN

CAP_SYS_ADMIN still enables:
- Mount operations (could mount host paths if accessible)
- User namespace creation and configuration
- Some cgroup operations
- Various administrative operations

**Mitigations in place:**
- No host filesystem paths exposed
- Network isolation via proxy still enforced
- Running as non-root user (developer)
- Custom seccomp blocks many dangerous syscalls

## Configuration

### docker-compose.yml

```yaml
sandbox:
  cap_add:
    - SYS_ADMIN  # Required for uid_map
    - MKNOD
  devices:
    - /dev/fuse:/dev/fuse
  security_opt:
    - seccomp=/path/to/seccomp-podman.json  # Custom profile instead of unconfined!
    - label:disable
```

### Profile Location

`images/base/seccomp-podman.json`

## Conclusion

**Improvement achieved:** Replacing `seccomp:unconfined` with a custom profile significantly reduces attack surface by blocking kernel module loading, BPF, kexec, and other dangerous syscalls.

**Remaining trade-off:** CAP_SYS_ADMIN cannot be removed due to kernel-level requirements for user namespace UID mapping. This remains a meaningful security concern but is partially mitigated by the custom seccomp profile.

See [podman-uid-mapping-research.md](./podman-uid-mapping-research.md) for detailed analysis of why CAP_SYS_ADMIN cannot be avoided.

### Comparison to Original Podman Experiment

| Aspect | Original Config | Improved Config |
|--------|-----------------|-----------------|
| CAP_SYS_ADMIN | Required | Required (unchanged) |
| Seccomp | `unconfined` | Custom minimal profile |
| Blocked syscalls | 0 | ~30+ dangerous syscalls |
| Kernel module loading | Allowed | **Blocked** |
| BPF | Allowed | **Blocked** |
| Kexec | Allowed | **Blocked** |
| Container escape risk | Higher | Lower |
