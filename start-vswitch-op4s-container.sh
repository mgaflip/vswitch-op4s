#!/usr/bin/bash
# Copyright RSTI-UPM
# SPDX-License-Identifier: Apache-2.0
#
# Start an Open P4 Studio virtual switch (tofino-model + bf_switchd) in a container.
# Every option has a sensible default, so running the script with no arguments
# starts a 4-port Tofino switch running tna_counter.
#
# Examples:
#   ./start-vswitch-op4s-container.sh                     # -> sw1, then sw2, ...
#   ./start-vswitch-op4s-container.sh --name sw1 --prog tna_exact_match --ports "0 1"
#   ./start-vswitch-op4s-container.sh --name sw2 --arch tofino2 --net p4net --ip 172.30.0.12
#   ./start-vswitch-op4s-container.sh --name sw4 --grpc-port 50052   # reachable from outside the VM
#   ./start-vswitch-op4s-container.sh --name sw3 -- -v /home/rsti/p4:/p4   # extra docker args

set -euo pipefail

HOME_DIR=$( cd "$(dirname "${BASH_SOURCE[0]}")" > /dev/null 2>&1 && pwd )
IMGDIR=${HOME_DIR}/images

MODEL_DESC="Open P4 Studio Virtual Switch Docker Image"
MODEL_NAME=vswitch-op4s

# ---- Defaults (can be overridden by environment variables or options) ----
MODEL_VERSION=${MODEL_VERSION:-latest}   # image tag
SW_NAME=${SW_NAME:-}                     # container name (auto if empty)
SW_PREFIX=${SW_PREFIX:-sw}               # prefix for automatic names: sw1, sw2, ...
P4_PROG=${P4_PROG:-tna_counter}          # P4 program to load
P4_ARCH=${P4_ARCH:-tofino}               # tofino | tofino2
DEV_PORTS=${DEV_PORTS:-"0 1 2 3"}        # switch device ports
CPU_VETH=${CPU_VETH:-1}                  # 1 = create CPU port veth pair
CPU_PORT=${CPU_PORT:-64}                 # CPU port device number
GRPC_PORT=${GRPC_PORT:-}                 # publish gRPC on this host port (empty = don't publish)
SW_NET=${SW_NET:-}                       # docker network (empty = default bridge)
SW_IP=${SW_IP:-}                         # fixed IP in SW_NET (empty = automatic)
INTERACTIVE=${INTERACTIVE:-0}            # 1 = stay attached to the bfshell prompt

usage() {
    cat << EOF
Usage: $(basename "$0") [options] [-- extra docker run args]

Options:
  -n, --name NAME          Container name            (default: first free ${SW_PREFIX}1, ${SW_PREFIX}2, ...)
      --prefix PREFIX      Prefix for automatic names (default: ${SW_PREFIX})
  -p, --prog PROG          P4 program                (default: ${P4_PROG})
  -a, --arch ARCH          tofino | tofino2          (default: ${P4_ARCH})
      --ports "P1 P2 ..."  Switch device ports       (default: "${DEV_PORTS}")
      --cpu-port N         CPU port device number    (default: ${CPU_PORT})
      --no-cpu-veth        Do not create the CPU port veth pair
      --net NETWORK        Docker network            (default: docker bridge)
      --ip ADDR            Fixed IP in that network  (needs --net with a subnet)
  -g, --grpc-port N        Also publish gRPC (50052) on host port N, to reach
                           the switch from outside the VM (0 = random port)
  -v, --version TAG        Image tag                 (default: ${MODEL_VERSION})
  -i, --interactive        Stay attached to the bfshell prompt
  -h, --help               Show this help

Anything after "--" is passed unchanged to "docker run".
EOF
}

# ---- Parse options ----
EXTRA_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--name)        SW_NAME="$2"; shift 2 ;;
        --prefix)         SW_PREFIX="$2"; shift 2 ;;
        -p|--prog)        P4_PROG="$2"; shift 2 ;;
        -a|--arch)        P4_ARCH="$2"; shift 2 ;;
        --ports)          DEV_PORTS="$2"; shift 2 ;;
        --cpu-port)       CPU_PORT="$2"; shift 2 ;;
        --no-cpu-veth)    CPU_VETH=0; shift ;;
        --net)            SW_NET="$2"; shift 2 ;;
        --ip)             SW_IP="$2"; shift 2 ;;
        -g|--grpc-port)   GRPC_PORT="$2"; shift 2 ;;
        -v|--version)     MODEL_VERSION="$2"; shift 2 ;;
        -i|--interactive) INTERACTIVE=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        --)               shift; EXTRA_ARGS=("$@"); break ;;
        *)                echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

case "$P4_ARCH" in
    tofino|tofino2) ;;
    *) echo "Invalid architecture: $P4_ARCH (use tofino or tofino2)" >&2; exit 1 ;;
esac

MODEL_IMAGE=${MODEL_NAME}:${MODEL_VERSION}
DKIMG_FILE=${IMGDIR}/${MODEL_NAME}-${MODEL_VERSION}-docker.tar.gz

echo "Starting ${MODEL_DESC}"

# ---- Load the image if it is not available yet ----
if [ -n "$(docker images -q "${MODEL_IMAGE}" 2> /dev/null)" ]; then
    echo "Using image ${MODEL_IMAGE}"
else
    echo "Loading docker image ${MODEL_IMAGE} from file ${DKIMG_FILE}"
    docker load -i "${DKIMG_FILE}"
fi

# ---- Container name ----
name_in_use() {
    docker ps -a --format '{{.Names}}' | grep -qx "$1"
}

if [ -n "$SW_NAME" ]; then
    # Explicit name: it must be free
    if name_in_use "$SW_NAME"; then
        echo "A container named ${SW_NAME} already exists. Use another --name or stop it first." >&2
        exit 1
    fi
else
    # Automatic name: first free <prefix>1, <prefix>2, ...
    n=1
    while name_in_use "${SW_PREFIX}${n}"; do
        n=$((n + 1))
    done
    SW_NAME="${SW_PREFIX}${n}"
fi

# ---- Network: every container has its own IP, so all of them can use 50052 ----
NET_ARGS=()
if [ -n "$SW_NET" ]; then
    NET_ARGS+=(--network "$SW_NET")
fi
if [ -n "$SW_IP" ]; then
    if [ -z "$SW_NET" ]; then
        echo "--ip requires --net (the default bridge does not allow fixed IPs)" >&2
        exit 1
    fi
    NET_ARGS+=(--ip "$SW_IP")
fi

# ---- Optional gRPC port publishing (only needed to reach it from outside the VM) ----
PORT_ARGS=()
if [ "$GRPC_PORT" = "0" ]; then
    PORT_ARGS=(-p 50052)                 # random free host port
elif [ -n "$GRPC_PORT" ]; then
    PORT_ARGS=(-p "${GRPC_PORT}:50052")
fi

# ---- Attached (bfshell in this terminal) or detached with a TTY ----
# bf_switchd opens an interactive bfshell, so it always needs a TTY (-t) and
# an open stdin (-i); otherwise it exits right after starting.
if [ "$INTERACTIVE" = "1" ]; then
    RUN_MODE=(-it)
else
    RUN_MODE=(-dit)
fi

echo "  name=${SW_NAME}  prog=${P4_PROG}  arch=${P4_ARCH}  ports=[${DEV_PORTS}]"

set -x
docker run "${RUN_MODE[@]}" --rm --privileged \
    --name "${SW_NAME}" \
    --hostname "${SW_NAME}" \
    "${NET_ARGS[@]}" \
    "${PORT_ARGS[@]}" \
    -e P4_PROG="${P4_PROG}" \
    -e P4_ARCH="${P4_ARCH}" \
    -e DEV_PORTS="${DEV_PORTS}" \
    -e CPU_VETH="${CPU_VETH}" \
    -e CPU_PORT="${CPU_PORT}" \
    "${EXTRA_ARGS[@]}" \
    "${MODEL_IMAGE}"
{ set +x; } 2> /dev/null

if [ "$INTERACTIVE" != "1" ]; then
    echo
    echo "Switch ${SW_NAME} started in the background."
    SW_ADDR=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "${SW_NAME}" 2> /dev/null | xargs)
    echo "  gRPC (BF Runtime): ${SW_ADDR:-?}:50052"
    if [ -n "$GRPC_PORT" ]; then
        echo "  published on host: $(docker port "${SW_NAME}" 50052 2> /dev/null | head -1)"
    fi
    echo "  bfshell:           docker attach ${SW_NAME}   (detach with Ctrl-P Ctrl-Q)"
    echo "  model log:         docker exec ${SW_NAME} tail -f /var/log/tofino/tofino_model.log"
    echo "  shell:             docker exec -it ${SW_NAME} bash"
fi
