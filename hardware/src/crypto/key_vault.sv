// Bóveda: almacenará 16 subllaves, rsp/rsa de 128 bits, rsa_valid, FSM y temporizador.
// Recibe la operación de crypto_decode y datos de crypto_unit; solo entrega
// subkey a feistel_round_logic y permiso de ronda a crypto_unit. Solo interfaz.
module key_vault (
    input  logic clk_i,
    input  logic rst_ni,
    // Reset síncrono activo bajo; valid califica una única solicitud en EX.
    input  logic ex_valid_i,
    input  logic [2:0] funct_i,
    input  logic [1:0] key_index_i,
    input  logic [1:0] subkey_index_i,
    input  logic [1:0] credential_word_index_i,
    input  logic [pkg_vliw::DATA_WIDTH-1:0] op_a_data_i,

    // Permiso y subllave combinacionales de la solicitud actual, internos a CRYPTO.
    output logic feistel_commit_o,
    output logic [pkg_vliw::DATA_WIDTH-1:0] subkey_o,
    output logic authenticated_o,
    // Eventos en EX hacia crypto_wb; política de errores pendiente de integración.
    output logic auth_failed_o,
    output logic access_error_o
);
endmodule
