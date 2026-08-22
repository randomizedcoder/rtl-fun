/*
 * trans_parser.c.inc — TCG translation of the parser custom instructions (Phase 7
 * QEMU leg). #included from target/riscv/translate.c after decode-insn32.c.inc
 * (which forward-declares trans_parser_c0/trans_parser_c3 from the two catch-all
 * patterns added to insn32.decode). The heavy lifting is in the helpers
 * (parser_helper.c); these just wire decode -> helper -> control flow.
 */

/* custom-0 (0x0b): a PC-redirecting parse micro-op. The helper steps the model
 * and returns the absolute next guest PC; we end the TB with a computed jump,
 * mirroring trans_jalr (mov cpu_pc, lookup_and_goto_ptr, DISAS_NORETURN). The
 * whole 32-bit word is passed via ctx->opcode (custom-0 has a non-standard field
 * layout the helper decodes with the model's pm_decode). Writes no rd. */
static bool trans_parser_c0(DisasContext *ctx, arg_parser_c0 *a)
{
    TCGv nextpc = tcg_temp_new();

    /* Save the opcode into insn_start so a helper-raised illegal instruction
     * reports the right mtval (as the fp/csr ops do before their helpers). */
    decode_save_opc(ctx, 0);
    gen_helper_parser_c0(nextpc, tcg_env,
                         tcg_constant_i32(ctx->opcode),
                         tcg_constant_tl(ctx->base.pc_next));
    tcg_gen_mov_tl(cpu_pc, nextpc);
    lookup_and_goto_ptr(ctx);
    ctx->base.is_jmp = DISAS_NORETURN;
    return true;
}

/* custom-3 (0x7b): coprocessor moves. The helper reads rs1 / writes rd from
 * env->gpr directly (the helper is not TCG_CALL_NO_WG, so TCG reloads the gpr
 * globals afterwards). Never redirects -> fall through to the next insn. */
static bool trans_parser_c3(DisasContext *ctx, arg_parser_c3 *a)
{
    decode_save_opc(ctx, 0);
    gen_helper_parser_c3(tcg_env, tcg_constant_i32(ctx->opcode));
    return true;
}
