#!/usr/bin/bash
# Copyright RSTI-UPM
# SPDX-License-Identifier: Apache-2.0
#
# Compile basic_router.p4 for Tofino with the compiler inside the vswitch-op4s image.
# Output: build/ with pipe/context.json, pipe/tofino.bin, bf-rt.json and basic_router.conf,
# ready to be loaded with: start-vswitch-op4s-container.sh -p basic_router --p4-build build

set -euo pipefail

DIR=$( cd "$(dirname "${BASH_SOURCE[0]}")" > /dev/null 2>&1 && pwd )
PROG=basic_router
IMAGE=${IMAGE:-vswitch-op4s:latest}
SDE_INSTALL=/home/open-p4studio/install

REGISTRY_IMAGE=${REGISTRY_IMAGE:-ghcr.io/mgaflip/vswitch-op4s}

# Get the image from the registry if it is not available locally
if [ -z "$(docker images -q "$IMAGE" 2> /dev/null)" ]; then
    echo "Pulling ${REGISTRY_IMAGE}:${IMAGE##*:}"
    docker pull "${REGISTRY_IMAGE}:${IMAGE##*:}"
    docker tag "${REGISTRY_IMAGE}:${IMAGE##*:}" "$IMAGE"
fi

echo "Compiling ${PROG}.p4 with image ${IMAGE}"

docker run --rm -v "$DIR:/p4" -w /p4 --entrypoint bash "$IMAGE" -c "
set -euo pipefail

# The P4 compiler needs the C preprocessor, which the slim runtime image may not include
if ! command -v cpp > /dev/null; then
    echo 'Installing the C preprocessor (cpp) in this temporary container...'
    apt-get update -qq && apt-get install -y -qq --no-install-recommends cpp > /dev/null
fi

COMPILER=\$(command -v bf-p4c || command -v p4c || true)
[ -n \"\$COMPILER\" ] || { echo 'ERROR: no P4 compiler (bf-p4c or p4c) found in the image'; exit 1; }
echo \"Using compiler \$COMPILER\"

rm -rf build && mkdir -p build
\$COMPILER --std p4-16 --target tofino --arch tna \
    --bf-rt-schema build/bf-rt.json -o build ${PROG}.p4

# Check the expected layout
for f in build/bf-rt.json build/pipe/context.json build/pipe/tofino.bin; do
    [ -f \"\$f\" ] || { echo \"ERROR: \$f was not generated. Output:\"; find build | head -30; exit 1; }
done

# Build the .conf from an installed example, so it has the format this SDE expects
sed 's/tna_counter/${PROG}/g' $SDE_INSTALL/share/p4/targets/tofino/tna_counter.conf > build/${PROG}.conf

# Give the files back to the host user
chown -R $(id -u):$(id -g) build
"

echo "Done: $DIR/build"
