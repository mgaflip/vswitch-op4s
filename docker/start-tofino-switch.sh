#!/bin/bash
# Start tofino-model and bf_switchd for a given P4 program,
# with a small, configurable number of switch ports.
#
# Configurable through environment variables (docker run -e ...):
#   P4_PROG     P4 program name                         (default: tna_counter)
#   P4_ARCH     tofino | tofino2                        (default: tofino)
#   DEV_PORTS   switch device ports to expose, space-separated
#                                                       (default: "0 1 2 3")
#   CPU_VETH    1 = also create veth250/veth251 for the CPU port (default: 1)
#   CPU_PORT    device port of the Ethernet CPU port    (default: 64, Tofino 1)
#   MODEL_WAIT  seconds to wait for tofino-model        (default: 5)
#   LOG_DIR     directory for logs and ports.json       (default: /var/log/tofino)
#
# Device ports on Tofino 1 follow pipe*128 + local port (pipe 0: 0.., pipe 1: 128..,
# pipe 2: 256.., pipe 3: 384..).
# Each device port N in DEV_PORTS gets its own veth pair (vethX <-> vethX+1).
# The model attaches to the first one; use the second one to send/capture traffic.
# Requires docker run --privileged or --cap-add NET_ADMIN.

set -euo pipefail

SDE="${SDE:-/home/open-p4studio}"
P4_PROG="${P4_PROG:-tna_counter}"
P4_ARCH="${P4_ARCH:-tofino}"
DEV_PORTS="${DEV_PORTS:-0 1 2 3}"
CPU_VETH="${CPU_VETH:-1}"
CPU_PORT="${CPU_PORT:-64}"
MODEL_WAIT="${MODEL_WAIT:-5}"
LOG_DIR="${LOG_DIR:-/var/log/tofino}"
PORTS_JSON="$LOG_DIR/ports.json"
MODEL_PID=""

mkdir -p "$LOG_DIR"
echo "SDE=$SDE  program=$P4_PROG  arch=$P4_ARCH  ports=[$DEV_PORTS]"

# Create one veth pair and configure it the way tofino-model expects
create_veth_pair() {
    local a="$1" b="$2"
    if ! ip link show "$a" > /dev/null 2>&1; then
        ip link add name "$a" type veth peer name "$b"
    fi
    for intf in "$a" "$b"; do
        ip link set dev "$intf" up
        ip link set dev "$intf" mtu 10240
        sysctl -q -w "net.ipv6.conf.$intf.disable_ipv6=1" || true
        # Disable offloads so the model sees real, unmodified packets
        ethtool -K "$intf" tx off rx off tso off gso off gro off > /dev/null 2>&1 || true
    done
}

# Create the veth pairs and build ports.json (device port -> veth mapping)
idx=0
entries=()
for port in $DEV_PORTS; do
    v1="veth$((idx * 2))"
    v2="veth$((idx * 2 + 1))"
    create_veth_pair "$v1" "$v2"
    entries+=("    { \"device_port\": $port, \"veth1\": $((idx * 2)), \"veth2\": $((idx * 2 + 1)) }")
    echo "  device port $port -> $v1 (model) / $v2 (traffic)"
    idx=$((idx + 1))
done

if [ "$CPU_VETH" = "1" ]; then
    create_veth_pair veth250 veth251
    entries+=("    { \"device_port\": $CPU_PORT, \"veth1\": 250, \"veth2\": 251 }")
    echo "  CPU port $CPU_PORT -> veth250 (model) / veth251 (traffic)"
fi

{
    echo "{"
    echo "  \"PortToVeth\": ["
    (IFS=$'\n'; echo "${entries[*]}" | sed '$!s/$/,/')
    echo "  ]"
    echo "}"
} > "$PORTS_JSON"

# Make sure tofino-model is stopped when bf_switchd exits or the container stops
cleanup() {
    if [ -n "$MODEL_PID" ]; then
        kill "$MODEL_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# Start tofino-model in the background with our port mapping, logging to a file
"$SDE/run_tofino_model.sh" -p "$P4_PROG" --arch "$P4_ARCH" -f "$PORTS_JSON" \
    > "$LOG_DIR/tofino_model.log" 2>&1 &
MODEL_PID=$!

# Give the model time to come up before bf_switchd connects to it
sleep "$MODEL_WAIT"
if ! kill -0 "$MODEL_PID" 2>/dev/null; then
    echo "ERROR: tofino-model exited, see $LOG_DIR/tofino_model.log"
    exit 1
fi

# Start bf_switchd in the foreground (opens the bfshell prompt: run the container with -it)
"$SDE/run_switchd.sh" -p "$P4_PROG" --arch "$P4_ARCH"
