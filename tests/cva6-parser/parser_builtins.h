/*
 * parser_builtins.h — dual-path shim: express the slice's raw-field prs_*(...)
 * calls through the patched-Clang __builtin_riscv_prs_* mnemonic-form builtins.
 *
 * Included by parser_slice.c ONLY under -DPRS_USE_BUILTINS (Phase 7 C2). The
 * slice body is unchanged; each prs_x(fields...) macro here dispatches — at
 * compile time, via __builtin_choose_expr on the constant size/E/dest/stp/er
 * fields — to the matching variant builtin, passing the remaining operands.
 * PRS_EMIT becomes a pass-through because the builtin emits the instruction
 * itself (an inline-asm carrying the prs.* mnemonic on the C0 MC layer).
 *
 * DRIFT ORACLE: the runner's 53-word byte-parity guard (parse_prog vs the model
 * enc.hex) proves this mapping encodes exactly what the intrinsics path does —
 * so a wrong dispatch fails loudly rather than silently diverging.
 *
 * size codes match the slice's SZ_* / the generated tsv:
 *   load, store, storeimm : b=1 h=2 w=3 d=0
 *   lenset family, cam    : n=0 b=1 h=2 w=3
 */
#ifndef PARSER_BUILTINS_H
#define PARSER_BUILTINS_H

/* The builtin lowers to the instruction; PRS_EMIT no longer plants a word. */
#undef PRS_EMIT
#define PRS_EMIT(x) (x)

/* prs.load — variant by (size, E); operand: offset. */
#define prs_load(sz, e, off) \
  __builtin_choose_expr((e), \
    __builtin_choose_expr((sz)==1, __builtin_riscv_prs_load_b_be(off), \
    __builtin_choose_expr((sz)==2, __builtin_riscv_prs_load_h_be(off), \
    __builtin_choose_expr((sz)==3, __builtin_riscv_prs_load_w_be(off), \
                                   __builtin_riscv_prs_load_d_be(off)))), \
    __builtin_choose_expr((sz)==1, __builtin_riscv_prs_load_b(off), \
    __builtin_choose_expr((sz)==2, __builtin_riscv_prs_load_h(off), \
    __builtin_choose_expr((sz)==3, __builtin_riscv_prs_load_w(off), \
                                   __builtin_riscv_prs_load_d(off)))))

/* prs.store — variant by size; operands: pos, offset. */
#define prs_store(sz, pos, off) \
  __builtin_choose_expr((sz)==1, __builtin_riscv_prs_store_b(pos, off), \
  __builtin_choose_expr((sz)==2, __builtin_riscv_prs_store_h(pos, off), \
  __builtin_choose_expr((sz)==3, __builtin_riscv_prs_store_w(pos, off), \
                                 __builtin_riscv_prs_store_d(pos, off))))

/* prs.storeimm — variant by size; operands: value, offset. */
#define prs_storeimm(sz, value, off) \
  __builtin_choose_expr((sz)==1, __builtin_riscv_prs_storeimm_b(value, off), \
  __builtin_choose_expr((sz)==2, __builtin_riscv_prs_storeimm_h(value, off), \
  __builtin_choose_expr((sz)==3, __builtin_riscv_prs_storeimm_w(value, off), \
                                 __builtin_riscv_prs_storeimm_d(value, off))))

/* prs.lensetconst — variant by size (never .stp from this path); operand: len. */
#define prs_lensetconst(sz, len) \
  __builtin_choose_expr((sz)==0, __builtin_riscv_prs_lensetconst_n(len), \
  __builtin_choose_expr((sz)==1, __builtin_riscv_prs_lensetconst_b(len), \
  __builtin_choose_expr((sz)==2, __builtin_riscv_prs_lensetconst_h(len), \
                                 __builtin_riscv_prs_lensetconst_w(len))))

/* prs.lenset — variant by size; operands: pos, shift, len. */
#define prs_lenset(sz, pos, shift, len) \
  __builtin_choose_expr((sz)==0, __builtin_riscv_prs_lenset_n(pos, shift, len), \
  __builtin_choose_expr((sz)==1, __builtin_riscv_prs_lenset_b(pos, shift, len), \
  __builtin_choose_expr((sz)==2, __builtin_riscv_prs_lenset_h(pos, shift, len), \
                                 __builtin_riscv_prs_lenset_w(pos, shift, len))))

/* prs.lensetmin — variant by size; operands: pos, shift, len. */
#define prs_lensetmin(sz, pos, shift, len) \
  __builtin_choose_expr((sz)==0, __builtin_riscv_prs_lensetmin_n(pos, shift, len), \
  __builtin_choose_expr((sz)==1, __builtin_riscv_prs_lensetmin_b(pos, shift, len), \
  __builtin_choose_expr((sz)==2, __builtin_riscv_prs_lensetmin_h(pos, shift, len), \
                                 __builtin_riscv_prs_lensetmin_w(pos, shift, len))))

/* prs.cam — variant by (size, dest d: 0=paccum/1=pnext, stp s); ops: pos,f,share,miss. */
#define PRS__CAM_SZ(suf, sz, pos, f, share, miss) \
  __builtin_choose_expr((sz)==0, __builtin_riscv_prs_cam_n##suf(pos, f, share, miss), \
  __builtin_choose_expr((sz)==1, __builtin_riscv_prs_cam_b##suf(pos, f, share, miss), \
  __builtin_choose_expr((sz)==2, __builtin_riscv_prs_cam_h##suf(pos, f, share, miss), \
                                 __builtin_riscv_prs_cam_w##suf(pos, f, share, miss))))
#define prs_cam(d, s, sz, pos, f, share, miss) \
  __builtin_choose_expr((s), \
    __builtin_choose_expr((d), PRS__CAM_SZ(_stp_pnext,  sz, pos, f, share, miss), \
                               PRS__CAM_SZ(_stp_paccum, sz, pos, f, share, miss)), \
    __builtin_choose_expr((d), PRS__CAM_SZ(_pnext,      sz, pos, f, share, miss), \
                               PRS__CAM_SZ(_paccum,     sz, pos, f, share, miss)))

/* prs.cmpib / prs.cmpneib — variant by er action; ops: pos, value, mask. */
#define prs_cmpib(er, pos, value, mask) \
  __builtin_choose_expr((er)==0, __builtin_riscv_prs_cmpib_stop(pos, value, mask), \
  __builtin_choose_expr((er)==1, __builtin_riscv_prs_cmpib_stopnode(pos, value, mask), \
  __builtin_choose_expr((er)==2, __builtin_riscv_prs_cmpib_stopsub(pos, value, mask), \
                                 __builtin_riscv_prs_cmpib_fail(pos, value, mask))))
#define prs_cmpneib(er, pos, value, mask) \
  __builtin_choose_expr((er)==0, __builtin_riscv_prs_cmpneib_stop(pos, value, mask), \
  __builtin_choose_expr((er)==1, __builtin_riscv_prs_cmpneib_stopnode(pos, value, mask), \
  __builtin_choose_expr((er)==2, __builtin_riscv_prs_cmpneib_stopsub(pos, value, mask), \
                                 __builtin_riscv_prs_cmpneib_fail(pos, value, mask))))

/* prs.nextnode / prs.setcode / prs.stp — no folded discriminator. */
#define prs_nextnode(payload) __builtin_riscv_prs_nextnode(payload)
#define prs_setcode(payload)  __builtin_riscv_prs_setcode(payload)
#define prs_stp()             __builtin_riscv_prs_stp()

#endif /* PARSER_BUILTINS_H */
