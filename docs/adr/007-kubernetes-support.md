# ADR-007: Kubernetes Support via K3s with Privileged Mode

## Status

Accepted (with significant security trade-offs documented)

## Context

We want to add Kubernetes support to the Claude sandbox, enabling workflows that require both:
- Building container images (existing Podman capability)
- Deploying to a local Kubernetes cluster

This enables development of K8s applications where Claude can build an image and deploy it to test.

### Requirements

- Single-node K8s cluster inside the sandbox
- Coexistence with existing Podman DinD capability
- Network isolation through proxy preserved
- `kubectl` access for the developer user
- Ability to deploy Podman-built images to K8s

### Constraints

- No systemd in container (required for K3s rootless mode)
- Must work on Docker hosts (not just Podman)
- cgroup v2 environment (WSL2, modern Linux)

## Decision

We add a new `base-k8s` image variant that runs K3s with:
- `--privileged` flag
- `--cgroupns=host` flag
- Network isolation via `network_mode: "service:proxy"`

### Why These Are Required

We tested an escalation path from minimal to maximum permissions:

| Configuration | K3s Server | Pods Start | Reason |
|--------------|------------|------------|--------|
| 11 caps + seccomp + cgroup mount | Yes | **No** | runc: "can't get final child's PID from pipe: EOF" |
| 11 caps + seccomp=unconfined | Yes | **No** | Same error |
| --privileged + cgroup mount | Yes | **No** | containerd shim panic: "cgroups: invalid group path" |
| **--privileged + cgroupns=host** | **Yes** | **Yes** | Working |

**Why `--privileged`**: K3s's containerd uses runc to create pods. runc requires full namespace and cgroup manipulation capabilities that cannot be expressed with individual capabilities. The "EOF" error indicates runc cannot set up PID namespaces for child containers.

**Why `--cgroupns=host`**: Containerd's shim process panics when trying to manage cgroups in an isolated cgroup namespace. Sharing the host's cgroup namespace allows proper cgroup hierarchy creation for pods.

### Why K3s Rootless Doesn't Work

K3s has a `--rootless` mode, but it requires:
- systemd with `Delegate=yes` property for cgroup delegation
- `systemctl --user` commands for cgroup controller setup

Our container doesn't run systemd, making rootless mode impossible.

## Consequences

### What `--privileged` Means

The `--privileged` flag grants:

| Privilege | Risk |
|-----------|------|
| All 41 Linux capabilities | Container has full capability set |
| Seccomp disabled | All syscalls allowed, including dangerous ones |
| AppArmor/SELinux disabled | No mandatory access control |
| All devices accessible | Full /dev access including disks |
| Read-write /sys access | Can modify kernel parameters |

### What `--cgroupns=host` Means

| Aspect | Risk |
|--------|------|
| Shared cgroup namespace | Container can see host's cgroup hierarchy |
| Cgroup manipulation | Container can potentially affect host resource limits |
| Process visibility | Container may see host process cgroups |

### Security Risk Assessment

**CRITICAL: This image variant has significantly reduced isolation compared to `base` or `base-podman`.**

| Threat | base | base-podman | base-k8s | Risk Level |
|--------|------|-------------|----------|------------|
| Container escape via capability abuse | Blocked | Partially mitigated | **Possible** | HIGH |
| Container escape via syscall exploit | Blocked | Blocked (seccomp) | **Possible** | HIGH |
| Host cgroup manipulation | Blocked | Blocked | **Possible** | MEDIUM |
| Network data exfiltration | Blocked (proxy) | Blocked (proxy) | **Blocked (proxy)** | LOW |
| Host filesystem access | Blocked | Blocked | Blocked | LOW |
| Host process interference | Blocked | Blocked | **Possible** via cgroups | MEDIUM |

### What Remains Protected

Despite elevated privileges, these protections remain:

1. **Network isolation for developer user**: Traffic from the developer user (Claude, git, curl, etc.) flows through the Squid proxy with domain whitelisting.

2. **Network isolation for K8s pods**: Pod HTTP/HTTPS traffic is intercepted via PREROUTING DNAT rules and routed through the Squid proxy. Non-HTTP/HTTPS traffic is blocked.

3. **Filesystem isolation**: Only explicitly mounted volumes are accessible. Host filesystem is not mounted.

4. **Container boundary**: The outer Docker container still provides some isolation from the host kernel (though significantly weakened).

### Network Isolation for Pods

K8s pods run in their own network namespace (managed by flannel CNI). Their egress traffic goes through the FORWARD chain rather than OUTPUT. To intercept this traffic, the k8s-entrypoint.sh adds PREROUTING and FORWARD chain rules after K3s creates the cni0 interface:

```
Pod (10.42.x.x) ──► PREROUTING ──► DNAT to proxy:3128/3129 ──► Squid ──► Internet
                    (nat table)     (cni0 interface)
```

| Traffic Source | Proxy Filtered | Notes |
|----------------|----------------|-------|
| Developer user (sandbox) | **Yes** | iptables OUTPUT chain |
| Podman containers | **Yes** | Uses host network via slirp4netns |
| K8s pods (HTTP/HTTPS) | **Yes** | iptables PREROUTING DNAT to squid |
| K8s pods (other ports) | **Blocked** | iptables FORWARD REJECT rule |

**How it works**:
1. Squid listens on `0.0.0.0:3128/3129` (not just loopback) for intercept ports
2. After K3s creates cni0, the entrypoint adds PREROUTING rules to DNAT pod HTTP/HTTPS traffic to squid
3. A FORWARD REJECT rule blocks any pod traffic that wasn't DNAT'd (non-HTTP/HTTPS ports)

**Limitations**:
- Only HTTP (port 80) and HTTPS (port 443) are proxied; other ports are blocked
- Pod-to-pod traffic within the cluster is unaffected (allowed via 10.42.0.0/16 rules)

### What Is NOT Protected

The following attacks become possible with `--privileged --cgroupns=host`:

1. **Kernel module loading**: Container can load kernel modules if available
2. **BPF programs**: Container can load eBPF programs (potential escape vector)
3. **Raw device access**: Container can read/write block devices
4. **Kernel parameter modification**: Container can modify /proc/sys and /sys settings
5. **cgroup manipulation**: Container can affect host cgroup limits

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  base-k8s container                                          │
│  (--privileged --cgroupns=host --network_mode=service:proxy) │
│                                                              │
│  ┌─────────────┐    ┌──────────────────────────────────────┐ │
│  │   Podman    │    │  K3s server (root)                   │ │
│  │  (rootless) │    │  ├─ API Server :6443                 │ │
│  │  developer  │    │  ├─ Kubelet                          │ │
│  │  user       │    │  └─ Containerd (runc)                │ │
│  └──────┬──────┘    └──────────────┬───────────────────────┘ │
│         │                          │                         │
│         │     Image Transfer       │                         │
│         │  podman save | k3s ctr   │                         │
│         │         import           │                         │
│         └────────────>─────────────┘                         │
│                                                              │
│  kubectl (developer user) ─────> kube-apiserver:6443         │
│                                                              │
│  ┌──────────────────────────────────────────────────────────┐│
│  │  All external traffic ─────> proxy container             ││
│  │                              (Squid whitelist)           ││
│  │  THIS IS THE PRIMARY SECURITY CONTROL                    ││
│  └──────────────────────────────────────────────────────────┘│
└──────────────────────────────────────────────────────────────┘
```

### Comparison with base-podman

| Aspect | base-podman | base-k8s |
|--------|-------------|----------|
| Capabilities | 9 specific | All (privileged) |
| Seccomp | Custom profile (blocks 40+ syscalls) | Disabled |
| Cgroup namespace | Isolated | Host |
| Kernel module loading | Blocked | Allowed |
| BPF | Blocked | Allowed |
| Container escape risk | Low | **Medium-High** |
| Network isolation (developer) | Yes (proxy) | Yes (proxy) |
| Network isolation (nested containers) | Yes (Podman uses host net) | Yes (PREROUTING DNAT to squid) |

### Acceptable Use Cases

This image is appropriate for:
- Local development and testing of K8s applications
- CI/CD pipelines in isolated environments
- Learning and experimentation

This image is NOT appropriate for:
- Multi-tenant environments
- Processing sensitive data without additional controls
- Production workloads

### Opt-in Model

Like `base-podman`, this is an opt-in variant:

```
images/
├── base/           # Default secure image (no DinD)
├── base-podman/    # Podman + elevated caps (moderate risk)
└── base-k8s/       # K3s + privileged (higher risk)
```

Users must explicitly choose the K8s variant, understanding the trade-offs.

## Alternatives Considered

### k3d (K3s in Docker)

k3d is purpose-built for running K3s in Docker. However:
- Uses similar `--privileged` requirements
- Adds another layer of complexity
- Our approach is simpler (direct K3s in container)

### KinD (Kubernetes in Docker)

KinD with Podman backend was tested but:
- Requires systemd for cgroup delegation (same limitation)
- Experimental with Podman provider

### Sysbox Runtime

Sysbox enables unprivileged K8s in containers but:
- Incompatible with WSL2 (see ADR-002)
- Requires specific host kernel configuration

## Recommendations

1. **Always prefer `base` or `base-podman`** unless K8s is specifically required
2. **Document the risks** when deploying K8s-enabled sandboxes
3. **Monitor for container escape CVEs** affecting privileged containers
4. **Keep K3s updated** to patch security vulnerabilities
5. **Rely on network isolation** as the primary security control

## References

- [K3s Documentation](https://docs.k3s.io/)
- [K3s GitHub Issue #2125: Required Capabilities](https://github.com/k3s-io/k3s/issues/2125)
- [Docker --privileged documentation](https://docs.docker.com/engine/reference/run/#runtime-privilege-and-linux-capabilities)
- [Understanding cgroup namespaces](https://man7.org/linux/man-pages/man7/cgroup_namespaces.7.html)
- Related ADRs: [003](./003-reject-privileged-flag.md), [006](./006-adopt-podman-rootless.md)
