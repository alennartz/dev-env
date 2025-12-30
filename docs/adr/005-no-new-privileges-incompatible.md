# ADR-005: no-new-privileges Is Incompatible with Podman

## Status

Accepted

## Context

The `no-new-privileges` security option is a Linux kernel feature that prevents processes from gaining new privileges through setuid/setgid binaries or file capabilities. It's generally recommended for container security.

We investigated whether this option could be enabled for the Podman-enabled sandbox variant.

## Decision

We cannot use `no-new-privileges` with Podman. This is an unavoidable technical limitation.

### Why It Fails

Rootless Podman requires the setuid `newuidmap` binary to set up user namespace UID mappings:

```
Container UID 0     → Host UID 1000 (developer)
Container UIDs 1-65535 → Host UIDs 100000-165535 (subordinate range)
```

The `newuidmap` binary is setuid root because writing to `/proc/[pid]/uid_map` requires elevated privileges that the unprivileged `developer` user doesn't have.

With `no-new-privileges:true`:

```
Error: cannot set up namespace using "/usr/bin/newuidmap": exit status 1
newuidmap: write to uid_map failed: Operation not permitted
```

The kernel prevents `newuidmap` from gaining the privileges it needs.

### This Is Fundamental

This isn't a configuration issue or a Podman bug. It's how Linux user namespaces work:

1. Unprivileged users can create user namespaces
2. But writing UID mappings for subordinate ranges requires `CAP_SETUID` in the parent namespace
3. The setuid `newuidmap` helper provides this capability
4. `no-new-privileges` blocks setuid binaries from working

## Consequences

### Positive

- Clear understanding of the limitation
- No time spent trying to work around it

### Negative

- Cannot use this recommended security hardening
- Setuid binaries (`newuidmap`, `newgidmap`) remain functional in the container
- Slightly increased attack surface

### Neutral

- This affects only the Podman-enabled variant
- The base sandbox image doesn't need Podman and could use `no-new-privileges`
- Other security mitigations (custom seccomp, capability dropping) partially compensate

## References

- [Linux kernel no_new_privs](https://www.kernel.org/doc/Documentation/prctl/no_new_privs.txt)
- [Podman rootless documentation](https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md)
- [newuidmap man page](https://man7.org/linux/man-pages/man1/newuidmap.1.html)
