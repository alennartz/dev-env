# Bug: trust-proxy-ca.sh requires sudo but base image has no sudo

## Summary

The CA trust script (`images/base/trust-proxy-ca.sh`) uses `sudo` commands, but the published base image (`images/base/Dockerfile`) does not install sudo.

## Files Involved

- `images/base/trust-proxy-ca.sh` (lines 20-21)
- `images/base/Dockerfile` (line 24-26 - creates user without sudo)

## Code

```bash
# trust-proxy-ca.sh lines 20-21
sudo cp "$CA_CERT" /usr/local/share/ca-certificates/squid-proxy-ca.crt
sudo update-ca-certificates
```

```dockerfile
# Dockerfile line 24-26
# CREATE USER (no sudo for security)
RUN useradd -m -s /bin/bash developer
```

## Impact

Users of the published `ghcr.io/alennartz/claude-sandbox-base:latest` image cannot establish trust with the proxy's SSL certificate, causing HTTPS connections to fail with certificate errors.

## Workaround

Extend the base image and add sudo:

```dockerfile
FROM ghcr.io/alennartz/claude-sandbox-base:latest
USER root
RUN apt-get update && apt-get install -y sudo && \
    echo "developer ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
USER developer
```

Or use the local image (`local/Dockerfile`) which includes sudo.

## Suggested Fix

Either:

1. **Install sudo in base image** - Add sudo to `images/base/Dockerfile` (but this contradicts the security intent of "no sudo")

2. **Rewrite trust-proxy-ca.sh to work without sudo** - Run CA installation as root during container init, then drop to developer user. For example:
   - Have the entrypoint run as root initially
   - Perform CA trust installation
   - Drop to developer user via `su` or `gosu`
   - Execute the original command

Option 2 preserves the security model while making the base image work out of the box.
