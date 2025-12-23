FROM node:22-slim

# ============================================
# SYSTEM PACKAGES (minimal)
# ============================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    jq \
    ripgrep \
    gosu \
    && rm -rf /var/lib/apt/lists/*

# ============================================
# CREATE USER (no sudo for security)
# ============================================
# Remove node user (UID 1000) from base image, create developer with UID 1000
# This ensures workspace volumes have correct ownership
RUN userdel -r node && useradd -m -s /bin/bash -u 1000 developer

# ============================================
# PROXY CA TRUST SCRIPT
# ============================================
COPY trust-proxy-ca.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/trust-proxy-ca.sh

# ============================================
# USER SETUP
# ============================================
# Note: No USER directive - entrypoint runs as root to install CA cert,
# then drops privileges to developer via gosu
WORKDIR /home/developer

# Set SHELL env var (required for Claude Code shell mode)
ENV SHELL=/bin/bash

# Add ~/.local/bin to PATH for mounted Claude binary
ENV PATH="/home/developer/.local/bin:${PATH}"

# Create mount point directories for Claude (binary and config mounted from host)
RUN mkdir -p /home/developer/.local/bin \
             /home/developer/.local/share/claude \
             /home/developer/.claude && \
    chown -R developer:developer /home/developer/.local /home/developer/.claude

CMD ["/bin/bash"]
