# Docker-in-Docker Alternatives for Sandboxed Environments

This document explores alternatives for providing Docker capabilities inside the sandbox container without introducing escape vulnerabilities. The goal is to allow Claude to run standard `docker` commands while maintaining the security isolation of the sandbox.

## Critical Requirement: True Docker-in-Docker

**Volume mounts must be relative to the sandbox filesystem, not the host.**

When Claude runs `docker run -v $(pwd):/app myimage`, the mounted path must come from the sandbox container's filesystem. If containers are created on the host (via socket proxy, SSH, etc.), then `-v /path:/container` mounts from the **host filesystem**, completely bypassing sandbox isolation.

This rules out all approaches that connect to the host's Docker daemon.

## Constraints

- **No Sysbox**: Doesn't work in WSL2 due to seccomp filter on PID 1
- **No `--privileged`**: Security risk, allows container escape
- **Minimal architecture changes**: Prefer not adding a 3rd container
- **CLI compatibility**: Claude should use standard `docker` commands
- **True isolation**: Child containers must run inside the sandbox, not on host

---

## Not Viable: Host Docker Socket Approaches

The following approaches are **not suitable** for this project because containers created via the host Docker daemon run on the host, not inside the sandbox. This means:

- Volume mounts (`-v /path:/path`) access the **host** filesystem
- `--net=host` accesses the **host** network (bypassing the proxy!)
- `--pid=host` sees **host** processes
- A compromised sandbox can escape by mounting `/` from the host

### Why Socket Proxies Don't Help

Projects like [Tecnativa/docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy) filter API **endpoints** (e.g., block `/exec`), but they **cannot filter request bodies**. They cannot block:

```json
{
  "HostConfig": {
    "Binds": ["/:/host"],
    "Privileged": true,
    "NetworkMode": "host"
  }
}
```

Even [Buildkite/sockguard](https://github.com/buildkite/sockguard) (archived), which does filter request bodies, still runs containers on the host—just with restrictions. This doesn't meet our requirement for volume mounts from the sandbox filesystem.

### Rejected Approaches

| Approach | Why Not Viable |
|----------|----------------|
| Docker socket proxy | Containers on host, mounts from host FS |
| Docker context via SSH | Containers on host, mounts from host FS |
| Docker context via TCP/TLS | Containers on host, mounts from host FS |
| Mounting `/var/run/docker.sock` | Direct host access, complete escape |

**References:**
- [The Dangers of Docker.sock](https://raesene.github.io/blog/2016/03/06/The-Dangers-Of-Docker.sock/)
- [HackTricks: Docker Breakout](https://book.hacktricks.wiki/en/linux-hardening/privilege-escalation/docker-security/docker-breakout-privilege-escalation/index.html)

---

## Viable Alternatives

The following approaches run a container runtime **inside** the sandbox, meaning child containers and their volume mounts are relative to the sandbox filesystem.

---

## Category 1: Alternative Container Runtimes (True DinD)

### 1.1 Podman (Rootless, Daemonless)

Podman is a Docker-compatible CLI that runs containers without a daemon and supports rootless operation.

**Key features:**
- Daemonless architecture (no root daemon)
- Docker CLI compatible (`alias docker=podman`)
- Supports rootless containers via user namespaces
- Supports Docker Compose via `podman-compose` or native support

**Running Podman in a container:**
```bash
# With some capabilities (not --privileged):
podman run --cap-add=sys_admin,mknod \
  --device=/dev/fuse \
  --security-opt label=disable \
  quay.io/podman/stable podman run alpine echo hello
```

**Nested Podman challenges:**
- May require `--privileged` for full functionality
- User namespace nesting has limitations
- Known issues with `newuidmap`/`newgidmap` permissions

**Pros:**
- No daemon = reduced attack surface
- Docker CLI compatible
- Active development, CNCF project

**Cons:**
- Nested rootless has issues (see [Issue #10705](https://github.com/containers/podman/issues/10705))
- May still need elevated capabilities
- Some Docker Compose features missing

**References:**
- [Podman.io](https://podman.io/)
- [Red Hat: Podman Inside Container](https://www.redhat.com/en/blog/podman-inside-container)
- [Rootless Containers with Podman](https://developers.redhat.com/blog/2020/09/25/rootless-containers-with-podman-the-basics)

---

### 1.2 nerdctl (containerd CLI)

Docker-compatible CLI for containerd with native rootless support.

**Key features:**
- Full Docker CLI compatibility
- Native rootless mode
- Supports lazy-pulling (stargz)
- Supports encrypted images (ocicrypt)

**Rootless setup:**
```bash
# Install full distribution (includes rootlesskit, slirp4netns)
tar -xzf nerdctl-full-<VERSION>-linux-amd64.tar.gz -C ~/.local
containerd-rootless-setuptool.sh install
nerdctl run -it alpine
```

**Pros:**
- Cutting-edge containerd features
- Docker-compatible
- Active CNCF project

**Cons:**
- Requires containerd (additional daemon)
- Nested container support unclear
- Less documentation than Docker/Podman

**References:**
- [GitHub: containerd/nerdctl](https://github.com/containerd/nerdctl)
- [nerdctl Rootless Docs](https://github.com/containerd/nerdctl/blob/main/docs/rootless.md)
- [Rootless Containers: containerd](https://rootlesscontaine.rs/getting-started/containerd/)

---

### 1.3 Rootless Docker

Docker daemon running in user namespace without root.

**Setup in container:**
```bash
# Requires: newuidmap, newgidmap, /etc/subuid, /etc/subgid
dockerd-rootless-setuptool.sh install
export DOCKER_HOST=unix://${XDG_RUNTIME_DIR}/docker.sock
docker run alpine echo hello
```

**WSL2 considerations:**
- May need `--skip-iptables` flag
- Requires systemd (WSL2 0.68+ with systemd enabled)
- Kernel must support user namespaces

**Pros:**
- Standard Docker CLI
- Reduced attack surface
- Official Docker support

**Cons:**
- Complex setup in containers
- Nested namespaces have limitations
- Performance overhead

**References:**
- [Docker Docs: Rootless Mode](https://docs.docker.com/engine/security/rootless/)
- [WSL2 Rootless Docker Guide](https://gist.github.com/espresso3389/a4aeeb1ce9d12c2b0d8b7409eed62e8c)

---

## Category 2: Image Building Only

If the primary need is building images (not running containers), these tools work without Docker daemon.

### 2.1 Kaniko

Build container images from Dockerfile inside containers/Kubernetes without Docker daemon.

**Usage:**
```bash
# Run kaniko executor
docker run \
  -v $(pwd):/workspace \
  gcr.io/kaniko-project/executor:latest \
  --dockerfile=/workspace/Dockerfile \
  --context=/workspace \
  --destination=myregistry/myimage:tag
```

**Pros:**
- No Docker daemon required
- No privileged mode needed
- Works in Kubernetes

**Cons:**
- Build only, cannot run containers
- Slower than native Docker builds
- Some Dockerfile features unsupported

---

### 2.2 BuildKit (Standalone Rootless)

Moby's next-generation builder, can run standalone without Docker.

**Usage:**
```bash
# Using rootless buildkit
docker run \
  --name buildkitd \
  -d \
  --security-opt seccomp=unconfined \
  --security-opt apparmor=unconfined \
  moby/buildkit:rootless --oci-worker-no-process-sandbox

# Build with buildctl
buildctl --addr tcp://buildkitd:1234 build \
  --frontend dockerfile.v0 \
  --local context=. \
  --local dockerfile=.
```

**Pros:**
- Highly efficient, concurrent builds
- DAG-based caching
- Rootless mode available

**Cons:**
- Build only
- `--oci-worker-no-process-sandbox` has security caveats
- Different CLI than Docker

**References:**
- [GitHub: moby/buildkit](https://github.com/moby/buildkit)
- [BuildKit Rootless Docs](https://github.com/moby/buildkit/blob/master/docs/rootless.md)
- [GitLab: Build with BuildKit](https://docs.gitlab.com/ci/docker/using_buildkit/)

---

### 2.3 Buildah

OCI image builder, works with Podman ecosystem.

**Usage:**
```bash
buildah bud -t myimage .
buildah push myimage docker://registry/myimage
```

**Pros:**
- No daemon
- No root required
- Shell-scriptable (more auditable than Dockerfiles)

**Cons:**
- Build only
- Different CLI

---

### 2.4 img (genuinetools)

Standalone, daemon-less, unprivileged image builder.

**Usage:**
```bash
img build -t myimage .
img push myimage
```

**Pros:**
- Docker-like CLI (`img build` vs `docker build`)
- Unprivileged operation
- Based on BuildKit

**Cons:**
- Build only
- Less actively maintained
- FUSE backend can be buggy

**References:**
- [GitHub: genuinetools/img](https://github.com/genuinetools/img)

---

## Category 3: VM-Based Isolation

### 3.1 Kata Containers

Runs containers inside lightweight VMs for stronger isolation.

**Limitations:**
- Requires KVM/nested virtualization
- Won't work in most WSL2 setups
- Docker-in-Kata typically needs `--privileged`

**Not recommended** for this use case due to WSL2 limitations.

---

### 3.2 gVisor (runsc)

User-space kernel that intercepts syscalls for sandboxing.

**Usage:**
```bash
# Configure Docker to use runsc runtime
docker run --runtime=runsc alpine echo hello
```

**Docker-in-gVisor:**
```bash
# Requires --net-raw for raw sockets
docker run --runtime=runsc \
  -e DOCKER_HOST=tcp://localhost:2375 \
  docker:dind
```

**Pros:**
- Strong syscall-level isolation
- No VM overhead

**Cons:**
- Rootless mode has issues ([#311](https://github.com/google/gvisor/issues/311))
- Not all syscalls supported
- Performance overhead

**References:**
- [gVisor: Docker in gVisor](https://gvisor.dev/docs/tutorials/docker-in-gvisor/)

---

## Category 4: CI/CD Specific Solutions

### 4.1 Dagger

CI/CD pipelines as code, built on BuildKit.

**How it works:**
- Write pipelines in Go, Python, TypeScript, or GraphQL
- Runs as containers via BuildKit engine
- Same pipeline runs locally and in CI

**Example (Go):**
```go
func main() {
    ctx := context.Background()
    client, _ := dagger.Connect(ctx)
    defer client.Close()

    client.Container().
        From("golang:1.21").
        WithDirectory("/src", client.Host().Directory(".")).
        WithExec([]string{"go", "build", "./..."}).
        Sync(ctx)
}
```

**Pros:**
- Portable pipelines
- Strong caching
- Type-safe

**Cons:**
- Learning curve
- Still needs container runtime underneath

**References:**
- [Dagger.io](https://dagger.io/)
- [GitHub: dagger/dagger](https://github.com/dagger/dagger)

---

### 4.2 Testcontainers Cloud

Offload container execution to cloud service.

**How it works:**
- Install TC Cloud agent in CI
- Testcontainers library routes requests to cloud
- No local Docker daemon needed

**Pros:**
- No DinD or privileged mode
- Works with CI platforms lacking nested virt
- Managed service

**Cons:**
- Paid service
- Network latency
- Not general-purpose Docker replacement

**References:**
- [Testcontainers Cloud Docs](https://testcontainers.com/cloud/docs/)
- [Docker Blog: Testcontainers Cloud vs DinD](https://www.docker.com/blog/testcontainers-cloud-vs-docker-in-docker-for-testing-scenarios/)

---

## Category 5: Sysbox Alternatives

### 5.1 Why Sysbox Doesn't Work in WSL2

Sysbox requires installing as a container runtime on the host and uses advanced Linux features that conflict with WSL2's architecture:

- WSL2 runs a Microsoft-modified Linux kernel
- PID 1 in WSL2 already has seccomp filters applied
- Sysbox needs to set up its own seccomp policies
- Nested user namespace setup fails

**References:**
- [Sysbox WSL2 Issue #32](https://github.com/nestybox/sysbox/issues/32)

### 5.2 Envbox (Coder)

Coder's envbox bundles Sysbox into a container for cloud dev environments.

**Not applicable** for WSL2 due to same underlying Sysbox limitations.

---

## Recommendation Matrix

Only approaches providing **true isolation** (containers inside sandbox) are considered viable.

| Approach | CLI Compat | True Isolation | WSL2 | Complexity | Notes |
|----------|------------|----------------|------|------------|-------|
| ~~Socket Proxy~~ | Full | **No** | Yes | Low | Rejected: mounts from host |
| ~~Docker SSH/TCP~~ | Full | **No** | Yes | Medium | Rejected: mounts from host |
| Podman Rootless | High | **Yes** | Needs testing | Medium | Most promising |
| nerdctl Rootless | High | **Yes** | Needs testing | Medium | Alternative to Podman |
| Rootless Docker | Full | **Yes** | Needs testing | High | Complex nested setup |
| Kaniko (build only) | Different | **Yes** | Yes | Low | Build only |
| gVisor | High | **Yes** | Unlikely | High | Syscall overhead |

---

## Recommended Approaches for This Project

Given the critical requirement that volume mounts must be relative to the sandbox filesystem, only true Docker-in-Docker approaches are viable.

### Option A: Podman Rootless in Sandbox (Most Promising)

Run Podman inside the sandbox container:
- Docker-compatible CLI (`alias docker=podman`)
- Daemonless = smaller attack surface
- Child containers run inside sandbox
- Volume mounts are from sandbox filesystem

**Requirements to test:**
- Capabilities needed: `sys_admin`, `mknod`, possibly others
- Device access: `/dev/fuse`
- User namespace configuration
- WSL2 kernel compatibility

**Tradeoff:** May need some elevated capabilities (not full `--privileged`). Nested rootless has known challenges.

### Option B: nerdctl + containerd Rootless

Similar to Podman but using containerd:
- Docker-compatible CLI
- Rootless mode available
- Active CNCF project

**Tradeoff:** Requires running containerd daemon inside sandbox.

### Option C: Rootless Docker Daemon in Sandbox

Run a separate Docker daemon inside the sandbox:
- Full Docker CLI compatibility
- Child containers isolated from host
- Volume mounts relative to sandbox

**Tradeoff:** High complexity. Requires user namespaces, may need `--skip-iptables` in WSL2, systemd dependency.

### Option D: Build-Only (Kaniko/Buildah)

If full `docker run` is not required:
- Use Kaniko or Buildah for image building
- No daemon required
- Works unprivileged

**Tradeoff:** Cannot run containers, only build images.

---

## Next Steps

1. **Test Podman rootless** inside the current sandbox with minimal capabilities
2. **Document required capabilities** if it works
3. **Test nerdctl** as fallback if Podman has issues
4. **Evaluate security** of any required capabilities vs `--privileged`

---

## Further Reading

- [OWASP Docker Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Docker_Security_Cheat_Sheet.html)
- [Rootless Containers](https://rootlesscontaine.rs/)
- [Nestybox: Related Tech Comparison](https://blog.nestybox.com/2020/10/06/related-tech-comparison.html)
- [Coder: Docker in Workspaces](https://coder.com/docs/admin/templates/extending-templates/docker-in-workspaces)
- [The Dangers of Docker.sock](https://raesene.github.io/blog/2016/03/06/The-Dangers-Of-Docker.sock/)
