// Decodificador combinacional del slot CRYPTO recibido por crypto_unit.
// Entrega validez y campos a key_vault según docs/isa.md; solo interfaz.
module crypto_decode (
    input  logic ex_valid_i,
    input  logic nop_flag_i,
    input  logic [pkg_vliw::SLOT_WIDTH-1:0] slot_i,

    output logic ex_valid_o,
    output logic [2:0] funct_o,
    output logic [1:0] key_index_o,
    output logic [1:0] subkey_index_o,
    output logic [1:0] credential_word_index_o
);
endmodule
