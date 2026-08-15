/*
 * program.c — the vertical-slice parse program as a decoded-instruction table.
 *
 * This is the reference *program* (Phase-2 §2.2): Ethernet -> IPv4/IPv6 ->
 * TCP/UDP, populating a flow_keys. It is authored knowing the flow_keys layout
 * (as a real parser knows its metadata-frame layout) and the node start indices
 * (node "addresses"). The same table is what Phase-3 encodes to bits and Phase-6
 * runs on RTL.
 *
 * Scope: the smoke path. IPv4 options / IPv6 extension-header TLV loops / VLAN
 * stacking (loop heads + camjumptlvloop + overlay) are the follow-up.
 */
#include "parser.h"
#include <stddef.h>

/* Sz encodings (load/store: 0=8B,1=byte,2=half,3=word). */
#define SZ_B 1
#define SZ_H 2
#define SZ_W 3
#define SZ_N 0   /* nibble (sub-register extract) */
#define SZ_DW 0  /* 8 bytes (load/store) */

#define OFF(field) ((uint32_t)offsetof(struct flow_keys, field))

/* Node start indices ("addresses"). Keep in sync with prog[] order below. */
enum {
    N_ETHER = 0,
    N_IPV4  = 3,
    N_IPV6  = 14,
    N_TCP   = 27,
    N_UDP   = 32,
};

/* CAM tables. share!=0 -> shared table id. */
static const struct cam_entry eth_ents[] = {
    { .share = 1, .match = 0x0800, .target = N_IPV4 },   /* IPv4 */
    { .share = 1, .match = 0x86DD, .target = N_IPV6 },   /* IPv6 */
};
static const struct cam_entry proto_ents[] = {
    { .share = 2, .match = 6,  .target = N_TCP },        /* TCP */
    { .share = 2, .match = 17, .target = N_UDP },        /* UDP */
};
static const struct cam_table eth_tbl   = { eth_ents,   sizeof(eth_ents)/sizeof(eth_ents[0]) };
static const struct cam_table proto_tbl = { proto_ents, sizeof(proto_ents)/sizeof(proto_ents[0]) };

static const instr prog[] = {
    /* ---- ether_node @0 ---- */
    [N_ETHER+0] = { .op = OP_LOAD,    .sz = SZ_H, .e = 1, .offset = 12 },              /* EtherType -> Accum (grows CurHdr.Length to 14) */
    [N_ETHER+1] = { .op = OP_STORE,   .sz = SZ_H, .pos = 0, .offset = OFF(n_proto) },  /* -> flow_keys.n_proto */
    [N_ETHER+2] = { .op = OP_CAMNEXT, .sz = SZ_H, .pos = 0, .share = 1, .cam = &eth_tbl, .miss = MISS_STOP, .s = 1 },

    /* ---- ipv4_node @3 ---- */
    [N_IPV4+0]  = { .op = OP_LOAD,    .sz = SZ_B, .offset = 0 },                       /* version+IHL byte */
    [N_IPV4+1]  = { .op = OP_LENCUR,  .d = 1, .sz = SZ_N, .pos = 1, .shift = 2, .value = 20 }, /* CurHdr.Length = IHL*4, min 20 */
    [N_IPV4+2]  = { .op = OP_CMPIB,   .pos = 0, .value = 0x40, .mask = 0xF0, .er = ER_FAIL },  /* version == 4 */
    [N_IPV4+3]  = { .op = OP_LOAD,    .sz = SZ_W, .e = 1, .offset = 12 },              /* src addr */
    [N_IPV4+4]  = { .op = OP_STORE,   .sz = SZ_W, .pos = 0, .offset = OFF(ipv4_src) },
    [N_IPV4+5]  = { .op = OP_LOAD,    .sz = SZ_W, .e = 1, .offset = 16 },              /* dst addr */
    [N_IPV4+6]  = { .op = OP_STORE,   .sz = SZ_W, .pos = 0, .offset = OFF(ipv4_dst) },
    [N_IPV4+7]  = { .op = OP_STOREIMM,.sz = SZ_B, .value = 4, .offset = OFF(addr_type) },
    [N_IPV4+8]  = { .op = OP_LOAD,    .sz = SZ_B, .offset = 9 },                       /* IP protocol */
    [N_IPV4+9]  = { .op = OP_STORE,   .sz = SZ_B, .pos = 0, .offset = OFF(ip_proto) },
    [N_IPV4+10] = { .op = OP_CAMNEXT, .sz = SZ_B, .pos = 0, .share = 2, .cam = &proto_tbl, .miss = MISS_STOP, .s = 1 },

    /* ---- ipv6_node @14 (fixed 40-byte header; ext headers deferred) ---- */
    [N_IPV6+0]  = { .op = OP_LENCUR,  .shift = 7, .value = 40 },                       /* constant length 40 */
    [N_IPV6+1]  = { .op = OP_STOREIMM,.sz = SZ_B, .value = 6, .offset = OFF(addr_type) },
    [N_IPV6+2]  = { .op = OP_LOAD,    .sz = SZ_DW, .e = 0, .offset = 8 },              /* src[0..7]  */
    [N_IPV6+3]  = { .op = OP_STORE,   .sz = SZ_DW, .offset = OFF(ipv6_src) },
    [N_IPV6+4]  = { .op = OP_LOAD,    .sz = SZ_DW, .e = 0, .offset = 16 },             /* src[8..15] */
    [N_IPV6+5]  = { .op = OP_STORE,   .sz = SZ_DW, .offset = OFF(ipv6_src) + 8 },
    [N_IPV6+6]  = { .op = OP_LOAD,    .sz = SZ_DW, .e = 0, .offset = 24 },             /* dst[0..7]  */
    [N_IPV6+7]  = { .op = OP_STORE,   .sz = SZ_DW, .offset = OFF(ipv6_dst) },
    [N_IPV6+8]  = { .op = OP_LOAD,    .sz = SZ_DW, .e = 0, .offset = 32 },             /* dst[8..15] */
    [N_IPV6+9]  = { .op = OP_STORE,   .sz = SZ_DW, .offset = OFF(ipv6_dst) + 8 },
    [N_IPV6+10] = { .op = OP_LOAD,    .sz = SZ_B, .offset = 6 },                       /* Next Header */
    [N_IPV6+11] = { .op = OP_STORE,   .sz = SZ_B, .pos = 0, .offset = OFF(ip_proto) },
    [N_IPV6+12] = { .op = OP_CAMNEXT, .sz = SZ_B, .pos = 0, .share = 2, .cam = &proto_tbl, .miss = MISS_STOP, .s = 1 },

    /* ---- tcp_node @27 ---- */
    [N_TCP+0]   = { .op = OP_LOAD,    .sz = SZ_H, .e = 1, .offset = 0 },               /* sport */
    [N_TCP+1]   = { .op = OP_STORE,   .sz = SZ_H, .pos = 0, .offset = OFF(sport) },
    [N_TCP+2]   = { .op = OP_LOAD,    .sz = SZ_H, .e = 1, .offset = 2 },               /* dport */
    [N_TCP+3]   = { .op = OP_STORE,   .sz = SZ_H, .pos = 0, .offset = OFF(dport) },
    [N_TCP+4]   = { .op = OP_STP },                                                    /* no Next -> STOP_OKAY */

    /* ---- udp_node @32 ---- */
    [N_UDP+0]   = { .op = OP_LOAD,    .sz = SZ_H, .e = 1, .offset = 0 },
    [N_UDP+1]   = { .op = OP_STORE,   .sz = SZ_H, .pos = 0, .offset = OFF(sport) },
    [N_UDP+2]   = { .op = OP_LOAD,    .sz = SZ_H, .e = 1, .offset = 2 },
    [N_UDP+3]   = { .op = OP_STORE,   .sz = SZ_H, .pos = 0, .offset = OFF(dport) },
    [N_UDP+4]   = { .op = OP_STP },
};

const instr *pm_slice_program(size_t *n)
{
    *n = sizeof(prog) / sizeof(prog[0]);
    return prog;
}
