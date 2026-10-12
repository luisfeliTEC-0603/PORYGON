// Datapath combinacional de una ronda: L'=R, R'=L XOR ((ROL32(R,5)+k) XOR ROL32(R,13)).
// Recibe operandos de crypto_unit y subllave de key_vault; devuelve mitades
// hacia crypto_wb a través de crypto_unit. Solo interfaz, sin reloj ni estado.
module feistel_round_logic (
    input  logic [pkg_vliw::DATA_WIDTH-1:0] left_i,
    input  logic [pkg_vliw::DATA_WIDTH-1:0] right_i,
    input  logic [pkg_vliw::DATA_WIDTH-1:0] subkey_i,

    output logic [pkg_vliw::DATA_WIDTH-1:0] left_o,
    output logic [pkg_vliw::DATA_WIDTH-1:0] right_o
);
endmodule
