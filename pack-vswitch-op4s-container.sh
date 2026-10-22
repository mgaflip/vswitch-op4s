#!/usr/bin/bash
# Copyright RSTI-UPM
# SPDX-License-Identifier: Apache-2.0
#
# Build a distributable package with the vswitch-op4s Docker image and the
# scripts needed to start, list, stop and rebuild the virtual switches.
#
# Usage: ./pack-vswitch-op4s-container.sh [-v TAG] [--no-image] [--with-sources]
#   -v, --version TAG   image tag to package               (default: latest)
#   --no-image          do not include the saved Docker image (build files only)
#   --with-sources      also include docker/open-p4studio.tgz (large, ~650 MB)
#
# Result: vswitch-op4s-<TAG>.tgz in this directory. To use it elsewhere:
#   tar xzf vswitch-op4s-<TAG>.tgz && cd vswitch-op4s && ./start-vswitch-op4s-container.sh

set -euo pipefail

HOME_DIR=$( cd "$(dirname "${BASH_SOURCE[0]}")" > /dev/null 2>&1 && pwd )
cd "$HOME_DIR"

MODEL_NAME=vswitch-op4s
MODEL_DESC="Open P4 Studio Virtual Switch Docker Image"
MODEL_VERSION=${MODEL_VERSION:-latest}

DKDIR=docker
IMGDIR=images

# Scripts for the end user (run time) and for rebuilding the image
RUN_SCRIPTS="start-vswitch-op4s-container.sh list-vswitch-op4s-containers.sh kill-vswitch-op4s-containers.sh link-vswitch-op4s.sh configure-vswitch-op4s.py"
BUILD_SCRIPTS="build-vswitch-op4s-container.sh"
DOCS="README.md"

WITH_IMAGE=1
WITH_SOURCES=0

while [ $# -gt 0 ]; do
    case "$1" in
        -v|--version)   MODEL_VERSION="$2"; shift 2 ;;
        --no-image)     WITH_IMAGE=0; shift ;;
        --with-sources) WITH_SOURCES=1; shift ;;
        -h|--help)      sed -n '5,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)              echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

MODEL_IMAGE=${MODEL_NAME}:${MODEL_VERSION}
IMG_FILE=${MODEL_NAME}-${MODEL_VERSION}-docker.tar.gz   # name expected by start script
PACKAGE_DIR=${MODEL_NAME}
PACKAGE_TAR=${MODEL_NAME}-${MODEL_VERSION}.tgz

echo "Generating package ${PACKAGE_TAR}"
echo "(${MODEL_DESC})"

# Work in a temporary directory so a failed run leaves nothing behind
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PKG="$WORK/$PACKAGE_DIR"
mkdir -p "$PKG/$DKDIR" "$PKG/$IMGDIR"

# ---- Scripts and docs ----
for f in $RUN_SCRIPTS $BUILD_SCRIPTS $DOCS; do
    if [ -f "$f" ]; then
        cp -p "$f" "$PKG/"
    else
        echo "WARNING: $f not found, skipping" >&2
    fi
done

# ---- Docker build files (Dockerfile, entrypoint, profile, .dockerignore) ----
# The open-p4studio sources are excluded unless --with-sources is given
for f in "$DKDIR"/* "$DKDIR"/.dockerignore; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in
        open-p4studio)     continue ;;   # unpacked sources: never packaged
        open-p4studio.tgz) [ "$WITH_SOURCES" = "1" ] || continue ;;
    esac
    cp -rp "$f" "$PKG/$DKDIR/"
done

# ---- Examples (without compiled output) ----
if [ -d examples ]; then
    cp -rp examples "$PKG/"
    find "$PKG/examples" -type d -name build -prune -exec rm -rf {} +
fi

# ---- Optional helper scripts used by the build script ----
for d in op4s-u24.04 old-op4s-u24.04; do
    if [ -d "$d" ]; then
        cp -rp "$d" "$PKG/"
    fi
done

# ---- Docker image ----
if [ "$WITH_IMAGE" = "1" ]; then
    if [ -z "$(docker images -q "$MODEL_IMAGE" 2> /dev/null)" ]; then
        echo "ERROR: image $MODEL_IMAGE not found. Build it first or use --no-image." >&2
        exit 1
    fi
    echo "Saving image ${MODEL_IMAGE} (this may take a while)"
    docker save "$MODEL_IMAGE" | gzip > "$PKG/$IMGDIR/$IMG_FILE"
    # Keep a local copy too, so start-vswitch-op4s-container.sh can load it here
    mkdir -p "$IMGDIR"
    cp -p "$PKG/$IMGDIR/$IMG_FILE" "$IMGDIR/"
fi

# ---- Create the tarball ----
rm -f "$PACKAGE_TAR"
tar czf "$PACKAGE_TAR" -C "$WORK" "$PACKAGE_DIR"

echo "Package ${PACKAGE_TAR} generated ($(du -h "$PACKAGE_TAR" | cut -f1))"
echo "Contents:"
tar tzf "$PACKAGE_TAR" | sed 's/^/  /'
