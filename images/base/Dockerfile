FROM debian:bookworm-slim

# ============================================
# SYSTEM PACKAGES (minimal)
# ============================================
RUN apt-get update && apt-get install -y \
    git \
    curl \
    wget \
    ca-certificates \
    gnupg \
    jq \
    ripgrep \
    gosu \
    && rm -rf /var/lib/apt/lists/*

# ============================================
# NODE.JS (required for Claude Code)
# ============================================
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# ============================================
# CREATE USER (no sudo for security)
# ============================================
RUN useradd -m -s /bin/bash developer

# ============================================
# CLAUDE CODE
# ============================================
RUN npm install -g @anthropic-ai/claude-code

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
RUN mkdir -p /home/developer/.claude && chown developer:developer /home/developer/.claude

CMD ["/bin/bash"]
