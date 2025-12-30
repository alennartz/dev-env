# Podman-enabled sandbox image for Docker-in-Docker functionality
# Extends the base sandbox with rootless Podman and Docker CLI compatibility
#
# SECURITY NOTE: This image requires CAP_SYS_ADMIN and custom seccomp profile.
# Use the base image instead if you don't need container functionality.
# See docs/adr/006-adopt-podman-rootless.md for security trade-off analysis.

ARG BASE_IMAGE=claude-sandbox-base:latest
FROM ${BASE_IMAGE}

# ============================================
# PODMAN AND CONTAINER RUNTIME
# ============================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    podman \
    crun \
    fuse-overlayfs \
    uidmap \
    slirp4netns \
    python3-pip \
    && pip3 install --break-system-packages podman-compose \
    && rm -rf /var/lib/apt/lists/*

# ============================================
# PODMAN WRAPPER SCRIPT
# ============================================
# Wrapper injects --cgroups=disabled --network=host for run/create commands
# This is required for nested containers without cgroup/network privileges
COPY podman-wrapper.sh /usr/local/bin/podman-wrapper
RUN chmod 755 /usr/local/bin/podman-wrapper \
    && mv /usr/bin/podman /usr/bin/podman.real \
    && ln -s /usr/local/bin/podman-wrapper /usr/bin/podman

# ============================================
# PODMAN CONFIGURATION
# ============================================
COPY containers.conf /etc/containers/containers.conf
RUN chmod 644 /etc/containers/containers.conf

# ============================================
# DOCKER SYMLINK
# ============================================
# Create docker symlink to podman wrapper for Docker CLI compatibility
# Using symlink instead of alias so it works in non-interactive shells
RUN ln -s /usr/bin/podman /usr/local/bin/docker

# ============================================
# SUBUID/SUBGID FOR ROOTLESS PODMAN
# ============================================
# Configure subordinate UID/GID ranges for user namespace mapping
# Remove any existing entries for developer and add a clean one
RUN sed -i '/^developer:/d' /etc/subuid /etc/subgid 2>/dev/null || true \
    && echo "developer:100000:65536" >> /etc/subuid \
    && echo "developer:100000:65536" >> /etc/subgid

# Ensure developer owns their Podman storage directory
RUN mkdir -p /home/developer/.local/share/containers \
    && chown -R developer:developer /home/developer/.local/share/containers
