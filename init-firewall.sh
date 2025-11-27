#!/bin/bash
set -e

# Must run as root for iptables
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

# Flush existing rules
iptables -F OUTPUT

# Allow loopback
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established connections
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow DNS (required for domain resolution)
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# ============================================
# CLAUDE API
# ============================================
iptables -A OUTPUT -d api.anthropic.com -j ACCEPT

# ============================================
# GIT HOSTING
# ============================================
iptables -A OUTPUT -d github.com -j ACCEPT
iptables -A OUTPUT -d api.github.com -j ACCEPT
iptables -A OUTPUT -d raw.githubusercontent.com -j ACCEPT
iptables -A OUTPUT -d objects.githubusercontent.com -j ACCEPT

# ============================================
# CONTAINER REGISTRIES
# ============================================
iptables -A OUTPUT -d registry-1.docker.io -j ACCEPT
iptables -A OUTPUT -d auth.docker.io -j ACCEPT
iptables -A OUTPUT -d production.cloudflare.docker.com -j ACCEPT
iptables -A OUTPUT -d ghcr.io -j ACCEPT
iptables -A OUTPUT -d mcr.microsoft.com -j ACCEPT

# ============================================
# CLOUD PROVIDERS
# ============================================
# AWS
iptables -A OUTPUT -d amazonaws.com -j ACCEPT
iptables -A OUTPUT -d aws.amazon.com -j ACCEPT
# Azure
iptables -A OUTPUT -d azure.microsoft.com -j ACCEPT
iptables -A OUTPUT -d management.azure.com -j ACCEPT
iptables -A OUTPUT -d login.microsoftonline.com -j ACCEPT
# GCP
iptables -A OUTPUT -d googleapis.com -j ACCEPT
iptables -A OUTPUT -d cloud.google.com -j ACCEPT

# ============================================
# NODE.JS / TYPESCRIPT / REACT / VITE / MUI
# ============================================
iptables -A OUTPUT -d registry.npmjs.org -j ACCEPT
iptables -A OUTPUT -d nodejs.org -j ACCEPT
iptables -A OUTPUT -d typescriptlang.org -j ACCEPT
iptables -A OUTPUT -d react.dev -j ACCEPT
iptables -A OUTPUT -d vitejs.dev -j ACCEPT
iptables -A OUTPUT -d mui.com -j ACCEPT

# ============================================
# PYTHON
# ============================================
iptables -A OUTPUT -d pypi.org -j ACCEPT
iptables -A OUTPUT -d files.pythonhosted.org -j ACCEPT
iptables -A OUTPUT -d python.org -j ACCEPT
iptables -A OUTPUT -d docs.python.org -j ACCEPT

# ============================================
# .NET
# ============================================
iptables -A OUTPUT -d nuget.org -j ACCEPT
iptables -A OUTPUT -d api.nuget.org -j ACCEPT
iptables -A OUTPUT -d dotnet.microsoft.com -j ACCEPT
iptables -A OUTPUT -d learn.microsoft.com -j ACCEPT

# ============================================
# GO
# ============================================
iptables -A OUTPUT -d proxy.golang.org -j ACCEPT
iptables -A OUTPUT -d sum.golang.org -j ACCEPT
iptables -A OUTPUT -d go.dev -j ACCEPT
iptables -A OUTPUT -d pkg.go.dev -j ACCEPT

# ============================================
# RUST
# ============================================
iptables -A OUTPUT -d crates.io -j ACCEPT
iptables -A OUTPUT -d static.crates.io -j ACCEPT
iptables -A OUTPUT -d doc.rust-lang.org -j ACCEPT
iptables -A OUTPUT -d rust-lang.org -j ACCEPT
iptables -A OUTPUT -d docs.rs -j ACCEPT

# ============================================
# DEFAULT DENY
# ============================================
iptables -A OUTPUT -j REJECT

echo "Firewall initialized. Outbound restricted to whitelisted domains."
