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
| `sw1.json`, `sw2.json` | Configuration of each switch (ports and routes) for [p4-bfrt-manager](https://github.com/mgaflip/p4-bfrt-manager) |
| `sw1.py`, `sw2.py` | The same configuration as bfrt_python scripts (fallback) |
| `compile.sh` | Compiles the program with the compiler inside the image |
| `run.sh` | Builds the whole network, loads the rules and pings h1 → h2 |
| `teardown.sh` | Removes the network |

## Running it

```bash
cd examples/basic_router
./compile.sh      # creates build/ (only needed once, or after editing the .p4)
./run.sh          # switches, hosts, links, routes and a ping test
./teardown.sh     # remove everything
```

`run.sh` needs `sudo` and 2 × 72 free hugepages (see the main README).

After `run.sh`, you can keep testing by hand:

```bash
docker exec -it h1 ping 10.0.2.1
docker exec -it h2 ping 10.0.1.1
docker attach sw1                    # bfshell (detach with Ctrl-P Ctrl-Q)
```

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

Routes installed by `sw1.py` and `sw2.py`:

| Switch | Destination | Port | New src MAC | New dst MAC |
|---|---|---|---|---|
| sw1 | 10.0.1.0/24 | 0 | sw1 port 0 | h1 |
| sw1 | 10.0.2.0/24 | 1 | sw1 port 1 | sw2 port 1 |
| sw2 | 10.0.2.0/24 | 0 | sw2 port 0 | h2 |
| sw2 | 10.0.1.0/24 | 1 | sw2 port 1 | sw1 port 1 |

The switches do not answer ARP, so `run.sh` gives each host a static ARP entry
for its gateway (`ip neigh ... nud permanent`).

## Loading your own program

The same steps work for any TNA program: compile it so that the output directory
contains `<prog>.conf`, `bf-rt.json` and `pipe/`, then start the switch with:

```bash
./start-vswitch-op4s-container.sh -p <prog> --p4-build path/to/build
```

## Ports and routes: p4-bfrt-manager or bfrt_python

`run.sh` configures the switches with
[p4-bfrt-manager](https://github.com/mgaflip/p4-bfrt-manager) and `sw1.json` /
`sw2.json` when the library is available, from the Docker host over gRPC. Point it to
the virtual environment where it is installed:

```bash
BFRT_PYTHON=~/venvs/bfrt/bin/python ./run.sh
```

Otherwise it runs `sw1.py` / `sw2.py` with `bfrt_python` inside each switch. Both
contain the same ports and routes. The JSON files can also be applied on their own,
for example after editing a route:

```bash
../../configure-vswitch-op4s.py sw1 sw1.json sw2 sw2.json
```
