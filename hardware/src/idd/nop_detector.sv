import pkg_vliw::*;

/**
 * @brief Detector de NOP.
 *
 * @param SLOT_WIDTH Ancho del slot. Default: 16.
 *
 * @input  slot_i     Slot a evaluar.
 * @output nop_flag_o '1' si el slot es NOP, '0' en caso contrario.
 */

module nop_detector #(
    parameter integer SLOT_WIDTH = pkg_vliw::SLOT_WIDTH
) (
    input  logic [SLOT_WIDTH-1:0] slot_i,
    output logic                  nop_flag_o
);

    assign nop_flag_o = (slot_i == NOP_ENCODING);

endmodule
