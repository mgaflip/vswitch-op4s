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
KEEP=${KEEP:-0}                          # 1 = keep the container after it stops (debugging)
HUGEPAGES_PER_SWITCH=${HUGEPAGES_PER_SWITCH:-72}  # 2 MB hugepages used by each bf_switchd (measured)
P4_BUILD=${P4_BUILD:-}                   # host dir with a compiled program (see --p4-build)

usage() {
    cat << EOF
Usage: $(basename "$0") [options] [-- extra docker run args]

Options:
  -n, --name NAME          Container name            (default: first free ${SW_PREFIX}1, ${SW_PREFIX}2, ...)
      --prefix PREFIX      Prefix for automatic names (default: ${SW_PREFIX})
  -p, --prog PROG          P4 program                (default: ${P4_PROG})
  -a, --arch ARCH          tofino | tofino2          (default: ${P4_ARCH})
      --p4-build DIR       Load your own compiled program from DIR (on the host).
                           DIR must contain <prog>.conf, bf-rt.json and pipe/;
                           use --prog to give the program name.
      --ports "P1 P2 ..."  Switch device ports       (default: "${DEV_PORTS}")
      --cpu-port N         CPU port device number    (default: ${CPU_PORT})
      --no-cpu-veth        Do not create the CPU port veth pair
      --net NETWORK        Docker network            (default: docker bridge)
      --ip ADDR            Fixed IP in that network  (needs --net with a subnet)
  -g, --grpc-port N        Also publish gRPC (50052) on host port N, to reach
                           the switch from outside the VM (0 = random port)
  -v, --version TAG        Image tag                 (default: ${MODEL_VERSION})
  -i, --interactive        Stay attached to the bfshell prompt
  -k, --keep               Keep the container after it stops, to read its logs
                           (remove it later with: docker rm NAME)
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
        --p4-build)       P4_BUILD="$2"; shift 2 ;;
        --ports)          DEV_PORTS="$2"; shift 2 ;;
        --cpu-port)       CPU_PORT="$2"; shift 2 ;;
        --no-cpu-veth)    CPU_VETH=0; shift ;;
        --net)            SW_NET="$2"; shift 2 ;;
        --ip)             SW_IP="$2"; shift 2 ;;
        -g|--grpc-port)   GRPC_PORT="$2"; shift 2 ;;
        -v|--version)     MODEL_VERSION="$2"; shift 2 ;;
        -i|--interactive) INTERACTIVE=1; shift ;;
        -k|--keep)        KEEP=1; shift ;;
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

# ---- Hugepages: bf_switchd needs free hugepages on the host for its DMA pools ----
# All switches share the host's hugepages. If there are not enough, bf_switchd fails
# with "bf_sys_dma_pool_create failed" a few seconds after starting.
HP_FREE=$(awk '/^HugePages_Free:/ { print $2 }' /proc/meminfo)
HP_TOTAL=$(awk '/^HugePages_Total:/ { print $2 }' /proc/meminfo)
# On a host with no hugepages yet, the SDE sets up its default (196) on first start
if [ "${HP_TOTAL:-0}" -gt 0 ] && [ "${HP_FREE:-0}" -lt "$HUGEPAGES_PER_SWITCH" ]; then
    RUNNING=$(docker ps --format '{{.Image}}' | grep -c "^${MODEL_NAME}" || true)
    cat >&2 << EOF
ERROR: not enough free hugepages for another switch
  free: ${HP_FREE}  total: ${HP_TOTAL}  needed per switch: ${HUGEPAGES_PER_SWITCH}  running switches: ${RUNNING}

To run N switches, the host needs about N x ${HUGEPAGES_PER_SWITCH} hugepages. For example, for 8:
  sudo sysctl -w vm.nr_hugepages=640
  echo "vm.nr_hugepages = 640" | sudo tee /etc/sysctl.d/90-vswitch-hugepages.conf
EOF
    exit 1
fi

# ---- Own P4 program: mount the build where the SDE expects installed programs ----
# The SDE looks for share/p4/targets/<arch>/<prog>.conf and share/<arch>pd/<prog>/,
# so mounting the build there lets run_tofino_model.sh / run_switchd.sh use -p <prog>.
MOUNT_ARGS=()
if [ -n "$P4_BUILD" ]; then
    [ -d "$P4_BUILD" ] || { echo "--p4-build: directory $P4_BUILD not found" >&2; exit 1; }
    P4_BUILD=$(cd "$P4_BUILD" && pwd)
    [ -f "$P4_BUILD/$P4_PROG.conf" ] || {
        echo "--p4-build: $P4_BUILD/$P4_PROG.conf not found (is --prog correct?)" >&2; exit 1; }
    SDE_SHARE=/home/open-p4studio/install/share
    MOUNT_ARGS=(
        -v "$P4_BUILD:$SDE_SHARE/${P4_ARCH}pd/$P4_PROG:ro"
        -v "$P4_BUILD/$P4_PROG.conf:$SDE_SHARE/p4/targets/$P4_ARCH/$P4_PROG.conf:ro"
    )
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

# ---- Remove the container when it stops, unless --keep ----
RM_ARGS=(--rm)
if [ "$KEEP" = "1" ]; then
    RM_ARGS=()
fi

echo "  name=${SW_NAME}  prog=${P4_PROG}  arch=${P4_ARCH}  ports=[${DEV_PORTS}]"

set -x
docker run "${RUN_MODE[@]}" "${RM_ARGS[@]}" --privileged \
    --name "${SW_NAME}" \
    --hostname "${SW_NAME}" \
    "${NET_ARGS[@]}" \
    "${MOUNT_ARGS[@]}" \
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
    if [ "$KEEP" = "1" ]; then
        echo "  kept after stop:   docker logs ${SW_NAME}; docker rm ${SW_NAME}"
    fi
fi
