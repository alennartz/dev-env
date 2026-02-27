# Minimal network jail container
# Provides: Squid proxy + iptables rules in isolated network namespace
# Host processes join this namespace via nsenter

FROM alpine:3.20

RUN apk add --no-cache \
    squid \
    iptables \
    openssl

COPY squid.conf /etc/squid/squid.conf
COPY whitelist.txt /etc/squid/whitelist.txt
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh && \
    mkdir -p /etc/squid/ssl /var/log/squid && \
    chown -R squid:squid /etc/squid/ssl /var/log/squid

# Expose ports for macOS port-mapped mode (claude-sandbox-macos.sh)
# 3127: forward proxy, 3128: HTTP intercept, 3129: HTTPS intercept
EXPOSE 3127 3128 3129

HEALTHCHECK --interval=2s --timeout=3s --start-period=10s \
    CMD pgrep squid || exit 1

ENTRYPOINT ["/entrypoint.sh"]
