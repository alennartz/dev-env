# ADR-002: Reject Sysbox and Envbox

## Status

Accepted

## Context

[Sysbox](https://github.com/nestybox/sysbox) is a container runtime that enables running Docker and Kubernetes inside containers without `--privileged`. It's often cited as the ideal solution for secure Docker-in-Docker.

[Envbox](https://coder.com/docs/admin/templates/extending-templates/docker-in-workspaces#envbox) is Coder's container image that bundles Sysbox for cloud development environments.

Both would provide true container isolation with minimal security trade-offs.

## Decision

We reject Sysbox and Envbox because they do not work in WSL2.

### Technical Reason

Sysbox requires installing as a container runtime on the host and uses advanced Linux features that conflict with WSL2's architecture:

1. WSL2 runs a Microsoft-modified Linux kernel
2. PID 1 in WSL2 already has seccomp filters applied by Microsoft's init system
3. Sysbox needs to set up its own seccomp policies for nested containers
4. The nested user namespace setup fails due to these conflicts

This is a fundamental incompatibility, not a configuration issue.

## Consequences

### Positive

- Clear decision eliminates a non-viable option from consideration
- Focus can shift to alternatives that work in WSL2

### Negative

- Cannot use what would otherwise be the most secure DinD solution
- Must accept more security trade-offs with alternative approaches

### Neutral

- This limitation may be resolved in future WSL2 versions
- If WSL2 support is added, this decision should be revisited

## References

- [Sysbox WSL2 Issue #32](https://github.com/nestybox/sysbox/issues/32)
- [Nestybox Blog: Related Tech Comparison](https://blog.nestybox.com/2020/10/06/related-tech-comparison.html)
- [Coder: Docker in Workspaces](https://coder.com/docs/admin/templates/extending-templates/docker-in-workspaces)
