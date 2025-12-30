# ADR-003: Reject --privileged Flag for Docker-in-Docker

## Status

Accepted

## Context

The `--privileged` flag is the simplest way to enable Docker-in-Docker. It grants the container full access to the host's capabilities and devices, making nested container operations trivial.

For the Podman-enabled sandbox variant, we need elevated capabilities. The question is whether to use `--privileged` for simplicity or craft a minimal capability set.

## Decision

We reject `--privileged` and instead use a minimal set of explicitly granted capabilities.

### What --privileged Grants

| Feature | --privileged | Our Config |
|---------|--------------|------------|
| All capabilities | Yes (all 41) | No (9 specific) |
| All devices | Yes | No (only /dev/fuse) |
| Seccomp | Disabled | Custom restrictive profile |
| AppArmor | Disabled | Disabled |
| Read-only paths | Removed | Preserved |
| Masked paths | Removed | Preserved |
| CAP_NET_RAW | Granted | Dropped |

### Our Minimal Configuration

```yaml
cap_drop:
  - ALL
cap_add:
  - SYS_ADMIN     # Required for Podman UID mapping
  - MKNOD         # Required for /dev/fuse
  - CHOWN         # Required for gosu
  - DAC_OVERRIDE  # Required for gosu
  - FOWNER        # Required for file operations
  - SETUID        # Required for gosu/newuidmap
  - SETGID        # Required for gosu/newuidmap
  - SETFCAP       # Required for capability operations
  - KILL          # Required for process signals
devices:
  - /dev/fuse:/dev/fuse
security_opt:
  - seccomp=seccomp-podman.json
  - label:disable
```

### Security Differences

With `--privileged`, an attacker could:
- Load kernel modules (`init_module`, `finit_module`)
- Run eBPF programs for kernel-level attacks
- Use `kexec` to replace the running kernel
- Access all host devices
- Manipulate raw network sockets

Our configuration blocks all of these through custom seccomp profile and capability dropping.

## Consequences

### Positive

- Significantly reduced attack surface compared to `--privileged`
- Kernel module loading blocked by seccomp
- BPF and kexec blocked
- CAP_NET_RAW explicitly dropped (no raw socket attacks)
- Read-only and masked paths preserved

### Negative

- More complex configuration to maintain
- Must track exactly which capabilities are needed
- Potential for breakage if Podman requirements change

### Neutral

- CAP_SYS_ADMIN is still required (unavoidable for rootless Podman)
- This is the best balance between functionality and security

## References

- [Trail of Bits: Understanding Docker Container Escapes](https://blog.trailofbits.com/2019/07/19/understanding-docker-container-escapes/)
- [OWASP Docker Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Docker_Security_Cheat_Sheet.html)
- [Excessive Capabilities Cheat Sheet](https://0xn3va.gitbook.io/cheat-sheets/container/escaping/excessive-capabilities)
