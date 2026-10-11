import pkg_vliw::*;

/**
 * @brief Selector de inmediato asociado a un slot enrutado.
 *
 * @details
 * Calcula el inmediato que le corresponde a una instrucción que fue
 * enrutada a un pipe. El inmediato se encuentra en el slot inmediatamente
 * siguiente al slot original de la instrucción.
 *
 * @param NUM_SLOTS  Número de slots del bundle. Default: 4.
 * @param SLOT_WIDTH Ancho del slot. Default: 16.
 *
 * @input  match_i     '1' si el pipe recibió una instrucción válida.
 * @input  slot_i      Slot enrutado al pipe (ya limpio).
 * @input  slot_idx_i  Índice del slot original del que vino la instrucción.
 * @input  slot_raw_i  Arreglo de slots crudos del bundle (fuente del inmediato).
 * @output imm_o       Inmediato asociado, o 0 si no aplica.
 */

module imm_router #(
    parameter integer NUM_SLOTS  = pkg_vliw::NUM_SLOTS,
    parameter integer SLOT_WIDTH = pkg_vliw::SLOT_WIDTH
) (
    input  logic                  match_i,
    input  logic [SLOT_WIDTH-1:0] slot_i,
    input  logic [1:0]            slot_idx_i,
    input  logic [SLOT_WIDTH-1:0] slot_raw_i [0:NUM_SLOTS-1],
    output logic [SLOT_WIDTH-1:0] imm_o
);

    logic compute_imm;

    assign compute_imm = match_i
                       & slot_i[2]
                       & (slot_idx_i < (NUM_SLOTS-1));

    assign imm_o = compute_imm
                   ? slot_raw_i[slot_idx_i + 2'd1]
                   : {SLOT_WIDTH{1'b0}};

endmodule
