# Future Directions for Docker-in-Docker

This document outlines alternative approaches for Docker-in-Docker capabilities that were identified but not fully investigated. These may be worth exploring for specific use cases or as the landscape evolves.

For the currently implemented solution (Podman rootless), see [ADR-006](./adr/006-adopt-podman-rootless.md).

## Alternative Container Runtimes

### nerdctl + containerd

Docker-compatible CLI for containerd with native rootless support.

**Key features:**
- Full Docker CLI compatibility
- Native rootless mode
- Supports lazy-pulling (stargz)
- Supports encrypted images (ocicrypt)
- Active CNCF project

**Considerations:**
- Requires running containerd daemon inside sandbox
- Less documentation than Docker/Podman
- Nested container support needs testing in WSL2

**When to consider:**
- If Podman has compatibility issues with specific Docker features
- For containerd-native workflows (Kubernetes development)

**References:**
- [GitHub: containerd/nerdctl](https://github.com/containerd/nerdctl)
- [nerdctl Rootless Docs](https://github.com/containerd/nerdctl/blob/main/docs/rootless.md)

---

### Rootless Docker

Docker daemon running in user namespace without root.

**Considerations:**
- Complex setup in containers
- May need `--skip-iptables` flag in WSL2
- Requires systemd (WSL2 0.68+ with systemd enabled)
- Full Docker CLI compatibility

**When to consider:**
- If 100% Docker CLI compatibility is required
- If Podman has edge cases that Docker handles better

**References:**
- [Docker Docs: Rootless Mode](https://docs.docker.com/engine/security/rootless/)

---

## Build-Only Solutions

If the primary need is building images (not running containers), these tools work without elevated capabilities.

### Kaniko

Build container images from Dockerfile inside containers without Docker daemon.

**Pros:**
- No Docker daemon required
- No privileged mode needed
- Works in Kubernetes

**Cons:**
- Build only, cannot run containers
- Slower than native Docker builds
- Some Dockerfile features unsupported

**When to consider:**
- CI/CD pipelines that only need image building
- Environments where running containers isn't needed

**References:**
- [GitHub: GoogleContainerTools/kaniko](https://github.com/GoogleContainerTools/kaniko)

---

### BuildKit (Standalone Rootless)

Moby's next-generation builder, can run standalone without Docker.

**Pros:**
- Highly efficient, concurrent builds
- DAG-based caching
- Rootless mode available

**Cons:**
- Build only
- Different CLI than Docker (`buildctl`)
- `--oci-worker-no-process-sandbox` has security caveats

**When to consider:**
- High-performance build pipelines
- Complex multi-stage builds with advanced caching

**References:**
- [GitHub: moby/buildkit](https://github.com/moby/buildkit)
- [BuildKit Rootless Docs](https://github.com/moby/buildkit/blob/master/docs/rootless.md)

---

### Buildah

OCI image builder from the Podman ecosystem.

**Pros:**
- No daemon
- No root required
- Shell-scriptable (more auditable than Dockerfiles)

**When to consider:**
- Scripted image builds
- Podman ecosystem integration

**References:**
- [GitHub: containers/buildah](https://github.com/containers/buildah)

---

## VM-Based Isolation

These approaches provide stronger isolation but have significant prerequisites.

### Kata Containers

Runs containers inside lightweight VMs for stronger isolation.

**Current status:** Not viable in WSL2 (requires KVM/nested virtualization)

**When to consider:**
- If running on native Linux with KVM support
- For high-security environments requiring VM-level isolation

**References:**
- [Kata Containers](https://katacontainers.io/)

---

### gVisor (runsc)

User-space kernel that intercepts syscalls for sandboxing.

**Considerations:**
- Rootless mode has issues
- Not all syscalls supported
- Performance overhead

**When to consider:**
- If gVisor's syscall interception model improves
- For defense-in-depth with other isolation mechanisms

**References:**
- [gVisor: Docker in gVisor](https://gvisor.dev/docs/tutorials/docker-in-gvisor/)

---

## When WSL2 Limitations Are Resolved

### Sysbox

Currently blocked by WSL2's seccomp filter on PID 1 (see [ADR-002](./adr/002-reject-sysbox-envbox.md)).

If future WSL2 versions resolve this:
- Sysbox would provide secure DinD without CAP_SYS_ADMIN
- Would be the preferred solution over Podman

**References:**
- [Sysbox WSL2 Issue #32](https://github.com/nestybox/sysbox/issues/32)

---

## Summary

| Approach | Status | Best For |
|----------|--------|----------|
| **Podman rootless** | Implemented | General Docker-in-Docker |
| nerdctl + containerd | Not tested | containerd-native workflows |
| Rootless Docker | Not tested | 100% Docker compatibility |
| Kaniko | Available | Build-only (no running containers) |
| BuildKit | Available | High-performance builds |
| Kata/gVisor | Not viable in WSL2 | Future consideration |
| Sysbox | Not viable in WSL2 | Future consideration |

For most use cases, the current Podman implementation ([ADR-006](./adr/006-adopt-podman-rootless.md)) is recommended.
