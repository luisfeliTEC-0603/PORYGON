import pkg_vliw::*;

/**
 * @brief Genera las dos direcciones de lectura para un slot.
 *
 * @details
 * Extrae las direcciones de los registros fuente de un slot:
 *   - op_a = bits [15:13]
 *   - op_b = bits [12:10]
 *
 * @input  slot_i     Slot enrutado.
 * @output op_a_addr_o Dirección del operando A.
 * @output op_b_addr_o Dirección del operando B.
 */

module rf_addr_gen #(
    parameter integer SLOT_WIDTH = pkg_vliw::SLOT_WIDTH
) (
    input  logic [SLOT_WIDTH-1:0] slot_i,
    output logic [2:0]            op_a_addr_o,
    output logic [2:0]            op_b_addr_o
);

    always_comb begin
        op_a_addr_o = slot_i[15:13];
        op_b_addr_o = slot_i[12:10];
    end

endmodule
