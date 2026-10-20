#!/usr/bin/bash
# Copyright RSTI-UPM
# SPDX-License-Identifier: Apache-2.0
#
# Connect two endpoints with a virtual cable (veth pair).
#
# An endpoint can be:
#   SWITCH:PORT             a device port of a vswitch-op4s container (e.g. sw1:0)
#   CONTAINER:IFACE[:IP]    a new interface in any other container (e.g. h1:eth1:10.0.0.1/24)
#
# Usage:
#   ./link-vswitch-op4s.sh sw1:0 sw2:1                  # switch <-> switch
#   ./link-vswitch-op4s.sh h1:eth1:10.0.0.1/24 sw1:1    # host <-> switch
#   ./link-vswitch-op4s.sh -d sw1:0 sw2:1               # remove the link
#
# How it works: a veth pair is created on the Docker host and each end is moved
# into one container. Inside a switch, tc redirects packets between that end and
# the traffic side of the port (vethN+1), so tofino-model sees them on vethN.
# No switch restart is needed. Links disappear when a container stops.
#
# Requires sudo (nsenter, ip, tc on the Docker host).

set -euo pipefail

PORTS_JSON=/var/log/tofino/ports.json
LINK_MTU=${LINK_MTU:-10240}

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    sed -n '5,22p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

# Run a command inside a container's network namespace (tools from the host)
nsrun() {
    local pid=$1; shift
    sudo nsenter -t "$pid" -n "$@"
}

# Parse an endpoint and store its fields in variables <prefix>_CT, _PID, _TYPE,
# _IF (interface name for the cable end), _VETH (switch traffic veth), _IP
parse_ep() {
    local prefix=$1 ep=$2 ct rest port ip="" pid type ifname veth=""

    [[ "$ep" == *:* ]] || die "invalid endpoint '$ep' (use NAME:PORT or NAME:IFACE[:IP])"
    ct=${ep%%:*}
    rest=${ep#*:}
    port=${rest%%:*}
    if [ "$rest" != "$port" ]; then
        ip=${rest#*:}
    fi

    pid=$(docker inspect -f '{{.State.Pid}}' "$ct" 2> /dev/null) || die "container '$ct' not found"
    [ -n "$pid" ] && [ "$pid" != "0" ] || die "container '$ct' is not running"

    if [[ "$port" =~ ^[0-9]+$ ]] && docker exec "$ct" test -f "$PORTS_JSON" 2> /dev/null; then
        # Switch port: find the traffic-side veth of this device port in ports.json
        type=switch
        ifname="p${port}"
        veth=$(docker exec -i "$ct" python3 - "$PORTS_JSON" "$port" << 'PY'
import json, sys
data = json.load(open(sys.argv[1]))
port = int(sys.argv[2])
for e in data.get("PortToVeth", []):
    if e.get("device_port") == port:
        print("veth%d" % e["veth2"])
        break
PY
)
        [ -n "$veth" ] || die "port $port is not configured in $ct (see $PORTS_JSON)"
    else
        # Generic container: create an interface with the given name
        type=host
        ifname="$port"
    fi

    if nsrun "$pid" ip link show "$ifname" > /dev/null 2>&1 && [ "$DEL" = "0" ]; then
        die "interface $ifname already exists in $ct (port already linked?)"
    fi

    printf -v "${prefix}_CT"   '%s' "$ct"
    printf -v "${prefix}_PID"  '%s' "$pid"
    printf -v "${prefix}_TYPE" '%s' "$type"
    printf -v "${prefix}_IF"   '%s' "$ifname"
    printf -v "${prefix}_VETH" '%s' "$veth"
    printf -v "${prefix}_IP"   '%s' "$ip"
}

# Configure one end of the cable inside its container
setup_end() {
    local pid=$1 tmp=$2 ifname=$3 type=$4 veth=$5 ip=$6

    nsrun "$pid" ip link set "$tmp" name "$ifname"
    nsrun "$pid" ip link set "$ifname" mtu "$LINK_MTU"
    nsrun "$pid" ip link set "$ifname" up
    nsrun "$pid" ethtool -K "$ifname" tx off rx off tso off gso off gro off > /dev/null 2>&1 || true

    if [ "$type" = "switch" ]; then
        # Bridge cable end <-> traffic side of the switch port, in both directions
        nsrun "$pid" tc qdisc del dev "$veth" ingress 2> /dev/null || true
        nsrun "$pid" tc qdisc add dev "$veth" ingress
        nsrun "$pid" tc filter add dev "$veth" parent ffff: protocol all \
            u32 match u32 0 0 action mirred egress redirect dev "$ifname"
        nsrun "$pid" tc qdisc add dev "$ifname" ingress
        nsrun "$pid" tc filter add dev "$ifname" parent ffff: protocol all \
            u32 match u32 0 0 action mirred egress redirect dev "$veth"
    elif [ -n "$ip" ]; then
        nsrun "$pid" ip addr add "$ip" dev "$ifname"
    fi
}

# Remove one end of the cable (deleting one end of a veth pair deletes both)
remove_end() {
    local pid=$1 ifname=$2 type=$3 veth=$4
    if [ "$type" = "switch" ]; then
        nsrun "$pid" tc qdisc del dev "$veth" ingress 2> /dev/null || true
    fi
    nsrun "$pid" ip link del "$ifname" 2> /dev/null || true
}

# ---- Main ----
DEL=0
if [ "${1:-}" = "-d" ]; then
    DEL=1
    shift
fi
[ $# -eq 2 ] || usage

parse_ep A "$1"
parse_ep B "$2"
[ "$A_CT" != "$B_CT" ] || die "both endpoints are in the same container"

if [ "$DEL" = "1" ]; then
    remove_end "$A_PID" "$A_IF" "$A_TYPE" "$A_VETH"
    remove_end "$B_PID" "$B_IF" "$B_TYPE" "$B_VETH"
    echo "Link $1 <-> $2 removed"
    exit 0
fi

# Temporary names on the host (max 15 chars), renamed inside each container
TMP_A="vl${RANDOM}a"
TMP_B="vl${RANDOM}b"

sudo ip link add "$TMP_A" type veth peer name "$TMP_B"
sudo ip link set "$TMP_A" netns "$A_PID"
sudo ip link set "$TMP_B" netns "$B_PID"

setup_end "$A_PID" "$TMP_A" "$A_IF" "$A_TYPE" "$A_VETH" "$A_IP"
setup_end "$B_PID" "$TMP_B" "$B_IF" "$B_TYPE" "$B_VETH" "$B_IP"

describe() {
    local ct=$1 type=$2 ifname=$3 veth=$4
    if [ "$type" = "switch" ]; then
        echo "${ct} port ${ifname#p} (${ifname} <-> ${veth})"
    else
        echo "${ct} ${ifname}"
    fi
}
echo "Linked $(describe "$A_CT" "$A_TYPE" "$A_IF" "$A_VETH") <-> $(describe "$B_CT" "$B_TYPE" "$B_IF" "$B_VETH")"
