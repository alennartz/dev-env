# Troubleshooting

Common issues and how to fix them.

## Certificate Errors

### Symptom

```text
curl: (60) SSL certificate problem: unable to get local issuer certificate
```

Or in Node.js:

```text
Error: unable to verify the first certificate
```

### Cause

The sandbox hasn't imported the proxy's CA certificate.

### Solution

1. Check if CA cert exists:

```bash
ls -la /etc/squid/ssl/
```

2. If missing, the proxy may not have started properly. Check proxy logs:

```bash
docker compose -f .devcontainer/docker-compose.yml logs proxy
```

3. The CA trust script runs automatically as the container entrypoint. If it failed, restart the container:

```bash
docker compose -f .devcontainer/docker-compose.yml restart sandbox
```

4. For Node.js specifically, ensure the env var is set:

```bash
export NODE_EXTRA_CA_CERTS=/etc/squid/ssl/squid-ca-cert.pem
```

## Connection Refused

### Symptom

```text
curl: (7) Failed to connect to example.com port 443: Connection refused
```

### Cause

Domain is not in the whitelist, or proxy isn't running.

### Solution

1. Check if proxy is running:

```bash
docker compose -f .devcontainer/docker-compose.yml ps
```

2. Check proxy logs for denied requests:

```bash
docker compose -f .devcontainer/docker-compose.yml logs proxy | grep DENIED
```

3. If domain should be allowed, add it to `whitelist.txt` and rebuild:

```bash
docker compose -f .devcontainer/docker-compose.yml build proxy
docker compose -f .devcontainer/docker-compose.yml up -d
```

## Proxy Not Starting

### Symptom

Sandbox fails to start with "depends_on condition failed" or proxy container keeps restarting.

### Cause

Proxy healthcheck failing, usually due to squid configuration error.

### Solution

1. Check proxy logs:

```bash
docker compose -f .devcontainer/docker-compose.yml logs proxy
```

2. Common issues:
   - Missing SSL directory permissions
   - Invalid squid.conf syntax
   - Port already in use

3. Try rebuilding from scratch:

```bash
docker compose -f .devcontainer/docker-compose.yml down -v  # Remove volumes too
docker compose -f .devcontainer/docker-compose.yml build --no-cache
docker compose -f .devcontainer/docker-compose.yml up -d
```

## Tools Not Working

### Git

If `git clone` fails:

```bash
# Check if github.com is accessible
curl -v https://github.com

# Check if github.com is in your whitelist
cat /etc/squid/whitelist.txt | grep github
```

Traffic is transparently intercepted via iptables, so explicit proxy config should not be needed.

### npm

If `npm install` fails:

```bash
# Check npm registry access
curl -v https://registry.npmjs.org

# Check npm config
npm config list
```

### pip

If `pip install` fails:

```bash
# Check PyPI access
curl -v https://pypi.org

# pip usually respects system CA store
pip install --trusted-host pypi.org <package>
```

## Viewing Proxy Logs

### Real-time logs

```bash
docker compose -f .devcontainer/docker-compose.yml logs -f proxy
```

### Access log (what's being requested)

```bash
docker compose -f .devcontainer/docker-compose.yml exec proxy tail -f /var/log/squid/access.log
```

### Cache log (squid errors)

```bash
docker compose -f .devcontainer/docker-compose.yml exec proxy tail -f /var/log/squid/cache.log
```

## Container Won't Start in VS Code

### Symptom

"Reopen in Container" fails or hangs.

### Solution

1. Try from command line first:

```bash
docker compose -f .devcontainer/docker-compose.yml up
```

2. Check Docker is running:

```bash
docker ps
```

3. Check for port conflicts:

```bash
docker compose -f .devcontainer/docker-compose.yml down
docker system prune  # Clean up old containers
```

4. Check VS Code Dev Containers extension output:
   - View → Output → Select "Dev Containers" from dropdown

## Slow Performance

### Cause

First request to each domain is slower due to SSL certificate generation.

### Solution

This is normal. Subsequent requests to the same domain are faster (certificates are cached).

If consistently slow:

1. Check proxy memory usage
2. Consider increasing `dynamic_cert_mem_cache_size` in squid.conf

## Reset Everything

Nuclear option - start fresh:

```bash
# Stop and remove containers
docker compose -f .devcontainer/docker-compose.yml down -v

# Remove images
docker rmi $(docker images -q '*sandbox*')

# Rebuild
docker compose -f .devcontainer/docker-compose.yml build --no-cache
docker compose -f .devcontainer/docker-compose.yml up -d
```
