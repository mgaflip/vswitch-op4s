#!/usr/bin/env python3
# Copyright RSTI-UPM
# SPDX-License-Identifier: Apache-2.0
"""
Configure vswitch-op4s switches from JSON files, using p4-bfrt-manager
(https://github.com/mgaflip/p4-bfrt-manager) over BF Runtime gRPC.

Each JSON file holds a list of entries in the p4-bfrt-manager format: P4 table
entries and fixed-function ones such as $PORT. Entries that already exist are
updated, so a configuration can be applied more than once.

Usage:
  configure-vswitch-op4s.py SWITCH FILE.json [SWITCH FILE.json ...]

  SWITCH is a container name (sw1), an IP address (172.17.0.2, port 50052)
  or HOST:PORT (10.0.2.68:50053).

Examples:
  ./configure-vswitch-op4s.py sw1 sw1.json sw2 sw2.json
  ./configure-vswitch-op4s.py --show sw1 sw1.json

Install p4-bfrt-manager first, e.g. in a virtual environment:
  python3 -m venv ~/venvs/bfrt && . ~/venvs/bfrt/bin/activate
  pip install git+https://github.com/mgaflip/p4-bfrt-manager.git
"""
import argparse
import json
import logging
import subprocess
import sys
import time

try:
    from bfrt_manager import BFRTManager, BFRTException
except ImportError:
    sys.exit("p4-bfrt-manager is not installed (or its virtual environment is not active).\n"
             "  pip install git+https://github.com/mgaflip/p4-bfrt-manager.git")

GRPC_PORT = 50052


def resolve(switch, default_port=GRPC_PORT):
    """Return (host, port) for a container name, an IP address or HOST:PORT."""
    if ":" in switch:
        host, port = switch.rsplit(":", 1)
        return host, int(port)
    if all(c.isdigit() or c == "." for c in switch):
        return switch, default_port
    out = subprocess.run(
        ["docker", "inspect", "-f",
         "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}", switch],
        capture_output=True, text=True)
    ips = out.stdout.split()
    if out.returncode != 0 or not ips:
        sys.exit(f"Switch container '{switch}' not found, not running or without an IP")
    return ips[0], default_port


def connect(host, port, timeout):
    """Connect and bind to the program running on the switch, retrying until timeout."""
    deadline = time.time() + timeout
    last_error = None
    while time.time() < deadline:
        try:
            mgr = BFRTManager(0, host, port)
            mgr.start()                     # bind to the program already running
            return mgr
        except Exception as e:              # switch still starting, gRPC not ready...
            last_error = e
            time.sleep(3)
    sys.exit(f"Cannot connect to {host}:{port} after {timeout}s: {last_error}")


def apply_entries(mgr, entries):
    """Insert each entry, or update it if it already exists. Returns counters."""
    inserted = updated = failed = 0
    for entry in entries:
        try:
            mgr.table_entry_insert_from_json(entry)
            inserted += 1
        except BFRTException:
            try:
                mgr.table_entry_update_from_json(entry)
                updated += 1
            except BFRTException as e:
                failed += 1
                print(f"  FAILED {entry.get('table-name')}: {e}")
    return inserted, updated, failed


def main():
    parser = argparse.ArgumentParser(
        description="Configure vswitch-op4s switches from p4-bfrt-manager JSON files.",
        epilog="Example: %(prog)s sw1 sw1.json sw2 sw2.json")
    parser.add_argument("pairs", nargs="+", metavar="SWITCH FILE",
                        help="switch (name, IP or HOST:PORT) followed by its JSON file")
    parser.add_argument("--timeout", type=int, default=120,
                        help="seconds to wait for each switch to answer (default: 120)")
    parser.add_argument("--show", action="store_true",
                        help="print the number of entries per table afterwards")
    parser.add_argument("-v", "--verbose", action="store_true", help="p4-bfrt-manager logs")
    args = parser.parse_args()

    if len(args.pairs) % 2:
        parser.error("arguments must be SWITCH FILE pairs")
    logging.basicConfig(level=logging.INFO if args.verbose else logging.WARNING)

    total_failed = 0
    for switch, path in zip(args.pairs[0::2], args.pairs[1::2]):
        with open(path) as f:
            entries = json.load(f)
        if isinstance(entries, dict):
            entries = [entries]

        host, port = resolve(switch)
        print(f"{switch} ({host}:{port}) <- {path}: {len(entries)} entries")
        mgr = connect(host, port, args.timeout)
        try:
            inserted, updated, failed = apply_entries(mgr, entries)
            print(f"  inserted {inserted}, updated {updated}, failed {failed}")
            total_failed += failed
            if args.show:
                mgr.print_table_entries_summary()
        finally:
            mgr.stop()

    sys.exit(1 if total_failed else 0)


if __name__ == "__main__":
    main()
