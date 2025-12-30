# ADR-004: Replace seccomp:unconfined with Custom Profile

## Status

Accepted

## Context

Initial Podman testing used `seccomp:unconfined` to disable all seccomp filtering. This was expedient for testing but allows all syscalls, including dangerous ones that could be used for container escape or kernel exploitation.

We investigated whether a custom seccomp profile could allow Podman operations while blocking dangerous syscalls.

## Decision

We replace `seccomp:unconfined` with a custom minimal profile (`images/base/seccomp-podman.json`).

### Dangerous Syscalls Blocked

| Category | Syscalls | Risk |
|----------|----------|------|
| Kernel modules | `init_module`, `finit_module`, `delete_module` | Load malicious kernel code |
| BPF | `bpf` | Kernel-level exploits, tracing |
| Raw I/O | `ioperm`, `iopl` | Direct hardware access |
| Kexec | `kexec_load`, `kexec_file_load` | Replace running kernel |
| Power | `reboot` | System disruption |
| Swap | `swapon`, `swapoff` | Resource manipulation |
| Time | `settimeofday`, `clock_settime` | Time-based attacks |
| Cross-process | `process_vm_readv`, `process_vm_writev` | Read/write other process memory |
| Userfaultfd | `userfaultfd` | Race condition exploits |
| Process comparison | `kcmp` | Information leaks |
| Performance | `perf_event_open` | Information leaks |
| Ptrace | `ptrace` with PTRACE_ATTACH | Only PTRACE_TRACEME allowed |

### Syscalls Allowed for Podman

- **Standard syscalls** (~350): File I/O, networking, memory, process control
- **Namespace syscalls**: `clone`, `clone3`, `setns`, `unshare`
- **Mount syscalls**: `mount`, `umount`, `umount2`, `pivot_root`
- **Keyring syscalls**: `add_key`, `keyctl`, `request_key` (for crun runtime)
- **Container runtime**: `sethostname`, `setdomainname`

### Security Improvement

| Before | After |
|--------|-------|
| `seccomp:unconfined` (all syscalls allowed) | Custom profile (~371 syscalls) |
| Blocks nothing | Blocks kernel modules, BPF, kexec, etc. |
| Known CVE vectors open | Many CVE vectors closed |

## Consequences

### Positive

- Blocks kernel module loading (CVE-2022-0185 mitigation)
- Blocks BPF exploits
- Blocks kexec kernel replacement
- Blocks cross-process memory access
- Restricts ptrace to self-tracing only
- Meaningful attack surface reduction

### Negative

- Custom profile must be maintained
- May need updates if Podman/crun requirements change
- Adds complexity to deployment

### Neutral

- CAP_SYS_ADMIN is still required (see ADR-005 for why)
- Profile is based on Docker's default with additions for Podman

## References

- [Docker Seccomp Documentation](https://docs.docker.com/engine/security/seccomp/)
- [Datadog: Container Security Fundamentals - Seccomp](https://securitylabs.datadoghq.com/articles/container-security-fundamentals-part-6/)
- Profile location: `images/base/seccomp-podman.json`
