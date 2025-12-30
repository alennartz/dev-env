# ADR-006: Adopt Podman Rootless for Docker-in-Docker

## Status

Accepted

## Context

We need Docker-in-Docker capabilities inside the Claude sandbox while preserving network isolation. After rejecting host socket approaches (ADR-001), Sysbox (ADR-002), and evaluating security trade-offs, we tested Podman rootless as our primary candidate.

Requirements:
- Child containers must run inside the sandbox (not on host)
- Volume mounts must be relative to sandbox filesystem
- Network traffic must go through the proxy whitelist
- Docker CLI compatibility for Claude's workflows

## Decision

We adopt Podman rootless with:
- `CAP_SYS_ADMIN` capability (required for UID mapping)
- Custom seccomp profile (blocks dangerous syscalls)
- `crun` runtime with `--cgroups=disabled`
- `--network=host` for child containers (inherits sandbox network)
- Separate opt-in image (`base-podman`) to keep default image secure

### Why Podman

1. **Daemonless** - No root daemon reduces attack surface
2. **Docker-compatible** - `alias docker=podman` works
3. **Rootless mode** - Runs as unprivileged user
4. **Active development** - CNCF project with Red Hat backing

### Why CAP_SYS_ADMIN Is Unavoidable

Rootless Podman uses Linux user namespaces with subordinate UID ranges:

```
Container UID 0     → Host UID 1000 (developer)
Container UIDs 1-65535 → Host UIDs 100000-165535
```

Writing to `/proc/[pid]/uid_map` requires CAP_SYS_ADMIN inside Docker containers. Even the setuid `newuidmap` helper cannot bypass this kernel restriction. Single-UID mapping was tested and fails with mount errors.

### Configuration

```yaml
# docker-compose.yml (sandbox-podman service)
cap_drop:
  - ALL
cap_add:
  - SYS_ADMIN
  - MKNOD
  - CHOWN
  - DAC_OVERRIDE
  - FOWNER
  - SETUID
  - SETGID
  - SETFCAP
  - KILL
devices:
  - /dev/fuse:/dev/fuse
security_opt:
  - seccomp=seccomp-podman.json
  - label:disable
```

### Architecture

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
│  │  │   Network: host (inherits sandbox)      │  │  │
│  │  └─────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────┘  │
│                        │                            │
│                   All traffic                       │
│                        ↓                            │
│              ┌─────────────────┐                    │
│              │  Squid Proxy    │                    │
│              │  (whitelist)    │                    │
│              └─────────────────┘                    │
└─────────────────────────────────────────────────────┘
```

## Consequences

### Positive

- True Docker-in-Docker: child containers run inside sandbox
- Volume mounts come from sandbox filesystem, not host
- Network isolation preserved: child containers respect proxy whitelist
- Docker CLI compatible via `docker` → `podman` alias
- Non-root execution: runs as `developer` user
- Significantly more secure than `--privileged` (see ADR-003)

### Negative

- Requires CAP_SYS_ADMIN (elevated capability)
- Cannot use `no-new-privileges` (see ADR-005)
- Child containers require `--network=host` and `--cgroups=disabled`
- Additional image variant to maintain (`base-podman`)
- Wrapper script needed for compose compatibility

### Security Mitigations

Despite requiring CAP_SYS_ADMIN, we mitigate risk through:

| Mitigation | Effect |
|------------|--------|
| Custom seccomp profile | Blocks kernel modules, BPF, kexec, ptrace ATTACH |
| `cap_drop: ALL` | Only 9 required capabilities, not Docker's 14 defaults |
| No CAP_NET_RAW | Raw socket attacks blocked |
| Network isolation | All traffic through proxy whitelist |
| No host mounts | Volume mounts from sandbox only |
| Non-root user | Running as `developer`, not root |
| Read-only mounts | Claude binary and git config read-only |

### Opt-in Model

The Podman variant is opt-in:

```
images/
├── base/           # Default secure image (no DinD)
└── base-podman/    # Extended image with Podman + elevated caps
```

Users who need Docker functionality explicitly choose the less-secure image. The default remains maximally secure.

## References

- [Podman.io](https://podman.io/)
- [Red Hat: Podman Inside Container](https://www.redhat.com/en/blog/podman-inside-container)
- [Rootless Containers with Podman](https://developers.redhat.com/blog/2020/09/25/rootless-containers-with-podman-the-basics)
- Related ADRs: [001](./001-reject-host-docker-socket.md), [002](./002-reject-sysbox-envbox.md), [003](./003-reject-privileged-flag.md), [004](./004-replace-seccomp-unconfined.md), [005](./005-no-new-privileges-incompatible.md)
