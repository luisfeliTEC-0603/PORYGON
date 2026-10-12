// Unidad CRYPTO: integra crypto_decode, key_vault, feistel_round_logic y crypto_wb.
// Recibe slot, direcciones y datos alineados en EX desde ID/EX y devuelve dos
// escrituras registradas a WB. Solo interfaz; aún no contiene lógica ni instancias.
module crypto_unit (
    input  logic clk_i,
    input  logic rst_ni,
    // Reset síncrono activo bajo; ex_valid excluye burbujas y solicitudes canceladas.
    input  logic ex_valid_i,
    input  logic nop_flag_i,
    input  logic [pkg_vliw::SLOT_WIDTH-1:0] slot_i,
    input  logic [$clog2(pkg_vliw::NUM_REGS)-1:0] op_a_addr_i,
    input  logic [$clog2(pkg_vliw::NUM_REGS)-1:0] op_b_addr_i,
    input  logic [pkg_vliw::DATA_WIDTH-1:0] op_a_data_i,
    input  logic [pkg_vliw::DATA_WIDTH-1:0] op_b_data_i,

    // Canal 0: L' hacia op_a_addr; canal 1: R' hacia op_b_addr.
    output logic write_enable_o [0:1],
    output logic [$clog2(pkg_vliw::NUM_REGS)-1:0] write_addr_o [0:1],
    output logic [pkg_vliw::DATA_WIDTH-1:0] write_data_o [0:1],
    // Estado vigente y eventos registrados para el futuro registro de estado.
    output logic authenticated_o,
    output logic auth_failed_o,
    output logic access_error_o
);
endmodule
