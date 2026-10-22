/*
 * basic_router.p4 - Minimal IPv4 router for Tofino (TNA)
 *
 * Copyright RSTI-UPM
 * SPDX-License-Identifier: Apache-2.0
 *
 * For every IPv4 packet, a longest-prefix-match table on the destination address
 * chooses the output port and rewrites the Ethernet addresses (like a router does
 * for the next hop). TTL is decremented and the IPv4 checksum is recomputed.
 * Anything that is not IPv4 (ARP, IPv6, ...) or has no matching route is dropped.
 */

#include <core.p4>
#include <tna.p4>

typedef bit<48> mac_addr_t;
typedef bit<32> ipv4_addr_t;

const bit<16> ETHERTYPE_IPV4 = 0x0800;

/*************************************************************************
 * Headers and metadata
 *************************************************************************/

header ethernet_h {
    mac_addr_t dst_addr;
    mac_addr_t src_addr;
    bit<16>    ether_type;
}

header ipv4_h {
    bit<4>      version;
    bit<4>      ihl;
    bit<8>      diffserv;
    bit<16>     total_len;
    bit<16>     identification;
    bit<3>      flags;
    bit<13>     frag_offset;
    bit<8>      ttl;
    bit<8>      protocol;
    bit<16>     hdr_checksum;
    ipv4_addr_t src_addr;
    ipv4_addr_t dst_addr;
}

struct headers_t {
    ethernet_h ethernet;
    ipv4_h     ipv4;
}

struct metadata_t { }

/*************************************************************************
 * Ingress
 *************************************************************************/

parser IngressParser(packet_in pkt,
                     out headers_t hdr,
                     out metadata_t meta,
                     out ingress_intrinsic_metadata_t ig_intr_md) {
    state start {
        pkt.extract(ig_intr_md);
        pkt.advance(PORT_METADATA_SIZE);
        transition parse_ethernet;
    }

    state parse_ethernet {
        pkt.extract(hdr.ethernet);
        transition select(hdr.ethernet.ether_type) {
            ETHERTYPE_IPV4: parse_ipv4;
            default: accept;
        }
    }

    state parse_ipv4 {
        pkt.extract(hdr.ipv4);
        transition accept;
    }
}

control Ingress(inout headers_t hdr,
                inout metadata_t meta,
                in ingress_intrinsic_metadata_t ig_intr_md,
                in ingress_intrinsic_metadata_from_parser_t ig_prsr_md,
                inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
                inout ingress_intrinsic_metadata_for_tm_t ig_tm_md) {

    action drop() {
        ig_dprsr_md.drop_ctl = 1;
    }

    // Send the packet out of 'port', towards the next hop with MAC 'dst_mac'
    action route(PortId_t port, mac_addr_t src_mac, mac_addr_t dst_mac) {
        ig_tm_md.ucast_egress_port = port;
        hdr.ethernet.src_addr = src_mac;
        hdr.ethernet.dst_addr = dst_mac;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
    }

    table ipv4_lpm {
        key = {
            hdr.ipv4.dst_addr : lpm;
        }
        actions = {
            route;
            drop;
        }
        default_action = drop();
        size = 1024;
    }

    apply {
        if (hdr.ipv4.isValid() && hdr.ipv4.ttl > 1) {
            ipv4_lpm.apply();
        } else {
            drop();
        }
    }
}

control IngressDeparser(packet_out pkt,
                        inout headers_t hdr,
                        in metadata_t meta,
                        in ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md) {
    Checksum() ipv4_checksum;

    apply {
        // TTL changed, so the IPv4 header checksum must be recomputed
        hdr.ipv4.hdr_checksum = ipv4_checksum.update({
            hdr.ipv4.version,
            hdr.ipv4.ihl,
            hdr.ipv4.diffserv,
            hdr.ipv4.total_len,
            hdr.ipv4.identification,
            hdr.ipv4.flags,
            hdr.ipv4.frag_offset,
            hdr.ipv4.ttl,
            hdr.ipv4.protocol,
            hdr.ipv4.src_addr,
            hdr.ipv4.dst_addr
        });
        pkt.emit(hdr);
    }
}

/*************************************************************************
 * Egress: nothing to do, packets go out unchanged
 *************************************************************************/

struct egress_headers_t { }
struct egress_metadata_t { }

parser EgressParser(packet_in pkt,
                    out egress_headers_t hdr,
                    out egress_metadata_t meta,
                    out egress_intrinsic_metadata_t eg_intr_md) {
    state start {
        pkt.extract(eg_intr_md);
        transition accept;
    }
}

control Egress(inout egress_headers_t hdr,
               inout egress_metadata_t meta,
               in egress_intrinsic_metadata_t eg_intr_md,
               in egress_intrinsic_metadata_from_parser_t eg_prsr_md,
               inout egress_intrinsic_metadata_for_deparser_t eg_dprsr_md,
               inout egress_intrinsic_metadata_for_output_port_t eg_oport_md) {
    apply { }
}

control EgressDeparser(packet_out pkt,
                       inout egress_headers_t hdr,
                       in egress_metadata_t meta,
                       in egress_intrinsic_metadata_for_deparser_t eg_dprsr_md) {
    apply {
        pkt.emit(hdr);
    }
}

/*************************************************************************
 * Switch
 *************************************************************************/

Pipeline(IngressParser(), Ingress(), IngressDeparser(),
         EgressParser(), Egress(), EgressDeparser()) pipe;

Switch(pipe) main;
