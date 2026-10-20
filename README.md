# vswitch-op4s: Open P4 Studio virtual switches in Docker

Run Intel Tofino virtual switches (`tofino-model` + `bf_switchd`) in lightweight Docker
containers, built from [open-p4studio](https://github.com/p4lang/open-p4studio).

Each container is a small virtual Tofino switch with a configurable P4 program,
architecture (Tofino or Tofino 2) and number of ports, and exposes BF Runtime over gRPC
on port `50052`. You can run several switches at once, each with its own name and IP.

## Requirements

- Linux host with Docker (BuildKit enabled, the default in recent versions).
- To **build** the image: 16 GB+ RAM and 30–40 GB of free disk space.
- To **run** switches: containers need `--privileged` (or `NET_ADMIN`) to create
  the veth interfaces. The start script already does this.

## Repository layout

```
.
├── build-vswitch-op4s-container.sh   # build the Docker image
├── start-vswitch-op4s-container.sh   # start a switch
├── list-vswitch-op4s-containers.sh   # list running switches
├── kill-vswitch-op4s-containers.sh   # stop switches
├── link-vswitch-op4s.sh              # connect switch ports (and hosts)
├── pack-vswitch-op4s-container.sh    # create a distributable package
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
- Only the P4-16 examples compiled into the image can be loaded for now.
  **Planned:** load user-compiled programs from a mounted volume.
- Links are created by hand with `link-vswitch-op4s.sh`. **Planned:** describe a whole
  topology in a file and create it with one command.

## License

Apache-2.0. open-p4studio is distributed under its own license; see its repository.
