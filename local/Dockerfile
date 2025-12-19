# Full development sandbox - extends base with additional runtimes
# This is a personal/opinionated setup, not published to GHCR

FROM claude-sandbox-base:latest

USER root

# ============================================
# ADDITIONAL SYSTEM PACKAGES
# ============================================
RUN apt-get update && apt-get install -y \
    # Additional core tools
    unzip sudo \
    # Build essentials
    build-essential pkg-config libssl-dev \
    # Debugging/profiling
    gdb strace htop \
    # Search tools
    fzf fd-find \
    # Python
    python3 python3-pip python3-venv pipx \
    && rm -rf /var/lib/apt/lists/*

# Symlink for fd (different name in Debian)
RUN ln -s /usr/bin/fdfind /usr/bin/fd 2>/dev/null || true

# Add sudo for developer (local dev only - NOT in published base)
RUN echo "developer ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# ============================================
# .NET SDK (latest LTS)
# ============================================
RUN curl -sSL https://dot.net/v1/dotnet-install.sh | bash /dev/stdin --channel LTS --install-dir /usr/share/dotnet && \
    ln -s /usr/share/dotnet/dotnet /usr/bin/dotnet
ENV DOTNET_ROOT=/usr/share/dotnet
ENV PATH="${PATH}:/usr/share/dotnet"

# ============================================
# GO (latest stable)
# ============================================
RUN curl -sSL "https://go.dev/dl/$(curl -sSL 'https://go.dev/VERSION?m=text' | head -1).linux-amd64.tar.gz" | tar -C /usr/local -xz
ENV PATH="${PATH}:/usr/local/go/bin"

# ============================================
# YQ (YAML processor)
# ============================================
RUN curl -sSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /usr/bin/yq && \
    chmod +x /usr/bin/yq

# ============================================
# RUST (latest stable) - installed as developer user
# ============================================
ENV RUSTUP_HOME=/home/developer/.rustup
ENV CARGO_HOME=/home/developer/.cargo
ENV PATH="${PATH}:/home/developer/.cargo/bin"
RUN gosu developer sh -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path'

# ============================================
# PYTHON TOOLS (as developer user)
# ============================================
RUN gosu developer pipx install poetry && \
    gosu developer pipx install ruff
ENV PATH="${PATH}:/home/developer/.local/bin"

# ============================================
# CLAUDE CONTEXT FILE
# ============================================
COPY CLAUDE.md /etc/claude-context/

# ============================================
# USER SETUP
# ============================================
# Note: No USER directive - entrypoint runs as root to install CA cert,
# then drops privileges to developer via gosu (inherited from base image)
WORKDIR /home/developer

# User-level paths (run as root, set ownership)
RUN mkdir -p /home/developer/go/bin /home/developer/.claude && \
    chown -R developer:developer /home/developer/go /home/developer/.claude
ENV GOPATH=/home/developer/go
ENV PATH="${PATH}:/home/developer/go/bin"

# Inform Claude CLI about context file
RUN echo 'export CLAUDE_CONTEXT_FILE=/etc/claude-context/CLAUDE.md' >> /home/developer/.bashrc

CMD ["/bin/bash"]
