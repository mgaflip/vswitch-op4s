#!/usr/bin/bash
# Copyright RSTI-UPM
# SPDX-License-Identifier: Apache-2.0
#
# List the Open P4 Studio virtual switch containers with their configuration:
# container ID, name, status, IP address(es), P4 program, architecture, ports and gRPC endpoint.
#
# Usage: ./list-vswitch-op4s-containers.sh [-a]
#   -a   also show stopped containers

set -euo pipefail

MODEL_NAME=vswitch-op4s

PS_ARGS=()
if [ "${1:-}" = "-a" ]; then
    PS_ARGS=(-a)
fi

# Containers created from any tag of the vswitch-op4s image
mapfile -t CONTAINERS < <(
    docker ps "${PS_ARGS[@]}" --format '{{.Names}} {{.Image}}' \
        | awk -v img="$MODEL_NAME" '$2 == img || index($2, img ":") == 1 { print $1 }'
)

if [ ${#CONTAINERS[@]} -eq 0 ]; then
    echo "No ${MODEL_NAME} containers found."
    exit 0
fi

# Read one environment variable from a container's configuration
get_env() {
    local env_list="$1" var="$2"
    echo "$env_list" | sed -n "s/^${var}=//p" | head -1
}

FMT="%-13s %-20s %-10s %-16s %-18s %-8s %-14s %-20s %s\n"
printf "$FMT" "CID" "NAME" "STATUS" "IP" "PROGRAM" "ARCH" "PORTS" "HOST gRPC" "IMAGE"

for name in "${CONTAINERS[@]}"; do
    cid=$(docker inspect -f '{{.Id}}' "$name" | cut -c1-12)
    status=$(docker inspect -f '{{.State.Status}}' "$name")
    image=$(docker inspect -f '{{.Config.Image}}' "$name")
    ips=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$name" | xargs)
    env_list=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$name")

    prog=$(get_env "$env_list" P4_PROG)
    arch=$(get_env "$env_list" P4_ARCH)
    ports=$(get_env "$env_list" DEV_PORTS)
    host_grpc=$(docker port "$name" 50052 2> /dev/null | head -1 || true)

    printf "$FMT" \
        "$cid" "$name" "$status" "${ips:--}" "${prog:--}" "${arch:--}" \
        "${ports:--}" "${host_grpc:--}" "$image"
done
