#!/usr/bin/bash
# Copyright RSTI-UPM
# SPDX-License-Identifier: Apache-2.0
#
# Build the vswitch-op4s Docker image (tofino-model + bf_switchd).
#
# Usage: ./build-vswitch-op4s-container.sh [-v TAG] [--ref REF] [--repo URL] [--refresh]
#   -v, --version TAG   image tag                                  (default: latest)
#   --ref REF           open-p4studio branch, tag or commit        (default: repo default)
#   --repo URL          open-p4studio git repository               (default: p4lang/open-p4studio)
#   --refresh           download open-p4studio again even if docker/open-p4studio.tgz exists
#
# Requirements: git, Docker with BuildKit (default in recent Docker versions),
# 16 GB+ RAM and 30-40 GB of free disk space for the build.

set -euo pipefail

HOME_DIR=$( cd "$(dirname "${BASH_SOURCE[0]}")" > /dev/null 2>&1 && pwd )
cd "$HOME_DIR"

MODEL_NAME=vswitch-op4s
MODEL_VERSION=${MODEL_VERSION:-latest}
OP4S_REPO=${OP4S_REPO:-https://github.com/p4lang/open-p4studio.git}
OP4S_REF=${OP4S_REF:-}
REFRESH=0

DKDIR=docker
SRC_TGZ=${DKDIR}/open-p4studio.tgz

while [ $# -gt 0 ]; do
    case "$1" in
        -v|--version) MODEL_VERSION="$2"; shift 2 ;;
        --ref)        OP4S_REF="$2"; shift 2 ;;
        --repo)       OP4S_REPO="$2"; shift 2 ;;
        --refresh)    REFRESH=1; shift ;;
        -h|--help)    sed -n '5,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

MODEL_IMAGE=${MODEL_NAME}:${MODEL_VERSION}

echo "Building Open P4 Studio Virtual Switch Docker Image (${MODEL_IMAGE})"

# ---- Get the open-p4studio sources (with submodules) as a tarball ----
if [ "$REFRESH" = "1" ] || [ ! -f "$SRC_TGZ" ]; then
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT

    echo "Cloning ${OP4S_REPO} ${OP4S_REF:+(${OP4S_REF})}"
    git clone "$OP4S_REPO" "$WORK/open-p4studio"
    if [ -n "$OP4S_REF" ]; then
        git -C "$WORK/open-p4studio" checkout "$OP4S_REF"
    fi
    git -C "$WORK/open-p4studio" submodule update --init --recursive

    echo "Creating ${SRC_TGZ}"
    tar czf "$SRC_TGZ" -C "$WORK" open-p4studio
else
    echo "Using existing ${SRC_TGZ} (use --refresh to download it again)"
fi

# ---- Build the image ----
DOCKER_BUILDKIT=1 docker build \
    -f "${DKDIR}/Dockerfile.vswitch-op4s" \
    -t "${MODEL_IMAGE}" \
    --label build-timestamp="$(date +%FT%T%z)" \
    --label build-machine="$(hostname)" \
    "${DKDIR}"

echo "Image ${MODEL_IMAGE} built."
