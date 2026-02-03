#!/bin/bash
# Helper script to transfer images between Podman and K3s containerd
#
# Usage:
#   k8s-wrapper.sh import <image:tag>  - Import Podman image into K3s
#   k8s-wrapper.sh list                - List K3s containerd images
#   k8s-wrapper.sh help                - Show this help

set -e

case "$1" in
    import)
        if [ -z "$2" ]; then
            echo "Usage: k8s-wrapper.sh import <image:tag>"
            echo "Example: k8s-wrapper.sh import myapp:latest"
            exit 1
        fi
        IMAGE="$2"
        echo "Exporting image from Podman: $IMAGE"
        # NOTE: k3s ctr requires root. This script must be run as root or via
        # docker exec without gosu: docker exec <container> k8s-wrapper.sh import <image>
        podman save "$IMAGE" | k3s ctr images import -
        echo "Image imported to K3s containerd"
        echo ""
        echo "To use in Kubernetes:"
        echo "  kubectl run myapp --image=$IMAGE --image-pull-policy=Never"
        ;;

    list)
        echo "K3s containerd images:"
        # NOTE: k3s ctr requires root
        k3s ctr images ls
        ;;

    help|--help|-h)
        echo "K8s wrapper - transfer images between Podman and K3s"
        echo ""
        echo "Usage:"
        echo "  k8s-wrapper.sh import <image:tag>  - Import Podman image into K3s"
        echo "  k8s-wrapper.sh list                - List K3s containerd images"
        echo "  k8s-wrapper.sh help                - Show this help"
        echo ""
        echo "Workflow:"
        echo "  1. Build with Podman:    podman build -t myapp:latest ."
        echo "  2. Import to K3s:        k8s-wrapper.sh import myapp:latest"
        echo "  3. Deploy to Kubernetes: kubectl run myapp --image=myapp:latest --image-pull-policy=Never"
        ;;

    *)
        echo "Unknown command: $1"
        echo "Run 'k8s-wrapper.sh help' for usage"
        exit 1
        ;;
esac
