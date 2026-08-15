/*
 * pm-trace — single-step tracer for the golden parser model (libparsermodel).
 *
 * A debugging companion to model/: it runs the slice program over one frame and
 * prints the machine state before every instruction, plus the final flow_keys
 * and exit code. Use it to retrace a parse when a corpus/unit test regresses.
 *
 *   pm-trace                 # trace a canned Ethernet+IPv4+TCP frame
 *   pm-trace <file.pcap>     # trace the first packet of a classic pcap
 *
 * Build (from repo root):
 *   nix run .#pm-trace -- [file.pcap]
 * or directly:
 *   gcc -I model/libparsermodel tools/pm-trace/pm-trace.c \
 *       model/libparsermodel/parser.c model/libparsermodel/program.c \
 *       model/libparsermodel/pcap.c -o pm-trace
 */
#include "parser.h"
#include "pcap.h"
#include <stdio.h>
#include <string.h>

static const char *op_name(enum opcode op)
{
    static const char *names[] = {
        "INITPARSER", "LOAD", "LENCUR", "CMPIB", "CMPINEB", "CMPORD",
        "CAM", "CAMNEXT", "STORE", "STOREIMM", "NEXTNODE", "SETCODE", "STP",
    };
    return (op < OP__COUNT) ? names[op] : "??";
}

static void trace_hook(const void *psv, const void *inv, void *ctx)
{
    const pstate *ps = psv;
    const instr *in = inv;
    (void)ctx;
    printf("  pc=%2u %-9s off=%u  cur[off=%u len=%u] dat[off=%u len=%u] "
           "bound=%08x loop=%d next=%08x accum=%016llx\n",
           ps->pc, op_name(in->op), in->offset,
           ps->cur.off, ps->cur.len, ps->dat.off, ps->dat.len,
           ps->databound, ps->loop, (uint32_t)ps->next,
           (unsigned long long)ps->accum);
}

/* Canned Ethernet + IPv4(IHL=5) + TCP frame, 42 bytes. */
static uint32_t canned_frame(uint8_t *b)
{
    memset(b, 0, 128);
    b[0]=0x02; b[5]=0x02; b[6]=0x02; b[11]=0x01; b[12]=0x08; b[13]=0x00; /* eth */
    uint8_t *ip = b + 14;
    ip[0]=0x45; ip[9]=6;                       /* v4/IHL5, proto TCP */
    ip[12]=10; ip[15]=1; ip[16]=10; ip[19]=2;  /* 10.0.0.1 -> 10.0.0.2 */
    uint8_t *l4 = ip + 20;
    l4[0]=0x12; l4[1]=0x34; l4[2]=0x00; l4[3]=0x50; /* sport 0x1234 dport 80 */
    return 42;
}

int main(int argc, char **argv)
{
    uint8_t pkt[2048];
    uint32_t len;

    if (argc > 1) {
        uint32_t lt = 0;
        int n = pcap_read_first(argv[1], pkt, sizeof(pkt), &lt);
        if (n <= 0) { fprintf(stderr, "pm-trace: cannot read %s (err %d)\n", argv[1], n); return 2; }
        if (lt != 1) fprintf(stderr, "pm-trace: warning: linktype %u (expected 1=Ethernet)\n", lt);
        len = (uint32_t)n;
        printf("== trace %s (%u bytes, linktype %u) ==\n", argv[1], len, lt);
    } else {
        len = canned_frame(pkt);
        printf("== trace canned eth+ipv4+tcp (%u bytes) ==\n", len);
    }

    struct flow_keys fk;
    pstate ps;
    pm_init(&ps, pkt, len, &fk);
    ps.trace = trace_hook;

    size_t n;
    const instr *prog = pm_slice_program(&n);
    int32_t code = pm_run(&ps, prog, n);

    printf("\nexit code = %d   cur.off=%u\n", code, ps.cur.off);
    printf("flow_keys: n_proto=0x%04x addr_type=%u ip_proto=%u\n",
           fk.n_proto, fk.addr_type, fk.ip_proto);
    printf("           ipv4 %u.%u.%u.%u -> %u.%u.%u.%u  sport=%u dport=%u\n",
           (fk.ipv4_src>>24)&0xff,(fk.ipv4_src>>16)&0xff,(fk.ipv4_src>>8)&0xff,fk.ipv4_src&0xff,
           (fk.ipv4_dst>>24)&0xff,(fk.ipv4_dst>>16)&0xff,(fk.ipv4_dst>>8)&0xff,fk.ipv4_dst&0xff,
           fk.sport, fk.dport);
    return code == P_STOP_OKAY ? 0 : 1;
}
