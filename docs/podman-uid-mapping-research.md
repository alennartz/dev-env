# Why CAP_SYS_ADMIN Cannot Be Avoided for Rootless Podman

**Date:** 2025-12-29

## Summary

We investigated whether CAP_SYS_ADMIN could be avoided by using single-UID mapping instead of subordinate UID ranges. **Conclusion: It cannot.** Rootless Podman fundamentally requires subordinate UID ranges, and those require CAP_SYS_ADMIN inside Docker containers.

## The UID Mapping Problem

### How Rootless Podman Works

Rootless Podman uses Linux user namespaces to run containers without root. It needs to map UIDs:

```
Container UID 0     → Host UID 1000 (developer)
Container UIDs 1-65535 → Host UIDs 100000-165535 (subordinate range)
```

This mapping is configured via `/etc/subuid` and written to `/proc/[pid]/uid_map` by the setuid `newuidmap` binary.

### The Docker Container Restriction

Inside a Docker container, even setuid binaries have their capabilities limited by the container's bounding set. `newuidmap` needs CAP_SYS_ADMIN to write to `uid_map`:

| Configuration | Result |
|--------------|--------|
| No CAP_SYS_ADMIN | `newuidmap: write to uid_map failed: Operation not permitted` |
| With CAP_SYS_ADMIN | Works |

## Can We Use Single-UID Mapping Instead?

### What Works Without CAP_SYS_ADMIN

Simple single-UID mapping works:
```bash
unshare --user --map-root-user echo "works"
# Maps only: Container UID 0 → Host UID 1000
```

This doesn't require `newuidmap` - the kernel allows any user to map their own UID.

### Why Single-UID Doesn't Work for Podman

We tested running Podman inside a pre-created single-UID namespace:

```bash
unshare --user --map-root-user podman run alpine echo "test"
```

**Result:** Failed with mount permission errors.

```
Error: mount overlay: operation not permitted
```

### Root Cause

Single-UID user namespaces have fundamentally restricted capabilities:

1. **No subordinate UIDs** → Container images with multiple file owners break
2. **Limited mount capabilities** → Can't create overlay filesystems
3. **Capability inheritance** → Even with CAP_SYS_ADMIN in outer container, inner user namespace can't do privileged mounts

The `newuidmap` approach isn't just about mapping UIDs - it sets up the user namespace with proper capabilities that enable container operations.

## Test Results

| Approach | CAP_SYS_ADMIN | Result |
|----------|---------------|--------|
| Normal rootless Podman | No | ❌ newuidmap fails |
| Normal rootless Podman | Yes | ✅ Works |
| Pre-created single-UID ns | No | ❌ Mount fails |
| Pre-created single-UID ns | Yes | ❌ Mount still fails |
| `--uidmap` explicit single | No | ❌ newuidmap still called |
| `--userns=host` | No | ❌ newuidmap still called |

## Why Subordinate UIDs Are Required

1. **Container images have multiple owners**
   - Alpine base image has files owned by root (0), nobody (65534), etc.
   - Without subordinate mappings, these UIDs have no valid host mapping

2. **Overlay filesystem requirements**
   - Overlay mounts need proper user namespace setup
   - Single-UID namespaces can't satisfy these requirements

3. **Process isolation**
   - Containers may run processes as non-root users
   - Those processes need valid UID mappings

## Final Architecture

```
┌─────────────────────────────────────────────────────┐
│ Docker Container (CAP_SYS_ADMIN + custom seccomp)   │
│                                                     │
│  ┌───────────────────────────────────────────────┐  │
│  │ User Namespace (via newuidmap)                │  │
│  │   UID 0 → 1000                                │  │
│  │   UIDs 1-65535 → 100000-165535                │  │
│  │                                               │  │
│  │  ┌─────────────────────────────────────────┐  │  │
│  │  │ Podman Container                        │  │  │
│  │  │   Overlay filesystem                    │  │  │
│  │  │   Process running as container root     │  │  │
│  │  └─────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

## Security Mitigations

Since CAP_SYS_ADMIN cannot be avoided, we mitigate risk by:

1. **Custom seccomp profile** - Blocks dangerous syscalls (kernel modules, BPF, kexec)
2. **Network isolation** - All traffic through proxy whitelist
3. **No host mounts** - Volume mounts from sandbox only
4. **Non-root user** - Running as `developer`, not root

## Conclusion

CAP_SYS_ADMIN is an unavoidable requirement for rootless Podman inside Docker containers. The subordinate UID range mechanism is fundamental to how rootless containers work - it's not just about mapping UIDs, but about setting up a properly-capable user namespace that can perform container operations.

The best we can do is:
- Keep CAP_SYS_ADMIN (required)
- Use custom seccomp profile instead of `seccomp:unconfined` (reduces attack surface)
- Maintain network isolation via proxy (prevents exfiltration)
