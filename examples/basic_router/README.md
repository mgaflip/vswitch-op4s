# Example: basic IPv4 routing between two hosts

Two virtual Tofino switches running a minimal IPv4 router written in P4, connecting
two hosts in different subnets:

```
  h1                    sw1                         sw2                    h2
10.0.1.1 ---- port 0 [ router ] port 1 ---- port 1 [ router ] port 0 ---- 10.0.2.1
 gw .254                                                                  gw .254
```

## Files

| File | Description |
|---|---|
| `basic_router.p4` | The P4 program: IPv4 longest-prefix-match routing |
| `sw1.json`, `sw2.json` | Configuration of each switch (ports and routes) for [p4-bfrt-manager](https://github.com/UPM-RSTI/p4-bfrt-manager) |
| `sw1.py`, `sw2.py` | The same configuration as bfrt_python scripts (fallback) |
| `compile.sh` | Compiles the program with the compiler inside the image |
| `run.sh` | Builds the whole network, loads the rules and pings h1 → h2 |
| `teardown.sh` | Removes the network |

## Running it

On a new machine, first prepare it as explained in
[Getting started](../../README.md#getting-started) in the main README. To load the
routes with p4-bfrt-manager, also [install it](../../README.md#configuring-switches-with-p4-bfrt-manager)
(optional). This example runs 2 switches, so the default hugepages are enough; it needs
about 4 GB of free RAM and 2 cores, plus `sudo` for the links. It uses the names `sw1`,
`sw2`, `h1` and `h2`: stop any other switch with those names first.

**1. Compile the P4 program.** This creates `build/` with `basic_router.conf`,
`bf-rt.json` and `pipe/`. Only needed once, or after editing the `.p4`. The first time it
needs internet access, to install the C preprocessor in a temporary container.

```bash
cd examples/basic_router
./compile.sh
```

**2. Build the network and test it.** `run.sh` asks for `sudo` (for the links and the
host configuration). It starts `sw1` and `sw2` with `basic_router`, creates `h1` and
`h2`, links them, configures the hosts, loads ports and routes, and ends with a ping:

```bash
BFRT_PYTHON=~/venvs/bfrt/bin/python ./run.sh
```

```
== Test: ping from h1 to h2
64 bytes from 10.0.2.1: seq=0 ttl=62 time=...
```

`ttl=62` shows that the reply went through two routers, each decrementing the TTL.
Without `BFRT_PYTHON`, ports and routes are loaded with `bfrt_python` inside the
switches instead (see [below](#ports-and-routes-p4-bfrt-manager-or-bfrt_python)).

**3. Test by hand.**

```bash
docker exec -it h1 ping 10.0.2.1
docker exec -it h2 ping 10.0.1.1
../../list-vswitch-op4s-containers.sh
docker attach sw1                    # bfshell (detach with Ctrl-P Ctrl-Q)
```

**4. Clean up.**

```bash
./teardown.sh
```

### Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `compile.sh` hangs while downloading | Docker MTU larger than the network's | Docker MTU in [Getting started](../../README.md#1-prepare-the-machine-once) |
| A switch stops a few seconds after starting | Not enough hugepages | [Hugepages](../../README.md#hugepages); the start script warns about it |
| `permission denied` when using Docker | User not in the `docker` group | `sudo usermod -aG docker $USER`, then log in again |
| `A container named sw1 already exists` | Another switch uses that name | Stop it: `../../kill-vswitch-op4s-containers.sh sw1 sw2` |
| The ping gets no reply | Routes not loaded, or field names differ in your SDE version | Check the output of the routes step in `run.sh` |

## How the program works

`basic_router.p4` parses Ethernet and IPv4. In the ingress pipeline, the table
`ipv4_lpm` matches the destination IP address (longest prefix match) and runs:

- `route(port, src_mac, dst_mac)`: sends the packet out of `port`, rewrites the
  Ethernet source with the switch port MAC and the destination with the next hop
  MAC, and decrements the TTL. The deparser recomputes the IPv4 checksum.
- `drop()`: the default action, for packets with no route.

Packets that are not IPv4 (ARP, IPv6...) or whose TTL would reach 0 are dropped.
The egress pipeline does nothing.

## Addresses and rules

| Element | IP | MAC |
|---|---|---|
| h1 | 10.0.1.1/24, gateway 10.0.1.254 | 00:00:00:00:00:01 |
| sw1 port 0 (h1 gateway) | | 00:00:00:00:01:00 |
| sw1 port 1 | | 00:00:00:00:01:01 |
| sw2 port 1 | | 00:00:00:00:02:01 |
| sw2 port 0 (h2 gateway) | | 00:00:00:00:02:00 |
| h2 | 10.0.2.1/24, gateway 10.0.2.254 | 00:00:00:00:00:02 |

Routes installed in each switch (`sw1.json` / `sw1.py` and `sw2.json` / `sw2.py`):

| Switch | Destination | Port | New src MAC | New dst MAC |
|---|---|---|---|---|
| sw1 | 10.0.1.0/24 | 0 | sw1 port 0 | h1 |
| sw1 | 10.0.2.0/24 | 1 | sw1 port 1 | sw2 port 1 |
| sw2 | 10.0.2.0/24 | 0 | sw2 port 0 | h2 |
| sw2 | 10.0.1.0/24 | 1 | sw2 port 1 | sw1 port 1 |

The switches do not answer ARP, so `run.sh` gives each host a static ARP entry
for its gateway (`ip neigh ... nud permanent`).

## Loading your own program

`compile.sh` and `run.sh` work for any TNA program: change `PROG` in both, and the
routes in the JSON files. To start a single switch with a compiled program, see
[Loading your own P4 program](../../README.md#loading-your-own-p4-program).

## Ports and routes: p4-bfrt-manager or bfrt_python

`run.sh` configures the switches with
[p4-bfrt-manager](https://github.com/UPM-RSTI/p4-bfrt-manager) and `sw1.json` /
`sw2.json` when `BFRT_PYTHON` points to the virtual environment where it is installed,
from the Docker host over gRPC. Otherwise it runs `sw1.py` / `sw2.py` with `bfrt_python` inside each switch. Both
contain the same ports and routes. The JSON files can also be applied on their own,
for example after editing a route (with the virtual environment active):

```bash
../../configure-vswitch-op4s.py sw1 sw1.json sw2 sw2.json
```
