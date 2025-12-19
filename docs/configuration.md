# Configuration

Customize the sandbox for your needs.

## Adding Whitelisted Domains

The default whitelist includes Claude API, GitHub, and common package managers. To add more domains:

### Option 1: Fork and Modify

1. Fork this repository
2. Edit `whitelist.txt`:

```text
# Your custom domains
.example.com
api.yourservice.com
```

3. Rebuild: `docker compose -f .devcontainer/docker-compose.yml build proxy`

### Option 2: Mount Custom Whitelist

Create a local whitelist file and mount it:

```yaml
# .devcontainer/docker-compose.yml
services:
  proxy:
    image: ghcr.io/alennartz/claude-sandbox-proxy:latest
    cap_add:
      - NET_ADMIN
    volumes:
      - squid-ssl:/etc/squid/ssl
      - ./whitelist.txt:/etc/squid/whitelist.txt:ro  # Custom whitelist
```

### Whitelist Format

```text
# Comments start with #

# Exact domain
api.example.com

# Domain and all subdomains (leading dot)
.example.com

# Multiple entries
.github.com
.githubusercontent.com
registry.npmjs.org
```

## Default Whitelisted Domains

| Category | Domains |
|----------|---------|
| Claude API | `.anthropic.com` |
| GitHub | `.github.com`, `.githubusercontent.com` |
| npm | `.npmjs.org`, `.npmjs.com` |
| Python | `.pypi.org`, `.pythonhosted.org` |
| .NET | `.nuget.org`, `.microsoft.com` |
| Go | `.golang.org`, `.go.dev` |
| Rust | `.crates.io`, `.rust-lang.org` |
| AWS | `.amazonaws.com` |
| Azure | `.azure.com`, `.azure.microsoft.com` |
| GCP | `.googleapis.com`, `.google.com` |

## Environment Variables

Pass environment variables to the sandbox:

```yaml
# .devcontainer/docker-compose.yml
services:
  sandbox:
    # ... other config ...
    environment:
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
      - MY_CUSTOM_VAR=value
```

## Persistent Data

By default, only the workspace is persistent. To persist other data:

```yaml
# .devcontainer/docker-compose.yml
services:
  sandbox:
    # ... other config ...
    volumes:
      - squid-ssl:/etc/squid/ssl:ro
      - claude-data:/home/developer/.claude  # Persist Claude config

volumes:
  squid-ssl:
  claude-data:
```

## Custom Sandbox Image

To add tools or runtimes, create your own Dockerfile:

```dockerfile
# .devcontainer/Dockerfile
FROM ghcr.io/alennartz/claude-sandbox:latest

# Add your tools
RUN apt-get update && apt-get install -y \
    your-package \
    another-package

# Or install via package managers
RUN npm install -g your-tool
RUN pip install your-python-package
```

Then reference it:

```yaml
# .devcontainer/docker-compose.yml
services:
  sandbox:
    build:
      context: .
      dockerfile: Dockerfile
    # ... rest of config ...
```

## Proxy Settings

### Squid Configuration

For advanced proxy configuration, mount a custom `squid.conf`:

```yaml
services:
  proxy:
    volumes:
      - ./squid.conf:/etc/squid/squid.conf:ro
```

### Logging

Proxy logs are available via:

```bash
docker compose -f .devcontainer/docker-compose.yml logs proxy
```

Or exec into proxy container:

```bash
docker compose -f .devcontainer/docker-compose.yml exec proxy cat /var/log/squid/access.log
```
