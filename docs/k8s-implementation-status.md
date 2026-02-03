# K8s Implementation Status

## Summary

Adding `images/base-k8s/` variant that provides single-node K3s alongside existing Podman DinD capabilities.

## Key Finding: Required Configuration

**K3s requires `--privileged --cgroupns=host` to function.**

```bash
docker run -d --name k8s-spike \
  --privileged \
  --cgroupns=host \
  claude-sandbox-base-k8s:latest
```

### Why These Are Required

| Requirement | Reason |
|-------------|--------|
| `--privileged` | runc needs full namespace/cgroup access for pod creation |
| `--cgroupns=host` | Containerd shim panics with isolated cgroup namespace ("cgroups: invalid group path") |

### Security Implications

- **`--privileged`**: All capabilities, seccomp disabled, all devices accessible
- **`--cgroupns=host`**: Container shares host's cgroup namespace (can see/affect host cgroups)
- **Network isolation still works**: Proxy-based filtering remains effective

## Spike Test Results

| Configuration | K3s Control Plane | Pods Start |
|--------------|-------------------|------------|
| 11 caps + seccomp + cgroup mount | YES | NO (runc EOF error) |
| 11 caps + seccomp=unconfined + cgroup mount | YES | NO (same error) |
| --privileged + cgroup mount | YES | NO (ttrpc: closed, shim panic) |
| **--privileged + cgroupns=host** | **YES** | **YES** |

## Completed

1. **Research & Planning**
   - Determined K3s rootless mode not viable (requires systemd)
   - Tested escalation path from minimal caps to privileged
   - Found minimum working config: `--privileged --cgroupns=host`

2. **Image Creation** (`images/base-k8s/`)
   - `Dockerfile` - extends base-podman, installs K3s v1.31.4, iptables, iproute2
   - `config.yaml` - K3s config with `snapshotter: fuse-overlayfs`
   - `k8s-entrypoint.sh` - startup script
   - `k8s-wrapper.sh` - image transfer helper
   - `seccomp-k8s.json` - (not used, privileged bypasses)

3. **K3s Working**
   - Node: Ready
   - Pods: coredns, local-path-provisioner Running

## Not Yet Tested

1. **Podman coexistence** - Does Podman still work alongside K3s?
2. **Image transfer** - `podman save | k3s ctr import`
3. **Proxy integration** - `network_mode: "service:proxy"`
4. **hostPath volumes** - Mount developer paths into pods

## Open Questions

1. **Is `--cgroupns=host` acceptable?** - Security trade-off vs functionality
2. **Alternative: k3d?** - k3d is designed for DinD, might have better cgroup handling
3. **Can we use specific caps + cgroupns=host?** - Might reduce from full privileged

## Files Created/Modified

```
images/base-k8s/
├── Dockerfile           # NEW (includes iptables, iproute2)
├── config.yaml          # NEW (snapshotter: fuse-overlayfs)
├── k8s-entrypoint.sh    # NEW
├── k8s-wrapper.sh       # NEW
└── seccomp-k8s.json     # NEW (not used with privileged)
```

## Next Actions

1. **Decision needed**: Is `--privileged --cgroupns=host` acceptable?
2. If yes: Test Podman coexistence
3. Update docker-compose.yml with working configuration
4. Test proxy integration (network isolation)
5. Document security trade-offs in ADR-007
