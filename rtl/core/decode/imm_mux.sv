import pkg_vliw::*;

/**
 * @brief Multiplexor de inmediatos por slot.
 *
 * @input  slot_i     Slot crudo a evaluar.
 * @input  is_imm_i   '1' si este slot es un inmediato.
 * @output instr_o Slot limpio (NOP si era inmediato, o el slot original).
 */

module imm_mux #(
    parameter integer SLOT_WIDTH = pkg_vliw::SLOT_WIDTH
) (
    input  logic [SLOT_WIDTH-1:0] slot_i,
    input  logic                  is_imm_i,
    output logic [SLOT_WIDTH-1:0] slot_o
);

    assign slot_o = is_imm_i ? NOP_ENCODING : slot_i;

endmodule
