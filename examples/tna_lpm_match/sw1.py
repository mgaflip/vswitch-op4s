# bfrt_python rules for sw1 running tna_lpm_match (run with: run_bfshell.sh -b sw1.py)
#
#   h1 (10.0.1.1) --- port 0 [sw1] port 1 --- port 1 [sw2] port 0 --- h2 (10.0.2.1)
#
# tna_lpm_match applies two tables in sequence, with vrf = 0:
#   forward       (vrf, ipv4 dst lpm) -> hit(port) / miss() = drop
#   alpm_forward  (vrf, ipv4 dst lpm) -> route(srcMac, dstMac, dst_port), also un-drops
# Only alpm_forward is filled: forward misses (drop), then route() sets the port,
# rewrites the MAC addresses and cancels the drop.

for dev_port in (0, 1):
    bfrt.port.port.add(DEV_PORT=dev_port, SPEED="BF_SPEED_10G",
                       FEC="BF_FEC_TYP_NONE", PORT_ENABLE=True)

alpm = bfrt.tna_lpm_match.pipe.SwitchIngress.alpm_forward
alpm.clear()

# 10.0.1.0/24 is directly connected on port 0: deliver to h1
alpm.add_with_route(vrf=0, dst_addr="10.0.1.0", dst_addr_p_length=24,
                    srcMac="00:00:00:00:01:00", dstMac="00:00:00:00:00:01", dst_port=0)

# 10.0.2.0/24 is behind sw2: send out of port 1 to sw2
alpm.add_with_route(vrf=0, dst_addr="10.0.2.0", dst_addr_p_length=24,
                    srcMac="00:00:00:00:01:01", dstMac="00:00:00:00:02:01", dst_port=1)

bfrt.complete_operations()
print("sw1: routes installed")
alpm.dump(table=True)
