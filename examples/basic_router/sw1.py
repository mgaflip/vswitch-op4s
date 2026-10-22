# bfrt_python rules for sw1 (run with: run_bfshell.sh -b sw1.py)
#
#   h1 (10.0.1.1) --- port 0 [sw1] port 1 --- port 1 [sw2] port 0 --- h2 (10.0.2.1)
#
# MAC addresses used in the example:
#   h1                00:00:00:00:00:01     sw1 port 0  00:00:00:00:01:00 (h1 gateway)
#   h2                00:00:00:00:00:02     sw1 port 1  00:00:00:00:01:01
#                                           sw2 port 0  00:00:00:00:02:00 (h2 gateway)
#                                           sw2 port 1  00:00:00:00:02:01

# Enable the two ports used by this switch
for dev_port in (0, 1):
    bfrt.port.port.add(DEV_PORT=dev_port, SPEED="BF_SPEED_10G",
                       FEC="BF_FEC_TYP_NONE", PORT_ENABLE=True)

lpm = bfrt.basic_router.pipe.Ingress.ipv4_lpm
lpm.clear()

# 10.0.1.0/24 is directly connected on port 0: deliver to h1
lpm.add_with_route(dst_addr="10.0.1.0", dst_addr_p_length=24,
                   port=0, src_mac="00:00:00:00:01:00", dst_mac="00:00:00:00:00:01")

# 10.0.2.0/24 is behind sw2: send out of port 1 to sw2
lpm.add_with_route(dst_addr="10.0.2.0", dst_addr_p_length=24,
                   port=1, src_mac="00:00:00:00:01:01", dst_mac="00:00:00:00:02:01")

bfrt.complete_operations()
print("sw1: routes installed")
lpm.dump(table=True)
