/*
 * parser_moves.c — Phase 7 C3: functional round-trip of the parser p-registers
 * through the Clang custom-3 move builtins (__builtin_riscv_prs_mv_p_x /
 * __builtin_riscv_prs_mv_x_p / prs_cam_read / prs_array_read).
 *
 * The C twin of tests/cva6-parser/parser_ctxsw_v10.S: it writes values into the
 * writable p-registers via the WRITE builtin and reads them back via the READ
 * builtin, asserting the value survives — proving the register-operand builtins
 * genuinely carry values through Clang's register allocation (not just that the
 * right mnemonic is emitted; that is the structural table parser-clang-moves.tsv).
 * Two layers: a directed WAW / sign-extend check, and a deterministic randomized
 * property loop over the full-64-bit p-registers (the "fuzz the register path"
 * analog — model-fuzz proper stays model-scoped, since C3 changes no model code).
 *
 * Bare-metal, self-checking: _start sets sp and calls moves_main, which writes the
 * result to the fesvr HTIF `tohost` (=1 => Spike exit 0 => PASS, else an odd fail
 * code). Assemble with htif.S + link.ld and run on the standalone parser Spike.
 *
 * The p-registers exercised (model/libparsermodel; isa/parser-opcodes.yaml):
 *   p15 paccum, p16 pflags — full 64-bit, lossless round-trip.
 *   p11 pnext             — 32-bit field, SIGN-extended on read.
 */
#include <stdint.h>

extern volatile uint64_t tohost;      /* htif.S — fesvr polls it (1 => exit 0 => PASS) */

/* Bare-metal stack (8 KiB); _start points sp at its top. */
unsigned long g_moves_stack[1024];

/* p-register selectors (Cpreg[28:24]); must be compile-time constants (the builtin's
 * first arg is _Constant — baked into the mnemonic as p<N> by CodeGen). */
#define P_ACCUM 15u
#define P_FLAGS 16u
#define P_NEXT  11u

/* PASS = 1 (tohost=1 => fesvr exit 0); FAIL = an odd code > 1 (fesvr exit (code>>1)). */
#define PASS         1
#define FAIL_WAW     3
#define FAIL_ACCUM   5
#define FAIL_FLAGS   7
#define FAIL_NEXT_SX 9

/* write V into p-register PREG, read it straight back (both via the C3 builtins). */
#define RT64(PREG, V) \
    (__builtin_riscv_prs_mv_p_x((PREG), (uint64_t)(V)), __builtin_riscv_prs_mv_x_p((PREG)))

/* xorshift64 — deterministic in-core PRNG (fixed seed => reproducible CI gate). */
static uint64_t xrng(uint64_t *s)
{
    uint64_t x = *s;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    *s = x;
    return x;
}

static int run_checks(void)
{
    /* --- directed: write-after-write, last writer wins (p16 Flags), like parser_insn.S --- */
    __builtin_riscv_prs_mv_p_x(P_FLAGS, 0x11u);
    __builtin_riscv_prs_mv_p_x(P_FLAGS, 0x22u);          /* younger write wins */
    if (__builtin_riscv_prs_mv_x_p(P_FLAGS) != 0x22u)
        return FAIL_WAW;

    /* --- directed: p11 Next is a 32-bit field, SIGN-extended on read --- */
    __builtin_riscv_prs_mv_p_x(P_NEXT, 0x80000000ull);
    if (__builtin_riscv_prs_mv_x_p(P_NEXT) != 0xFFFFFFFF80000000ull)
        return FAIL_NEXT_SX;

    /* --- randomized property round-trip over the full-64-bit p-registers --- */
    uint64_t s = 0x0123456789abcdefull;
    for (int i = 0; i < 256; i++) {
        uint64_t a = xrng(&s);
        if (RT64(P_ACCUM, a) != a)
            return FAIL_ACCUM;
        uint64_t f = xrng(&s);
        if (RT64(P_FLAGS, f) != f)
            return FAIL_FLAGS;
    }

    /* --- exercise the CAM/array READ builtins on Spike (unprogrammed => miss); we do not
     *     assert the value (no builtin CAM-write path), only that they compile + run. --- */
    volatile uint64_t sink;
    sink = __builtin_riscv_prs_cam_read(P_ACCUM, 0x00010800u);
    sink = __builtin_riscv_prs_array_read(P_ACCUM, 0x00010800u);
    (void)sink;

    return PASS;
}

__attribute__((used, noreturn))
void moves_main(void)
{
    tohost = (uint64_t)run_checks();
    for (;;) { }
}

/* _start: set sp to the top of g_moves_stack, call moves_main (never returns). In
 * .text.init so it lands first at the DRAM base (0x80000000), per link.ld. */
__asm__(
    ".section .text.init            \n"
    ".globl _start                  \n"
    "_start:                        \n"
    "  la   sp, g_moves_stack       \n"
    "  li   t0, 8192                 \n"
    "  add  sp, sp, t0              \n"
    "  call moves_main              \n"
    "1:j    1b                       \n"
    ".text                          \n"
);
