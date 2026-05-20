#!/bin/bash
# Docker container build script (for GitHub Actions)
# Supports multiple container images and OS labels

set -e

# Parse arguments
TARGET=$1
CONTAINER_IMAGE=$2
OS_LABEL=$3

if [ -z "$TARGET" ] || [ -z "$CONTAINER_IMAGE" ] || [ -z "$OS_LABEL" ]; then
    echo "Error: Missing required parameters"
    echo "Usage: $0 <target> <container-image> <os-label>"
    echo "Example: $0 x86_64-unknown-linux-musl public.ecr.aws/amazonlinux/amazonlinux:2 amazonlinux2"
    exit 1
fi

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=========================================="
echo "Docker container build"
echo "=========================================="
echo "Target architecture: ${TARGET}"
echo "Container image: ${CONTAINER_IMAGE}"
echo "OS label: ${OS_LABEL}"
echo "=========================================="

# Container name
CONTAINER_NAME="musl-cross-build-${OS_LABEL}"

# Clean up old containers
echo "Cleaning up old containers..."
docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true

# Start container
echo "Starting container..."
docker run -d \
    --name "${CONTAINER_NAME}" \
    -v "${PROJECT_ROOT}:/workspace/musl-cross" \
    -w /workspace/musl-cross \
    "${CONTAINER_IMAGE}" \
    tail -f /dev/null

# Configure yum/dnf mirror
if [[ "${CONTAINER_IMAGE}" == *"centos"* ]] || [[ "${OS_LABEL}" == "centos7" ]]; then
    echo "Configuring CentOS 7 mirror..."
    docker exec "${CONTAINER_NAME}" bash -c '
        # Update base repositories to Aliyun mirror (faster)
        sed -i -e "s|mirrorlist=|#mirrorlist=|g" \
               -e "s|#baseurl=http://mirror.centos.org|baseurl=https://mirrors.aliyun.com|g" \
               /etc/yum.repos.d/CentOS-*.repo

        # Clean cache
        yum clean all
        yum makecache
        echo "Mirror configuration completed"
    '
fi

# Execute build
echo "=========================================="
echo "Starting build..."
echo "=========================================="
docker exec "${CONTAINER_NAME}" bash -c "cd /workspace/musl-cross && ./scripts/make ${TARGET}"

# Rename output files and add OS label
echo "=========================================="
echo "Adding OS label to output files..."
echo "=========================================="
docker exec "${CONTAINER_NAME}" bash -c "
    cd /workspace/musl-cross
    if [ -f ${TARGET}.tar.xz ]; then
        mv ${TARGET}.tar.xz ${TARGET}-${OS_LABEL}.tar.xz
        mv ${TARGET}.tar.xz.sha256 ${TARGET}-${OS_LABEL}.tar.xz.sha256
        echo 'Renaming completed:'
        ls -lh ${TARGET}-${OS_LABEL}.tar.xz*
    else
        echo 'Error: Build artifact does not exist'
        exit 1
    fi
"

# Copy output files to host (if needed)
echo "=========================================="
echo "Build completed!"
echo "=========================================="
echo "Output files:"
echo "  - ${TARGET}-${OS_LABEL}.tar.xz"
echo "  - ${TARGET}-${OS_LABEL}.tar.xz.sha256"
echo "=========================================="

# Clean up container (optional, GitHub Actions will clean up automatically)
# docker rm -f "${CONTAINER_NAME}"

