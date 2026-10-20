#!/usr/bin/bash
# Copyright RSTI-UPM
# SPDX-License-Identifier: Apache-2.0
#
# Stop Open P4 Studio virtual switch containers.
#
# Usage: ./kill-vswitch-op4s-containers.sh [-f] [NAME ...]
#   (no names)  stop all vswitch-op4s containers
#   NAME ...    stop only these containers (name or ID)
#   -f          kill immediately instead of a graceful stop
#
# A graceful stop (docker stop) lets start-tofino-switch.sh shut down
# tofino-model cleanly; -f (docker kill) does not.

set -euo pipefail

MODEL_NAME=vswitch-op4s
STOP_TIMEOUT=${STOP_TIMEOUT:-10}   # seconds before docker stop falls back to kill

FORCE=0
if [ "${1:-}" = "-f" ]; then
    FORCE=1
    shift
fi

# Containers created from any tag of the vswitch-op4s image
mapfile -t ALL < <(
    docker ps --format '{{.Names}} {{.Image}}' \
        | awk -v img="$MODEL_NAME" '$2 == img || index($2, img ":") == 1 { print $1 }'
)

if [ $# -gt 0 ]; then
    TARGETS=("$@")
else
    TARGETS=("${ALL[@]}")
fi

if [ ${#TARGETS[@]} -eq 0 ]; then
    echo "No ${MODEL_NAME} containers running."
    exit 0
fi

for c in "${TARGETS[@]}"; do
    # Only touch containers that really come from the vswitch-op4s image
    name=$(docker inspect -f '{{.Name}}' "$c" 2> /dev/null | sed 's#^/##') || true
    if [ -z "$name" ] || ! printf '%s\n' "${ALL[@]}" | grep -qx "$name"; then
        echo "Skipping $c: not a running ${MODEL_NAME} container" >&2
        continue
    fi

    if [ "$FORCE" = "1" ]; then
        echo "Killing $name"
        docker kill "$name" > /dev/null
    else
        echo "Stopping $name"
        docker stop -t "$STOP_TIMEOUT" "$name" > /dev/null
    fi
done
