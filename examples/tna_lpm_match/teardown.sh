#!/usr/bin/bash
# Copyright RSTI-UPM
# SPDX-License-Identifier: Apache-2.0
#
# Remove the example network (switches sw1, sw2 and hosts h1, h2).

DIR=$( cd "$(dirname "${BASH_SOURCE[0]}")" > /dev/null 2>&1 && pwd )
TOP=$( cd "$DIR/../.." && pwd )

"$TOP/kill-vswitch-op4s-containers.sh" sw1 sw2
docker rm -f h1 h2 > /dev/null 2>&1 || true
echo "Example network removed"
