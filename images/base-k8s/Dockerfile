# Kubernetes-enabled sandbox image with K3s
# Extends base-podman with single-node K3s cluster
#
# SECURITY NOTE: This image requires elevated capabilities beyond base-podman.
# See docs/adr/007-kubernetes-support.md for security analysis.

ARG BASE_IMAGE=claude-sandbox-base-podman:latest
FROM ${BASE_IMAGE}

# ============================================
# INSTALL DEPENDENCIES
# ============================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    iptables \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

# ============================================
# K3S INSTALLATION
# ============================================
# K3s version - use latest stable
ARG K3S_VERSION=v1.31.4+k3s1

# Download K3s binary
RUN curl -sfL "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s" -o /usr/local/bin/k3s \
    && chmod +x /usr/local/bin/k3s \
    # Create symlinks for kubectl, crictl, ctr
    && ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl \
    && ln -sf /usr/local/bin/k3s /usr/local/bin/crictl \
    && ln -sf /usr/local/bin/k3s /usr/local/bin/ctr

# ============================================
# K3S DATA DIRECTORIES
# ============================================
RUN mkdir -p /var/lib/rancher/k3s \
             /etc/rancher/k3s \
             /var/lib/rancher/k3s/agent/images \
             /var/log

# ============================================
# K3S CONFIGURATION
# ============================================
COPY config.yaml /etc/rancher/k3s/config.yaml

# ============================================
# KUBECONFIG FOR DEVELOPER USER
# ============================================
RUN mkdir -p /home/developer/.kube \
    && chown developer:developer /home/developer/.kube

# ============================================
# HELPER SCRIPTS
# ============================================
COPY k8s-entrypoint.sh /usr/local/bin/k8s-entrypoint.sh
COPY k8s-wrapper.sh /usr/local/bin/k8s-wrapper.sh
RUN chmod 755 /usr/local/bin/k8s-entrypoint.sh /usr/local/bin/k8s-wrapper.sh

# ============================================
# ENVIRONMENT
# ============================================
ENV KUBECONFIG=/home/developer/.kube/config
ENV CLAUDE_SANDBOX_K8S=1

# Use the K8s-specific entrypoint
ENTRYPOINT ["/bin/bash", "/usr/local/bin/k8s-entrypoint.sh"]
CMD ["sleep", "infinity"]
