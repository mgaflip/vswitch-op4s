# bfrt_python rules for sw2 running tna_lpm_match (run with: run_bfshell.sh -b sw2.py)
#
#   h1 (10.0.1.1) --- port 0 [sw1] port 1 --- port 1 [sw2] port 0 --- h2 (10.0.2.1)
#
# See sw1.py for how the two tables of tna_lpm_match are used.

for dev_port in (0, 1):
    bfrt.port.port.add(DEV_PORT=dev_port, SPEED="BF_SPEED_10G",
                       FEC="BF_FEC_TYP_NONE", PORT_ENABLE=True)

alpm = bfrt.tna_lpm_match.pipe.SwitchIngress.alpm_forward
alpm.clear()

# 10.0.2.0/24 is directly connected on port 0: deliver to h2
alpm.add_with_route(vrf=0, dst_addr="10.0.2.0", dst_addr_p_length=24,
                    srcMac="00:00:00:00:02:00", dstMac="00:00:00:00:00:02", dst_port=0)

# 10.0.1.0/24 is behind sw1: send out of port 1 to sw1
alpm.add_with_route(vrf=0, dst_addr="10.0.1.0", dst_addr_p_length=24,
                    srcMac="00:00:00:00:02:01", dstMac="00:00:00:00:01:01", dst_port=1)

bfrt.complete_operations()
print("sw2: routes installed")
alpm.dump(table=True)
