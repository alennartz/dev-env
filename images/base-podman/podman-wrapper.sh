#!/bin/bash
# Podman wrapper script for nested container support
#
# This wrapper injects required flags for running containers inside the sandbox:
# - --cgroups=disabled: Cgroup filesystem is read-only in nested context
# - --network=host: Inherit sandbox network (which routes through proxy)
#
# These flags are automatically added to 'run' and 'create' commands so that
# podman-compose and direct CLI usage work transparently.

set -e

if [[ "$1" == "run" || "$1" == "create" ]]; then
    cmd="$1"
    shift
    exec /usr/bin/podman.real "$cmd" --cgroups=disabled --network=host "$@"
else
    exec /usr/bin/podman.real "$@"
fi
