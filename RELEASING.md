# Releasing a new image version

Notes for maintainers on how to build the vswitch-op4s image and publish it on
GitHub Container Registry as `ghcr.io/mgaflip/vswitch-op4s`.

Each release is published with two tags: its version number (`0.1.0`, `0.1.1`...) and
`latest`. Users get `latest` by default; `start-vswitch-op4s-container.sh -v X.Y.Z`
uses a fixed version.

## 1. Build the image

On a machine with 16 GB+ of RAM and 30–40 GB of free disk:

```bash
./build-vswitch-op4s-container.sh
```

The first build takes several hours. Later builds reuse the Docker cache: changes that
only affect the runtime stage of the Dockerfile (packages, labels, the entrypoint
script) take a few minutes.

## 2. Test it

```bash
# No missing shared libraries (no output expected)
docker run --rm --entrypoint bash vswitch-op4s:latest -c \
  'for f in install/bin/* $(find install/lib -name "*.so*"); do ldd "$f" 2>/dev/null; done | grep "not found"'

# Switches start and their gRPC server answers
./start-vswitch-op4s-container.sh
sleep 30
./list-vswitch-op4s-containers.sh
docker exec sw1 bash -c 'exec 3<>/dev/tcp/127.0.0.1/50052 && echo "gRPC OK"'

# A complete scenario
(cd examples/tna_lpm_match && ./run.sh && ./teardown.sh)
./kill-vswitch-op4s-containers.sh
```

## 3. Publish it

Create a GitHub token (classic) with the `write:packages` scope at
<https://github.com/settings/tokens>. Never paste it anywhere except in the
`docker login` password prompt.

```bash
VERSION=0.1.1

docker login ghcr.io -u mgaflip            # paste the token when asked for a password
docker tag vswitch-op4s:latest ghcr.io/mgaflip/vswitch-op4s:$VERSION
docker tag vswitch-op4s:latest ghcr.io/mgaflip/vswitch-op4s:latest
docker push ghcr.io/mgaflip/vswitch-op4s:$VERSION
docker push ghcr.io/mgaflip/vswitch-op4s:latest
docker logout ghcr.io
```

The image carries the `org.opencontainers.image.source` label, so GitHub links the
package to this repository automatically. The package must be public (set once in
its *Package settings*).

## 4. Tag the repository

Tag the commit the image was built from, so each image version maps to a version of
the scripts:

```bash
git tag -a v$VERSION -m "vswitch-op4s $VERSION"
git push origin v$VERSION
```

Optionally, create a GitHub release from the tag with a short changelog, and attach the
offline package from `./pack-vswitch-op4s-container.sh`.
