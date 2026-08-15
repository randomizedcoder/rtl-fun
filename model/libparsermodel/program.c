/*
 * program.c — the parse program as a decoded-instruction table.
 *
 * This is the reference *program* (Phase-2 §2.2): Ethernet -> [VLAN...] ->
 * IPv4/IPv6 -> [IPv6 ext headers...] -> TCP/UDP, populating a flow_keys. It is
 * authored knowing the flow_keys layout (as a real parser knows its metadata
 * frame) and the node start indices (node "addresses"). The same table is what
 * Phase-3 encodes to bits and Phase-6 runs on RTL.
 *
 * Coverage: eth, 802.1Q/802.1ad VLAN (incl. stacked), IPv4 (incl. options via
 * IHL), IPv6 (incl. hop-by-hop/routing/dest-opt/fragment extension headers),
 * TCP, UDP. True TLV *extraction* (DataHdr/Loop/DataBound with camjumptlvloop)
 * and flag-fields (GRE) remain the follow-up — flow_keys needs neither.
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

/* IP protocol / IPv6 next-header numbers used by the CAM tables. */
enum {
    IPPROTO_HOPOPTS  = 0,    /* IPv6 hop-by-hop options   */
    IPPROTO_TCP      = 6,
    IPPROTO_UDP      = 17,
    IPPROTO_ROUTING  = 43,   /* IPv6 routing header       */
    IPPROTO_FRAGMENT = 44,   /* IPv6 fragment header      */
    IPPROTO_NONE     = 59,   /* IPv6 "no next header"     */
    IPPROTO_DSTOPTS  = 60,   /* IPv6 destination options  */
};

/* EtherTypes. */
enum {
    ETH_P_IP     = 0x0800,
    ETH_P_IPV6   = 0x86DD,
    ETH_P_8021Q  = 0x8100,   /* C-VLAN */
    ETH_P_8021AD = 0x88A8,   /* S-VLAN (QinQ) */
};

/* Node start indices ("addresses"). Keep in sync with prog[] order below. */
enum {
    N_ETHER   = 0,
    N_IPV4    = 3,
    N_IPV6    = 14,
    N_TCP     = 27,
    N_UDP     = 32,
    N_VLAN    = 37,
    N_IP6EXT  = 41,   /* generic ext header (HBH / routing / dest-opts) */
    N_IP6FRAG = 47,   /* fragment header (fixed 8 bytes)                */
    N_DONE    = 52,   /* "no next header" -> clean STOP_OKAY            */
};

/* CAM tables. share!=0 -> shared table id. */

/* EtherType table (share=1): used by ether_node AND vlan_node, so a VLAN tag
 * nesting another VLAN tag (QinQ / stacking) loops back to vlan_node. */
static const struct cam_entry eth_ents[] = {
    { .share = 1, .match = ETH_P_IP,     .target = N_IPV4 },
    { .share = 1, .match = ETH_P_IPV6,   .target = N_IPV6 },
    { .share = 1, .match = ETH_P_8021Q,  .target = N_VLAN },
    { .share = 1, .match = ETH_P_8021AD, .target = N_VLAN },
};

/* IPv4 next-protocol table (share=2). */
static const struct cam_entry proto_ents[] = {
    { .share = 2, .match = IPPROTO_TCP, .target = N_TCP },
    { .share = 2, .match = IPPROTO_UDP, .target = N_UDP },
};

/* IPv6 next-header table (share=3): includes the extension headers, so the
 * IPv6 node and every ext-header node route the chain through one table. */
static const struct cam_entry ip6nh_ents[] = {
    { .share = 3, .match = IPPROTO_HOPOPTS,  .target = N_IP6EXT },
    { .share = 3, .match = IPPROTO_ROUTING,  .target = N_IP6EXT },
    { .share = 3, .match = IPPROTO_DSTOPTS,  .target = N_IP6EXT },
    { .share = 3, .match = IPPROTO_FRAGMENT, .target = N_IP6FRAG },
    { .share = 3, .match = IPPROTO_TCP,      .target = N_TCP },
    { .share = 3, .match = IPPROTO_UDP,      .target = N_UDP },
    { .share = 3, .match = IPPROTO_NONE,     .target = N_DONE },
};

static const struct cam_table eth_tbl   = { eth_ents,   sizeof(eth_ents)/sizeof(eth_ents[0]) };
static const struct cam_table proto_tbl = { proto_ents, sizeof(proto_ents)/sizeof(proto_ents[0]) };
static const struct cam_table ip6nh_tbl = { ip6nh_ents, sizeof(ip6nh_ents)/sizeof(ip6nh_ents[0]) };

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

    /* ---- ipv6_node @14 (fixed 40-byte header; ext headers via ip6nh_tbl) ---- */
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
    [N_IPV6+12] = { .op = OP_CAMNEXT, .sz = SZ_B, .pos = 0, .share = 3, .cam = &ip6nh_tbl, .miss = MISS_STOP, .s = 1 },

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

    /* ---- vlan_node @37 (802.1Q/802.1ad) ---- *
     * Entered with CurHdr.Offset past the TPID (the ether/vlan node CAM'd the
     * TPID as its "ethertype"); the remaining tag is TCI(2)+innerEtherType(2). */
    [N_VLAN+0]  = { .op = OP_LOAD,    .sz = SZ_H, .e = 1, .offset = 2 },               /* inner EtherType */
    [N_VLAN+1]  = { .op = OP_STORE,   .sz = SZ_H, .pos = 0, .offset = OFF(n_proto) },
    [N_VLAN+2]  = { .op = OP_LENCUR,  .shift = 7, .value = 4 },                        /* tag remainder = 4 bytes */
    [N_VLAN+3]  = { .op = OP_CAMNEXT, .sz = SZ_H, .pos = 0, .share = 1, .cam = &eth_tbl, .miss = MISS_STOP, .s = 1 },

    /* ---- ip6ext_node @41 (HBH / routing / dest-opts: len = (ExtLen+1)*8) ---- */
    [N_IP6EXT+0]= { .op = OP_LOAD,    .sz = SZ_B, .offset = 0 },                       /* Next Header */
    [N_IP6EXT+1]= { .op = OP_STORE,   .sz = SZ_B, .pos = 0, .offset = OFF(ip_proto) }, /* track final proto */
    [N_IP6EXT+2]= { .op = OP_LOAD,    .sz = SZ_B, .offset = 1 },                       /* Hdr Ext Len */
    [N_IP6EXT+3]= { .op = OP_LENCUR,  .d = 0, .sz = SZ_B, .pos = 0, .shift = 3, .value = 8 }, /* (ExtLen<<3)+8 */
    [N_IP6EXT+4]= { .op = OP_LOAD,    .sz = SZ_B, .offset = 0 },                       /* reload NH for CAM key */
    [N_IP6EXT+5]= { .op = OP_CAMNEXT, .sz = SZ_B, .pos = 0, .share = 3, .cam = &ip6nh_tbl, .miss = MISS_STOP, .s = 1 },

    /* ---- ip6frag_node @47 (fragment header: fixed 8 bytes) ---- */
    [N_IP6FRAG+0]={ .op = OP_LOAD,    .sz = SZ_B, .offset = 0 },                       /* Next Header */
    [N_IP6FRAG+1]={ .op = OP_STORE,   .sz = SZ_B, .pos = 0, .offset = OFF(ip_proto) },
    [N_IP6FRAG+2]={ .op = OP_LENCUR,  .shift = 7, .value = 8 },                        /* constant length 8 */
    [N_IP6FRAG+3]={ .op = OP_LOAD,    .sz = SZ_B, .offset = 0 },                       /* reload NH for CAM key */
    [N_IP6FRAG+4]={ .op = OP_CAMNEXT, .sz = SZ_B, .pos = 0, .share = 3, .cam = &ip6nh_tbl, .miss = MISS_STOP, .s = 1 },

    /* ---- done_node @52 ("no next header") ---- */
    [N_DONE+0]  = { .op = OP_STP },                                                    /* clean STOP_OKAY */
};

const instr *pm_slice_program(size_t *n)
{
    *n = sizeof(prog) / sizeof(prog[0]);
    return prog;
}
