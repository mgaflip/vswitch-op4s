# vswitch-op4s: Open P4 Studio virtual switches in Docker

Run Intel Tofino virtual switches (`tofino-model` + `bf_switchd`) in lightweight Docker
containers, built from [open-p4studio](https://github.com/p4lang/open-p4studio).

Each container is a small virtual Tofino switch with a configurable P4 program,
architecture (Tofino or Tofino 2) and number of ports, and exposes BF Runtime over gRPC
on port `50052`. You can run several switches at once, each with its own name and IP,
connect them to each other and to hosts, and configure them remotely with
[p4-bfrt-manager](https://github.com/mgaflip/p4-bfrt-manager).

## Requirements

- Linux host with Docker (BuildKit enabled, the default in recent versions).
- To **build** the image: 16 GB+ RAM and 30–40 GB of free disk space.
- To **run** switches: containers need `--privileged` (or `NET_ADMIN`) to create
  the veth interfaces. The start script already does this.
- Optional, to configure switches from JSON files:
  [p4-bfrt-manager](https://github.com/mgaflip/p4-bfrt-manager) (see
  [Configuring switches](#configuring-switches-with-p4-bfrt-manager)).
- Each running switch uses about **520 MB of RAM**, **half a CPU core** and
  **72 hugepages** (2 MB each, 144 MB) on the host. See [Hugepages](#hugepages).

## Hugepages

`bf_switchd` allocates its DMA memory pools from the host's hugepages, which are shared
by all switch containers. Each switch needs **72 hugepages** (2 MB each).

On first start the SDE sets the host to 196 hugepages, which is only enough for
**2 switches**. A third switch starts but `bf_switchd` fails a few seconds later with
`bf_sys_dma_pool_create failed`, and the container stops.

To run N switches, reserve about N × 72 hugepages (plus some margin). For 8 switches:

```bash
sudo sysctl -w vm.nr_hugepages=640
echo "vm.nr_hugepages = 640" | sudo tee /etc/sysctl.d/90-vswitch-hugepages.conf
grep -i hugepages /proc/meminfo     # check HugePages_Total and HugePages_Free
```

The SDE scripts only raise this value when it is lower than 196, so containers will not
reduce it. Reserved hugepages are not available to other programs, even when no switch
is running.

`start-vswitch-op4s-container.sh` checks that at least 72 hugepages are free before
starting a switch. When starting several switches in a loop, wait a few seconds between
them (`sleep 10`) so each one has reserved its hugepages before the next check.

## Repository layout

```
.
├── build-vswitch-op4s-container.sh   # build the Docker image
├── start-vswitch-op4s-container.sh   # start a switch
├── list-vswitch-op4s-containers.sh   # list running switches
├── kill-vswitch-op4s-containers.sh   # stop switches
├── link-vswitch-op4s.sh              # connect switch ports (and hosts)
├── configure-vswitch-op4s.py         # configure switches from JSON (p4-bfrt-manager)
├── pack-vswitch-op4s-container.sh    # create a distributable package
├── examples/
│   ├── basic_router/                 # 2 switches + 2 hosts, own P4 router program
│   └── tna_lpm_match/                # same network with a precompiled SDE example
└── docker/
    ├── Dockerfile.vswitch-op4s       # multi-stage build (builder + slim runtime)
    ├── vswitch-op4s.yaml             # p4studio build profile
    ├── start-tofino-switch.sh        # container entrypoint
    └── .dockerignore
```

## Quick start

```bash
# 1. Build the image (clones open-p4studio and compiles it; takes a long time)
./build-vswitch-op4s-container.sh

# 2. Start a switch with the defaults: Tofino, tna_counter, ports 0-3
./start-vswitch-op4s-container.sh

# 3. List switches
./list-vswitch-op4s-containers.sh

# 4. Open the bfshell prompt (detach with Ctrl-P Ctrl-Q)
docker attach sw1

# 5. Stop all switches
./kill-vswitch-op4s-containers.sh
```

## Starting switches

Every option has a default, so the script can be run without arguments.

| Option | Description | Default |
|---|---|---|
| `-n, --name` | Container name | first free `sw1`, `sw2`, ... |
| `--prefix` | Prefix for automatic names | `sw` |
| `-p, --prog` | P4 program | `tna_counter` |
| `-a, --arch` | `tofino` or `tofino2` | `tofino` |
| `--p4-build` | Load your own compiled program from this host directory (see below) | |
| `--ports` | Switch device ports | `"0 1 2 3"` |
| `--cpu-port` | CPU port device number | `64` |
| `--no-cpu-veth` | Do not create the CPU port veth pair | |
| `--net` | Docker network | default bridge |
| `--ip` | Fixed IP (requires `--net`) | automatic |
| `-g, --grpc-port` | Also publish gRPC on this host port (`0` = random) | not published |
| `-v, --version` | Image tag | `latest` |
| `-i, --interactive` | Stay attached to the bfshell prompt | |
| `-k, --keep` | Keep the container after it stops, to read its logs (`docker rm` it later) | |

Anything after `--` is passed to `docker run` unchanged.

### Several switches with fixed IPs

```bash
docker network create --subnet 172.30.0.0/24 p4net

./start-vswitch-op4s-container.sh -n sw1 --net p4net --ip 172.30.0.11
./start-vswitch-op4s-container.sh -n sw2 --net p4net --ip 172.30.0.12 -p tna_exact_match --ports "0 1"
```

Each switch listens on its own IP at port `50052` (`172.30.0.11:50052`, `172.30.0.12:50052`).
Containers on the same user-defined network can also reach them by name (`sw1:50052`).

Container IPs are only reachable from the Docker host. To reach a switch from another
machine, publish its gRPC port with a different host port per switch (`-g 50052`, `-g 50053`, ...).

### Loading your own P4 program

By default a switch runs one of the P4-16 examples compiled into the image. To run your
own program, compile it so that the output directory contains `<prog>.conf`,
`bf-rt.json` and `pipe/` (`context.json`, `tofino.bin`), and start the switch with:

```bash
./start-vswitch-op4s-container.sh -p myprog --p4-build path/to/build
```

The directory is mounted read-only where the SDE expects installed programs. See
[`examples/basic_router`](examples/basic_router) for a complete example, including how
to compile with the compiler inside the image.

## Configuring switches with p4-bfrt-manager

[p4-bfrt-manager](https://github.com/mgaflip/p4-bfrt-manager) is a Python library to
configure Tofino switches remotely over BF Runtime gRPC, with table entries written as
JSON. It works with these virtual switches exactly as with hardware ones, from the
Docker host (or from another machine if the gRPC port is published with `-g`).

Install it once, in a virtual environment:

```bash
python3 -m venv ~/venvs/bfrt
source ~/venvs/bfrt/bin/activate
pip install git+https://github.com/mgaflip/p4-bfrt-manager.git
```

`configure-vswitch-op4s.py` applies one JSON file per switch. Switches can be given by
container name; their IP is looked up with Docker. Entries that already exist are
updated, so a configuration can be applied again after changing it:

```bash
./configure-vswitch-op4s.py sw1 sw1.json sw2 sw2.json
./configure-vswitch-op4s.py --show sw1 sw1.json        # also print entries per table
```

A configuration file lists ports (`$PORT`) and P4 table entries in the p4-bfrt-manager
format:

```json
[
  {
    "table-name": "$PORT",
    "match-fields": {"$DEV_PORT": 0},
    "action-params": {"$SPEED": "BF_SPEED_10G", "$FEC": "BF_FEC_TYP_NONE", "$PORT_ENABLE": true}
  },
  {
    "table-name": "pipe.Ingress.ipv4_lpm",
    "match-fields": {"hdr.ipv4.dst_addr": {"value": "10.0.2.0", "prefix_len": 24}},
    "match-annotations": {"hdr.ipv4.dst_addr": "ipv4"},
    "action-name": "Ingress.route",
    "action-params": {"port": 1, "src_mac": "00:00:00:00:01:01", "dst_mac": "00:00:00:00:02:01"},
    "action-annotations": {"src_mac": "mac", "dst_mac": "mac"}
  }
]
```

For anything beyond applying entries (reading tables and counters, dumping a switch's
state to JSON, multicast, loading programs over gRPC...), use the library directly
with the switch address shown by `list-vswitch-op4s-containers.sh`:

```python
from bfrt_manager import BFRTManager

with BFRTManager(0, "172.17.0.2", 50052) as sw:
    sw.start()                                   # bind to the running program
    sw.print_table_entries_summary()
    print(sw.get_port_stats())
```

The examples use p4-bfrt-manager when it is installed. Point them to its virtual
environment with `BFRT_PYTHON`:

```bash
BFRT_PYTHON=~/venvs/bfrt/bin/python ./run.sh
```

Without it, they fall back to `bfrt_python` scripts run inside each switch.

## Example network

[`examples/basic_router`](examples/basic_router) builds two switches running a minimal
IPv4 router in P4 and two hosts in different subnets, installs the routes and pings
from one host to the other:

```bash
cd examples/basic_router
./compile.sh && ./run.sh
```

[`examples/tna_lpm_match`](examples/tna_lpm_match) builds the same network using
`tna_lpm_match`, an open-p4studio example already compiled into the image, so no
compilation is needed:

```bash
cd examples/tna_lpm_match
./run.sh
```

## Ports and veth interfaces

Inside each container, every device port in `--ports` gets its own veth pair:

| Device port | Model side | Traffic side |
|---|---|---|
| 1st port | `veth0` | `veth1` |
| 2nd port | `veth2` | `veth3` |
| ... | ... | ... |
| CPU port | `veth250` | `veth251` |

`tofino-model` attaches to the even interface; send or capture traffic on the odd one
(for example `docker exec -it sw1 tcpdump -i veth1`). The mapping is written to
`/var/log/tofino/ports.json` inside the container and passed to the model.

On Tofino 1, device ports are numbered `pipe × 128 + local port` (pipe 0 starts at 0,
pipe 1 at 128, and so on). Tofino 2 uses a different numbering: set `--ports` and
`--cpu-port` to the values your P4 program expects.

Ports must also be added and enabled from the control plane (BF Runtime or bfshell)
before they forward traffic.

## Connecting switches and hosts

`link-vswitch-op4s.sh` connects two endpoints with a virtual cable, so you can build
topologies of switches and hosts. Switches do not need to be restarted.

### Usage

```bash
./link-vswitch-op4s.sh ENDPOINT_A ENDPOINT_B       # create a link
./link-vswitch-op4s.sh -d ENDPOINT_A ENDPOINT_B    # remove it
```

An endpoint can be:

| Endpoint | Meaning | Example |
|---|---|---|
| `SWITCH:PORT` | A device port of a vswitch-op4s container. The port must be one of the `--ports` the switch was started with. | `sw1:0` |
| `CONTAINER:IFACE` | A new interface created in any other container (for example, a host). | `h1:eth1` |
| `CONTAINER:IFACE:IP/PREFIX` | Same, and the IP address is assigned to the new interface. | `h1:eth1:10.0.0.1/24` |

The script runs `ip`, `tc` and `nsenter` on the Docker host, so it needs `sudo`.

### Example: h1 -- sw1 -- sw2 -- h2

```bash
# Two switches
./start-vswitch-op4s-container.sh                 # sw1
./start-vswitch-op4s-container.sh                 # sw2

# Two hosts with no network other than the links we create
docker run -dit --name h1 --network none --cap-add NET_ADMIN alpine
docker run -dit --name h2 --network none --cap-add NET_ADMIN alpine

# Cables
./link-vswitch-op4s.sh h1:eth1:10.0.0.1/24 sw1:0
./link-vswitch-op4s.sh sw1:1 sw2:0
./link-vswitch-op4s.sh sw2:1 h2:eth1:10.0.0.2/24

# Once the switches forward traffic (see below)
docker exec h1 ping 10.0.0.2

# Remove a link
./link-vswitch-op4s.sh -d sw1:1 sw2:0
```

### How it works

1. A veth pair is created on the Docker host and each end is moved into the network
   namespace of one container (found through the container PID).
2. In a host container, the end is renamed to the interface name you gave
   (`eth1`) and gets the IP address, if any.
3. In a switch container, the end is renamed to `p<PORT>` (for example `p1`). The script
   reads `/var/log/tofino/ports.json` to find the traffic side of that port
   (`veth1`, `veth3`, ...) and adds two `tc` rules that redirect every packet between
   `p<PORT>` and that veth, in both directions.

Packet path for `sw1:1 <-> sw2:0`:

```
sw1: tofino-model -> veth2 -> veth3 -> (tc) -> p1 ====cable==== p0 -> (tc) -> veth1 -> veth0 -> tofino-model :sw2
```

### Checking a link

```bash
docker exec sw1 ip link show p1                      # cable end exists and is UP
docker exec sw1 tc filter show dev veth3 ingress     # redirect rule in place
docker exec -it sw2 tcpdump -ni p0                   # watch packets arriving at sw2
```

### Notes

- **Links are not persistent.** They disappear when either container stops; recreate
  them after restarting a switch or host.
- **A port can only have one link.** Linking a port that is already linked fails with
  "interface pN already exists". Remove the old link first with `-d`.
- **A link does not mean forwarding.** Packets only cross a switch if its ports are
  enabled in `bf_switchd` and the loaded P4 program (with its table entries) forwards them.
- You can still capture or inject traffic on the traffic veth of a linked port
  (`veth3` in the example above) for debugging.

## Logs

```bash
docker exec sw1 tail -f /var/log/tofino/tofino_model.log
docker exec -it sw1 bash
```

## Packaging for distribution

```bash
./pack-vswitch-op4s-container.sh              # image + scripts -> vswitch-op4s-latest.tgz
./pack-vswitch-op4s-container.sh --no-image   # build files only
```

On the target machine:

```bash
tar xzf vswitch-op4s-latest.tgz && cd vswitch-op4s && ./start-vswitch-op4s-container.sh
```

## Limitations and roadmap

- `tofino-model` is a functional simulator: suitable for testing P4 logic and
  control planes, not for performance measurements.
- Links are created by hand with `link-vswitch-op4s.sh`. **Planned:** describe a whole
  topology in a file and create it with one command.

## License

Apache-2.0. open-p4studio is distributed under its own license; see its repository.
