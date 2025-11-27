FROM debian:bookworm-slim

# ============================================
# SYSTEM PACKAGES
# ============================================
RUN apt-get update && apt-get install -y \
    # Core tools
    git curl wget unzip ca-certificates gnupg sudo \
    # Build essentials
    build-essential pkg-config libssl-dev \
    # Debugging/profiling
    gdb strace htop jq \
    # Search tools
    fzf ripgrep fd-find \
    # Python
    python3 python3-pip python3-venv pipx \
    && rm -rf /var/lib/apt/lists/*

# Symlink for fd (different name in Debian)
RUN ln -s /usr/bin/fdfind /usr/bin/fd

# ============================================
# NODE.JS (minimal, only for Claude Code)
# ============================================
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

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
# RUST (latest stable)
# ============================================
ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV PATH="${PATH}:/usr/local/cargo/bin"
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path

# ============================================
# PYTHON TOOLS
# ============================================
RUN pipx install poetry && \
    pipx install ruff
ENV PATH="${PATH}:/root/.local/bin"

# ============================================
# YQ (YAML processor)
# ============================================
RUN curl -sSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /usr/bin/yq && \
    chmod +x /usr/bin/yq

# ============================================
# CREATE USER
# ============================================
RUN useradd -m -s /bin/bash developer && \
    echo "developer ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    chown -R developer:developer /usr/local/cargo /usr/local/rustup

# ============================================
# CLAUDE CODE
# ============================================
RUN npm install -g @anthropic-ai/claude-code

# ============================================
# PROXY CA TRUST SCRIPT & CLAUDE CONTEXT
# ============================================
COPY trust-proxy-ca.sh /usr/local/bin/
COPY CLAUDE.md /etc/claude-context/
RUN chmod 755 /usr/local/bin/trust-proxy-ca.sh

# ============================================
# USER SETUP
# ============================================
USER developer
WORKDIR /home/developer

# User-level paths
RUN mkdir -p ~/go/bin ~/.local/bin
ENV GOPATH=/home/developer/go
ENV PATH="${PATH}:/home/developer/go/bin:/home/developer/.local/bin"

# Inform Claude CLI about context file
RUN echo 'export CLAUDE_CONTEXT_FILE=/etc/claude-context/CLAUDE.md' >> ~/.bashrc

CMD ["/bin/bash"]
