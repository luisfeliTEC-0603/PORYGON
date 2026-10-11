import pkg_vliw::*;

/**
 * @brief Etapa Decode/Dispatch del pipeline VLIW.
 *
 * @details
 * Integra:
 *   1. bundle_splitter : parte el bundle en 4 slots.
 *   2. imm_mux (×4)    : reemplaza inmediatos por NOP.
 *   3. pipe_gate (×5)  : enruta slots a ALU0, ALU1, LSU, BRU, CRYPTO.
 *   4. nop_detector(×5): marca NOPs por pipe.
 *   5. imm_router (×5) : calcula el inmediato asociado a cada pipe.
 *   6. rf_addr_gen (×5): genera direcciones de operandos por pipe.
 *
 * @param BUNDLE_WIDTH Ancho del bundle.
 * @param SLOT_WIDTH   Ancho del slot.
 * @param NUM_SLOTS    Número de slots.
 *
 * @input  bundle_i Bundle VLIW de 64 bits.
 *
 * @output alu0_slot_o       Slot para ALU0.
 * @output alu0_nop_flag_o   '1' si ALU0 debe ejecutar NOP.
 * @output alu0_imm_o        Inmediato asociado a ALU0.
 * @output alu0_op_a_addr_o  Dirección del operando A de ALU0.
 * @output alu0_op_b_addr_o  Dirección del operando B de ALU0.
 * ... (análogo para ALU1, LSU, BRU, CRYPTO)
 */

module idd_stage #(
    parameter integer BUNDLE_WIDTH = pkg_vliw::BUNDLE_WIDTH,
    parameter integer SLOT_WIDTH   = pkg_vliw::SLOT_WIDTH,
    parameter integer NUM_SLOTS    = pkg_vliw::NUM_SLOTS
) (
    input  logic [BUNDLE_WIDTH-1:0] bundle_i,

    // ---- ALU0 ----
    output logic [SLOT_WIDTH-1:0]   alu0_slot_o,
    output logic                    alu0_nop_flag_o,
    output logic [SLOT_WIDTH-1:0]   alu0_imm_o,
    output logic [2:0]              alu0_op_a_addr_o,
    output logic [2:0]              alu0_op_b_addr_o,

    // ---- ALU1 ----
    output logic [SLOT_WIDTH-1:0]   alu1_slot_o,
    output logic                    alu1_nop_flag_o,
    output logic [SLOT_WIDTH-1:0]   alu1_imm_o,
    output logic [2:0]              alu1_op_a_addr_o,
    output logic [2:0]              alu1_op_b_addr_o,

    // ---- LSU ----
    output logic [SLOT_WIDTH-1:0]   lsu_slot_o,
    output logic                    lsu_nop_flag_o,
    output logic [SLOT_WIDTH-1:0]   lsu_imm_o,
    output logic [2:0]              lsu_op_a_addr_o,
    output logic [2:0]              lsu_op_b_addr_o,

    // ---- BRU ----
    output logic [SLOT_WIDTH-1:0]   bru_slot_o,
    output logic                    bru_nop_flag_o,
    output logic [SLOT_WIDTH-1:0]   bru_imm_o,
    output logic [2:0]              bru_op_a_addr_o,
    output logic [2:0]              bru_op_b_addr_o,

    // ---- CRYPTO ----
    output logic [SLOT_WIDTH-1:0]   crypto_slot_o,
    output logic                    crypto_nop_flag_o,
    output logic [SLOT_WIDTH-1:0]   crypto_imm_o,
    output logic [2:0]              crypto_op_a_addr_o,
    output logic [2:0]              crypto_op_b_addr_o
);

    // Señales internas
    logic [SLOT_WIDTH-1:0] slot_raw   [0:NUM_SLOTS-1];
    logic [SLOT_WIDTH-1:0] slot_clean [0:NUM_SLOTS-1];

    logic is_imm_0, is_imm_1, is_imm_2, is_imm_3;
    logic is_imm_1_raw, is_imm_2_raw, is_imm_3_raw;

    logic [SLOT_WIDTH-1:0] alu0_slot, alu1_slot, lsu_slot, bru_slot, crypto_slot;
    logic [1:0]            alu0_idx,  alu1_idx,  lsu_idx,  bru_idx,  crypto_idx;
    logic                  alu0_match, alu1_match, lsu_match, bru_match, crypto_match;

    logic [SLOT_WIDTH-1:0] alu0_imm, alu1_imm, lsu_imm, bru_imm, crypto_imm;

    // ------------------------------------------------------------------------
    // 1. Partir el bundle
    // ------------------------------------------------------------------------
    bundle_splitter #(
        .BUNDLE_WIDTH (BUNDLE_WIDTH),
        .SLOT_WIDTH   (SLOT_WIDTH),
        .NUM_SLOTS    (NUM_SLOTS)
    ) u_splitter (
        .bundle_i (bundle_i),
        .slot_o   (slot_raw)
    );

    // ------------------------------------------------------------------------
    // 2. Selectores de inmediato con corte de cadena
    // ------------------------------------------------------------------------
    assign is_imm_1_raw = slot_raw[0][2];
    assign is_imm_2_raw = slot_raw[1][2];
    assign is_imm_3_raw = slot_raw[2][2];

    assign is_imm_0 = 1'b0;
    assign is_imm_1 = is_imm_1_raw;
    assign is_imm_2 = is_imm_2_raw & ~is_imm_1;
    assign is_imm_3 = is_imm_3_raw & ~is_imm_2;

    // ------------------------------------------------------------------------
    // 3. Reemplazar inmediatos por NOP
    // ------------------------------------------------------------------------
    imm_mux #(.SLOT_WIDTH(SLOT_WIDTH)) u_imm_mux_0 (
        .slot_i(slot_raw[0]), .is_imm_i(is_imm_0), .slot_o(slot_clean[0])
    );
    imm_mux #(.SLOT_WIDTH(SLOT_WIDTH)) u_imm_mux_1 (
        .slot_i(slot_raw[1]), .is_imm_i(is_imm_1), .slot_o(slot_clean[1])
    );
    imm_mux #(.SLOT_WIDTH(SLOT_WIDTH)) u_imm_mux_2 (
        .slot_i(slot_raw[2]), .is_imm_i(is_imm_2), .slot_o(slot_clean[2])
    );
    imm_mux #(.SLOT_WIDTH(SLOT_WIDTH)) u_imm_mux_3 (
        .slot_i(slot_raw[3]), .is_imm_i(is_imm_3), .slot_o(slot_clean[3])
    );

    // ------------------------------------------------------------------------
    // 4. Enrutar a pipes
    // ------------------------------------------------------------------------
    pipe_gate #(
        .TARGET_OPCODE (OPCODE_MATH),
        .SUB_PIPE      (0),
        .SUB_PIPE_BIT  (3)
    ) u_alu0_gate (
        .slot_i (slot_clean), .slot_o (alu0_slot),
        .slot_index_o (alu0_idx), .match_o (alu0_match)
    );

    pipe_gate #(
        .TARGET_OPCODE (OPCODE_MATH),
        .SUB_PIPE      (1),
        .SUB_PIPE_BIT  (3)
    ) u_alu1_gate (
        .slot_i (slot_clean), .slot_o (alu1_slot),
        .slot_index_o (alu1_idx), .match_o (alu1_match)
    );

    pipe_gate #(
        .TARGET_OPCODE (OPCODE_LOST),
        .SUB_PIPE      (-1)
    ) u_lsu_gate (
        .slot_i (slot_clean), .slot_o (lsu_slot),
        .slot_index_o (lsu_idx), .match_o (lsu_match)
    );

    pipe_gate #(
        .TARGET_OPCODE (OPCODE_JUMP),
        .SUB_PIPE      (-1)
    ) u_bru_gate (
        .slot_i (slot_clean), .slot_o (bru_slot),
        .slot_index_o (bru_idx), .match_o (bru_match)
    );

    pipe_gate #(
        .TARGET_OPCODE (OPCODE_CRYPTO),
        .SUB_PIPE      (-1)
    ) u_crypto_gate (
        .slot_i (slot_clean), .slot_o (crypto_slot),
        .slot_index_o (crypto_idx), .match_o (crypto_match)
    );

    // ------------------------------------------------------------------------
    // 5. Cálculo del inmediato por pipe (vía imm_router)
    // ------------------------------------------------------------------------
    imm_router #(
        .NUM_SLOTS  (NUM_SLOTS),
        .SLOT_WIDTH (SLOT_WIDTH)
    ) u_alu0_imm_sel (
        .match_i    (alu0_match),
        .slot_i     (alu0_slot),
        .slot_idx_i (alu0_idx),
        .slot_raw_i (slot_raw),
        .imm_o      (alu0_imm)
    );

    imm_router #(
        .NUM_SLOTS  (NUM_SLOTS),
        .SLOT_WIDTH (SLOT_WIDTH)
    ) u_alu1_imm_sel (
        .match_i    (alu1_match),
        .slot_i     (alu1_slot),
        .slot_idx_i (alu1_idx),
        .slot_raw_i (slot_raw),
        .imm_o      (alu1_imm)
    );

    imm_router #(
        .NUM_SLOTS  (NUM_SLOTS),
        .SLOT_WIDTH (SLOT_WIDTH)
    ) u_lsu_imm_sel (
        .match_i    (lsu_match),
        .slot_i     (lsu_slot),
        .slot_idx_i (lsu_idx),
        .slot_raw_i (slot_raw),
        .imm_o      (lsu_imm)
    );

    imm_router #(
        .NUM_SLOTS  (NUM_SLOTS),
        .SLOT_WIDTH (SLOT_WIDTH)
    ) u_bru_imm_sel (
        .match_i    (bru_match),
        .slot_i     (bru_slot),
        .slot_idx_i (bru_idx),
        .slot_raw_i (slot_raw),
        .imm_o      (bru_imm)
    );

    imm_router #(
        .NUM_SLOTS  (NUM_SLOTS),
        .SLOT_WIDTH (SLOT_WIDTH)
    ) u_crypto_imm_sel (
        .match_i    (crypto_match),
        .slot_i     (crypto_slot),
        .slot_idx_i (crypto_idx),
        .slot_raw_i (slot_raw),
        .imm_o      (crypto_imm)
    );

    // ------------------------------------------------------------------------
    // 6. Detectar NOPs
    // ------------------------------------------------------------------------
    nop_detector #(.SLOT_WIDTH(SLOT_WIDTH)) u_alu0_nop   (.slot_i(alu0_slot),   .nop_flag_o(alu0_nop_flag_o));
    nop_detector #(.SLOT_WIDTH(SLOT_WIDTH)) u_alu1_nop   (.slot_i(alu1_slot),   .nop_flag_o(alu1_nop_flag_o));
    nop_detector #(.SLOT_WIDTH(SLOT_WIDTH)) u_lsu_nop    (.slot_i(lsu_slot),    .nop_flag_o(lsu_nop_flag_o));
    nop_detector #(.SLOT_WIDTH(SLOT_WIDTH)) u_bru_nop    (.slot_i(bru_slot),    .nop_flag_o(bru_nop_flag_o));
    nop_detector #(.SLOT_WIDTH(SLOT_WIDTH)) u_crypto_nop (.slot_i(crypto_slot), .nop_flag_o(crypto_nop_flag_o));

    // ------------------------------------------------------------------------
    // 7. Direcciones de operandos
    // ------------------------------------------------------------------------
    rf_addr_gen #(.SLOT_WIDTH(SLOT_WIDTH)) u_alu0_addr (
        .slot_i(alu0_slot), .op_a_addr_o(alu0_op_a_addr_o), .op_b_addr_o(alu0_op_b_addr_o)
    );
    rf_addr_gen #(.SLOT_WIDTH(SLOT_WIDTH)) u_alu1_addr (
        .slot_i(alu1_slot), .op_a_addr_o(alu1_op_a_addr_o), .op_b_addr_o(alu1_op_b_addr_o)
    );
    rf_addr_gen #(.SLOT_WIDTH(SLOT_WIDTH)) u_lsu_addr (
        .slot_i(lsu_slot), .op_a_addr_o(lsu_op_a_addr_o), .op_b_addr_o(lsu_op_b_addr_o)
    );
    rf_addr_gen #(.SLOT_WIDTH(SLOT_WIDTH)) u_bru_addr (
        .slot_i(bru_slot), .op_a_addr_o(bru_op_a_addr_o), .op_b_addr_o(bru_op_b_addr_o)
    );
    rf_addr_gen #(.SLOT_WIDTH(SLOT_WIDTH)) u_crypto_addr (
        .slot_i(crypto_slot), .op_a_addr_o(crypto_op_a_addr_o), .op_b_addr_o(crypto_op_b_addr_o)
    );

    // ------------------------------------------------------------------------
    // 8. Exponer slots e inmediatos
    // ------------------------------------------------------------------------
    assign alu0_slot_o   = alu0_slot;
    assign alu1_slot_o   = alu1_slot;
    assign lsu_slot_o    = lsu_slot;
    assign bru_slot_o    = bru_slot;
    assign crypto_slot_o = crypto_slot;

    assign alu0_imm_o    = alu0_imm;
    assign alu1_imm_o    = alu1_imm;
    assign lsu_imm_o     = lsu_imm;
    assign bru_imm_o     = bru_imm;
    assign crypto_imm_o  = crypto_imm;

endmodule
