# De-risk Plan: Podman Inside Claude Sandbox

> **Status: COMPLETED** - See [podman-derisk-results.md](./podman-derisk-results.md) for full results.
> All 5 phases passed. Podman is viable with security trade-offs documented.

## Goal
Validate Podman-in-sandbox feasibility with minimal investment before committing to implementation.

## Risk Priority (Fail-Fast Order)

### Phase 1: WSL2 User Namespace Nesting (HIGHEST RISK)
**Risk**: WSL2's modified kernel may block nested user namespaces entirely.

**Test**: Manual validation in current sandbox container
```bash
# From host, exec into running sandbox
docker exec -it <sandbox-container> /bin/bash

# Test if user namespaces work at all
unshare --user --map-root-user echo "user ns works"

# Check kernel support
cat /proc/sys/kernel/unprivileged_userns_clone  # Should be 1
cat /proc/sys/user/max_user_namespaces          # Should be > 0
```

**Blocker if**: User namespace creation fails. Would need to explore privileged alternatives or abandon DinD approach.

---

### Phase 2: Rootless Podman Execution (HIGH RISK - HARD REQUIREMENT)
**Risk**: Rootless Podman may require `--privileged` or capabilities that break security model.

**Why rootless is required**:
- Current security model drops to `developer` user via `gosu` - no root process remains
- Rootful Podman would require rethinking entire security architecture
- Rootless aligns with principle of least privilege

**Test**: Install Podman, test ROOTLESS with incremental capabilities
```bash
# In sandbox container (as root before gosu drop)
apt-get update && apt-get install -y podman fuse-overlayfs uidmap slirp4netns

# Switch to developer user for ALL tests (rootless requirement)
su - developer

# Test 1: No extra capabilities (expect failure, establishes baseline)
podman run --rm alpine echo hello

# Test 2: Add only /dev/fuse
# (requires docker-compose change: devices: ["/dev/fuse:/dev/fuse"])
podman run --rm alpine echo hello

# Test 3: Add fuse + SYS_ADMIN cap
# (requires: cap_add: [SYS_ADMIN])
podman run --rm alpine echo hello
```

**Document**: Minimum capability set that works for ROOTLESS. Compare against security requirements.

**Blocker if**:
- Rootless doesn't work at all → STOP, evaluate alternatives (nerdctl, abandon DinD)
- Requires `--privileged` → STOP, unacceptable security trade-off

---

### Phase 3: Storage Driver Compatibility (MEDIUM RISK)
**Risk**: Overlay-on-overlay may fail; fuse-overlayfs may have performance issues.

**Test**: Check what storage driver Podman selects and if it works
```bash
# Check Podman's storage driver selection
podman info | grep -A5 "graphDriverName"

# Test with explicit drivers
podman --storage-driver=overlay run --rm alpine echo hello
podman --storage-driver=fuse-overlayfs run --rm alpine echo hello

# If both fail, test vfs (slow but always works)
podman --storage-driver=vfs run --rm alpine echo hello
```

**Acceptable outcomes**: Native overlay (best), fuse-overlayfs (acceptable), vfs (fallback).

---

### Phase 4: Network Isolation Compatibility (MEDIUM RISK)
**Risk**: Podman's networking may conflict with proxy iptables rules or bypass isolation.

**Test**: Verify child containers respect network isolation
```bash
# Inside Podman container, test network access
podman run --rm alpine wget -q -O- https://api.anthropic.com  # Should work (whitelisted)
podman run --rm alpine wget -q -O- https://example.com        # Should fail (not whitelisted)

# Test volume mounts are from sandbox FS (critical requirement)
echo "sandbox-file" > /tmp/test.txt
podman run --rm -v /tmp/test.txt:/test.txt alpine cat /test.txt  # Should show "sandbox-file"
```

**Blocker if**: Child containers can bypass proxy or mount host filesystem.

---

### Phase 5: Compose Compatibility (LOW RISK)
**Risk**: `podman-compose` or `podman compose` may have gaps vs Docker Compose.

**Test**: Run a multi-container compose file
```bash
# Install podman-compose
pip3 install podman-compose

# Test with a simple compose file
cat > /tmp/test-compose.yml << 'EOF'
version: "3"
services:
  web:
    image: alpine
    command: echo "web service"
  db:
    image: alpine
    command: echo "db service"
EOF

# Test podman-compose
podman-compose -f /tmp/test-compose.yml up

# Test native podman compose (v4.7+)
podman compose -f /tmp/test-compose.yml up
```

**Check for**:
- Service startup order (depends_on)
- Volume mounts between services
- Network connectivity between services
- Environment variable passing

**Acceptable outcomes**: Either `podman-compose` or native `podman compose` works. Document which.

---

## Test Infrastructure

### Quick Test Script
Create `scripts/test-podman-dind.sh` for repeatable testing:
```bash
#!/bin/bash
set -e
echo "=== Phase 1: User Namespace ==="
# ... tests

echo "=== Phase 2: Podman Execution ==="
# ... tests

# etc.
```

### Modified docker-compose for testing
Create `.devcontainer/docker-compose.podman-test.yml`:
- Add `devices: ["/dev/fuse:/dev/fuse"]`
- Add `cap_add: [SYS_ADMIN, MKNOD]` (test incrementally)
- Add `security_opt: [label:disable]`

---

## Decision Gates

| Phase | Pass Criteria | Fail Action |
|-------|--------------|-------------|
| 1 | User namespaces work in WSL2 | **BLOCKER** - abandon DinD approach |
| 2 | Rootless works without `--privileged` | **BLOCKER** - try nerdctl, else abandon |
| 3 | overlay or fuse-overlayfs works | Use vfs fallback (slower but acceptable) |
| 4 | Network isolation preserved | Investigate Podman network modes |
| 5 | podman-compose or native compose works | Document limitations, manual workarounds |

---

## Files to Modify (if all phases pass)

1. `images/base/Dockerfile` - Add Podman + fuse-overlayfs packages
2. `.devcontainer/docker-compose.yml` - Add required caps/devices
3. `template/docker-compose.yml` - Same changes for template
4. `images/base/trust-proxy-ca.sh` - Configure Podman storage if needed
5. `docs/docker-in-docker-alternatives.md` - Update with findings

---

## Out of Scope (for now)
- Building images inside sandbox (Kaniko/Buildah) - test separately if needed
- nerdctl as Podman alternative - test only if Podman fails completely
- Podman machine/VM mode - not applicable to nested container scenario
