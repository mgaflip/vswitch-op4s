# Example: IPv4 routing with tna_lpm_match (no compilation needed)

Same network as [`basic_router`](../basic_router), but using `tna_lpm_match`, one of the
open-p4studio P4-16 examples that are already compiled into the image:

```
  h1                    sw1                         sw2                    h2
10.0.1.1 ---- port 0 [ router ] port 1 ---- port 1 [ router ] port 0 ---- 10.0.2.1
 gw .254                                                                  gw .254
```

## Files

| File | Description |
|---|---|
| `sw1.json`, `sw2.json` | Configuration of each switch (ports and routes) for [p4-bfrt-manager](https://github.com/mgaflip/p4-bfrt-manager) |
| `sw1.py`, `sw2.py` | The same configuration as bfrt_python scripts (fallback) |
| `run.sh` | Builds the whole network, loads the rules and pings h1 → h2 |
| `teardown.sh` | Removes the network |

## Running it

On a new machine, first prepare it as explained in
[Getting started](../../README.md#getting-started) in the main README. To load the
routes with p4-bfrt-manager, also [install it](../../README.md#configuring-switches-with-p4-bfrt-manager)
(optional). Like [`basic_router`](../basic_router), it runs 2 switches and uses the
names `sw1`, `sw2`, `h1` and `h2`, and `run.sh` needs `sudo` for the links.

```bash
cd examples/tna_lpm_match
BFRT_PYTHON=~/venvs/bfrt/bin/python ./run.sh   # switches, hosts, links, routes and a ping test
./teardown.sh                                  # remove everything
```

The ping replies show `ttl=64`: this program does not decrement the TTL. Without
`BFRT_PYTHON`, ports and routes are loaded with `bfrt_python` inside the switches
(`sw1.py`, `sw2.py`). If something fails, see the
[troubleshooting table of basic_router](../basic_router#troubleshooting).

## How tna_lpm_match is used

The program applies two tables in sequence, both keyed on `vrf` (always 0) and the IPv4
destination address (longest prefix match):

| Table | Action | Effect |
|---|---|---|
| `forward` | `hit(port)` / `miss()` (default) | Sets the output port, or marks the packet to be dropped |
| `alpm_forward` | `route(srcMac, dstMac, dst_port)` | Sets the output port, rewrites both MAC addresses and cancels the drop |

The configuration only fills `alpm_forward`: `forward` misses and marks the packet for
drop, then `route()` sends it to the right port with the next-hop MACs and cancels the
drop.

Addresses, MACs and routes are the same as in [`basic_router`](../basic_router#addresses-and-rules).
To apply the JSON files on their own, for example after editing a route (with the
p4-bfrt-manager virtual environment active):

```bash
../../configure-vswitch-op4s.py sw1 sw1.json sw2 sw2.json
```
