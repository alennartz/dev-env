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
USER developer
WORKDIR /home/developer
RUN mkdir -p ~/.claude

CMD ["/bin/bash"]
