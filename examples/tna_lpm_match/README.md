# Example: IPv4 routing with tna_lpm_match (no compilation needed)

Same network as [`basic_router`](../basic_router), but using `tna_lpm_match`, one of the
open-p4studio P4-16 examples that are already compiled into the image:

```
  h1                    sw1                         sw2                    h2
10.0.1.1 ---- port 0 [ router ] port 1 ---- port 1 [ router ] port 0 ---- 10.0.2.1
 gw .254                                                                  gw .254
```

On a new machine, first follow
[Installation](../../README.md#installation) in the main README.
No compilation is needed:

```bash
cd examples/tna_lpm_match
BFRT_PYTHON=~/venvs/bfrt/bin/python ./run.sh   # switches, hosts, links, routes and a ping test
./teardown.sh                                  # remove everything
```

The ping replies show `ttl=64`: unlike `basic_router`, this program does not decrement
the TTL.

## How tna_lpm_match is used

The program applies two tables in sequence, both keyed on `vrf` (always 0) and the IPv4
destination address (longest prefix match):

| Table | Action | Effect |
|---|---|---|
| `forward` | `hit(port)` / `miss()` (default) | Sets the output port, or marks the packet to be dropped |
| `alpm_forward` | `route(srcMac, dstMac, dst_port)` | Sets the output port, rewrites both MAC addresses and cancels the drop |

`sw1.py` and `sw2.py` only fill `alpm_forward`: `forward` misses and marks the packet
for drop, then `route()` sends it to the right port with the next-hop MACs and cancels
the drop. Unlike `basic_router`, the TTL is not decremented.

Addresses, MACs and routes are the same as in [`basic_router`](../basic_router#addresses-and-rules).

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
