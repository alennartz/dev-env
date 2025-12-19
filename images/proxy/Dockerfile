FROM alpine:3.20

RUN apk add --no-cache squid iptables openssl

COPY squid.conf /etc/squid/squid.conf
COPY whitelist.txt /etc/squid/whitelist.txt
COPY proxy-entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh && \
    mkdir -p /etc/squid/ssl /var/log/squid && \
    chown -R squid:squid /etc/squid/ssl /var/log/squid

HEALTHCHECK --interval=2s --timeout=3s --start-period=10s \
    CMD pgrep squid || exit 1

ENTRYPOINT ["/entrypoint.sh"]
