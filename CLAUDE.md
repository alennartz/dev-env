# DevContainer Environment Context

You are running inside a sandboxed development container. This container is ephemeral - any changes to system configuration, installed packages, or environment will be lost when the container is rebuilt.

## Working Within the Container

You CAN and SHOULD modify the environment as needed to complete your work:
- Install system packages (apt-get install)
- Install global tools (npm -g, pip, cargo install, go install)
- Modify shell configuration
- Do whatever is needed to get the job done

Project files in ~/repos ARE persistent across container restarts.

## When Changes Should Be Permanent

After completing your work, if you installed tools or made environment changes that should persist across container rebuilds, you must ask the user to update the devcontainer configuration.

### For Simple Changes

Provide the user with the specific edit needed:

---
**To make this permanent, add the following to the Dockerfile:**

```dockerfile
RUN apt-get install -y <package>
```

Then rebuild: `cd ~/repos/dev-env && docker build -t claude-sandbox .`

---

### For Complex Changes

If multiple files need modification or the changes are non-trivial, give the user a prompt to paste into Claude Code running on the host:

---
**This requires updates to the devcontainer. Run this prompt in Claude Code on your host machine (in ~/repos/dev-env):**

```
Update the devcontainer to add support for <X>. Specifically:
- Add <package> to the Dockerfile
- Whitelist <domain> in init-firewall.sh
- <any other changes>
```

---

## Network Restrictions

Outbound network access is restricted by firewall to whitelisted domains. If a request fails unexpectedly, it may be blocked. Ask the user to whitelist the domain in init-firewall.sh.

## Authentication

Use `claude login` for account-based auth. API keys are not configured in this environment.
