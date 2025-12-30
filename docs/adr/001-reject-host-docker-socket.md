# ADR-001: Reject Host Docker Socket Approaches

## Status

Accepted

## Context

We need Docker-in-Docker (DinD) capabilities inside the Claude sandbox to enable Claude to build and run containers. Several approaches exist that connect to the host's Docker daemon:

1. **Docker socket proxy** - Mount `/var/run/docker.sock` through a filtering proxy
2. **Docker context via SSH** - Connect to host Docker over SSH
3. **Docker context via TCP/TLS** - Connect to host Docker over network

These approaches are commonly used in CI/CD systems and appear simpler than running a container runtime inside the sandbox.

## Decision

We reject all host Docker socket approaches because they fundamentally break sandbox isolation.

**Critical requirement:** Volume mounts must be relative to the sandbox filesystem, not the host.

When Claude runs `docker run -v $(pwd):/app myimage`, the path must come from the sandbox container. If containers are created on the host Docker daemon:

- `-v /path:/container` mounts from the **host filesystem**
- `--net=host` accesses the **host network** (bypassing our proxy)
- `--pid=host` sees **host processes**
- A compromised sandbox can mount `/` from the host and escape completely

### Why Socket Proxies Don't Help

Projects like [Tecnativa/docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy) filter API endpoints (e.g., block `/exec`), but they cannot filter request bodies. They cannot block dangerous `HostConfig` options:

```json
{
  "HostConfig": {
    "Binds": ["/:/host"],
    "Privileged": true,
    "NetworkMode": "host"
  }
}
```

Even [Buildkite/sockguard](https://github.com/buildkite/sockguard) (archived), which does filter request bodies, still runs containers on the host with restrictions. This doesn't meet our requirement.

## Consequences

### Positive

- Maintains true sandbox isolation
- Volume mounts come from sandbox filesystem, not host
- Network isolation preserved (all traffic through proxy)
- No risk of host filesystem access

### Negative

- Must run a container runtime inside the sandbox
- More complex setup than socket mounting
- Requires elevated capabilities (CAP_SYS_ADMIN) for nested containers

### Neutral

- This is a fundamental architectural decision that shapes all DinD work

## References

- [The Dangers of Docker.sock](https://raesene.github.io/blog/2016/03/06/The-Dangers-Of-Docker.sock/)
- [HackTricks: Docker Breakout](https://book.hacktricks.wiki/en/linux-hardening/privilege-escalation/docker-security/docker-breakout-privilege-escalation/index.html)
- [Tecnativa/docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy)
