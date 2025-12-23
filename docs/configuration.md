# Configuration

Customize the sandbox for your needs.

## Adding Whitelisted Domains

The published proxy image includes only `.anthropic.com` by default. The template includes additional common domains (GitHub, npm). To add more domains:

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

By default, the following data persists across container restarts:

- **Workspace**: Your project files are mounted from the host
- **Claude config**: `~/.claude/` and `~/.claude.json` are mounted from your host
- **SSL certificates**: Stored in the `squid-ssl` Docker volume

To persist additional data (e.g., npm cache), add named volumes:

```yaml
# .devcontainer/docker-compose.yml
services:
  sandbox:
    # ... other config ...
    volumes:
      - npm-cache:/home/developer/.npm

volumes:
  squid-ssl:
  npm-cache:
```

## Custom Sandbox Image

To add tools or runtimes, create your own Dockerfile:

```dockerfile
# .devcontainer/Dockerfile
FROM ghcr.io/alennartz/claude-sandbox-base:latest

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
