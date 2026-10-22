#!/usr/bin/bash
# Copyright RSTI-UPM
# SPDX-License-Identifier: Apache-2.0
#
# Build the example network and test it:
#
#   h1 (10.0.1.1) --- port 0 [sw1] port 1 --- port 1 [sw2] port 0 --- h2 (10.0.2.1)
#
# Uses tna_lpm_match, precompiled in the image (no compile step). Needs sudo (for the links and the host configuration).

set -euo pipefail

DIR=$( cd "$(dirname "${BASH_SOURCE[0]}")" > /dev/null 2>&1 && pwd )
TOP=$( cd "$DIR/../.." && pwd )
PROG=tna_lpm_match
SDE=/home/open-p4studio
HOST_IMAGE=${HOST_IMAGE:-alpine}


# Wait until bf_switchd in a switch is ready (its BF Runtime gRPC port answers)
wait_switch() {
    local sw=$1 i
    echo -n "Waiting for $sw "
    for i in $(seq 1 90); do
        if docker exec "$sw" bash -c 'exec 3<>/dev/tcp/127.0.0.1/50052' 2> /dev/null; then
            echo " ready"
            return 0
        fi
        if ! docker ps --format '{{.Names}}' | grep -qx "$sw"; then
            echo; echo "ERROR: $sw stopped. Start it with -i to see why." >&2
            exit 1
        fi
        echo -n "."
        sleep 2
    done
    echo; echo "ERROR: $sw not ready after 3 minutes" >&2
    exit 1
}

# Run a command inside a container's network namespace with the host's tools
hns() {
    local ct=$1; shift
    sudo nsenter -t "$(docker inspect -f '{{.State.Pid}}' "$ct")" -n "$@"
}

# Configure a host: MAC address, default gateway and a static ARP entry for it
# (the P4 program does not answer ARP, so the gateway MAC is configured by hand)
setup_host() {
    local h=$1 mac=$2 gw=$3 gw_mac=$4
    hns "$h" ip link set eth1 down
    hns "$h" ip link set eth1 address "$mac"
    hns "$h" ip link set eth1 mtu 1500
    hns "$h" ip link set eth1 up
    hns "$h" ip route add default via "$gw" dev eth1
    hns "$h" ip neigh replace "$gw" lladdr "$gw_mac" dev eth1 nud permanent
}

echo "== Switches"
for sw in sw1 sw2; do
    "$TOP/start-vswitch-op4s-container.sh" -n "$sw" -p "$PROG" --ports "0 1" > /dev/null
    wait_switch "$sw"
done

echo "== Hosts"
for h in h1 h2; do
    docker rm -f "$h" > /dev/null 2>&1 || true
    docker run -dit --name "$h" --hostname "$h" --network none --cap-add NET_ADMIN \
        "$HOST_IMAGE" > /dev/null
done

echo "== Links"
"$TOP/link-vswitch-op4s.sh" h1:eth1:10.0.1.1/24 sw1:0
"$TOP/link-vswitch-op4s.sh" sw1:1 sw2:1
"$TOP/link-vswitch-op4s.sh" sw2:0 h2:eth1:10.0.2.1/24

echo "== Host configuration"
setup_host h1 00:00:00:00:00:01 10.0.1.254 00:00:00:00:01:00
setup_host h2 00:00:00:00:00:02 10.0.2.254 00:00:00:00:02:00

echo "== Ports and routes"
# Preferred: p4-bfrt-manager over gRPC from this machine, with sw1.json / sw2.json.
# Fallback: bfrt_python inside each switch, with sw1.py / sw2.py.
# Set BFRT_PYTHON to the python of the virtual environment where p4-bfrt-manager
# is installed (e.g. BFRT_PYTHON=~/venvs/bfrt/bin/python ./run.sh).
PYTHON=${BFRT_PYTHON:-python3}
if "$PYTHON" -c "import bfrt_manager" 2> /dev/null; then
    "$PYTHON" "$TOP/configure-vswitch-op4s.py" --show sw1 "$DIR/sw1.json" sw2 "$DIR/sw2.json"
else
    echo "(p4-bfrt-manager not found: using bfrt_python inside the switches)"
    for sw in sw1 sw2; do
        docker cp "$DIR/$sw.py" "$sw:/tmp/$sw.py"
        docker exec "$sw" "$SDE/run_bfshell.sh" -b "/tmp/$sw.py"
    done
fi

echo "== Test: ping from h1 to h2"
docker exec h1 ping -c 3 -W 2 10.0.2.1
