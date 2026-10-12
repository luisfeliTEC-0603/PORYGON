/**
 * @brief Calcula combinacionalmente una ronda del cifrado Feistel4.
 *
 * @details
 * Implementa F(R,k) = (ROL32(R,5) + k) XOR ROL32(R,13) y produce
 * L' = R y R' = L XOR F(R,k). Recibe la subllave desde key_vault a través
 * de crypto_unit y devuelve ambas mitades a crypto_unit para su posterior WB.
 *
 * @input  left_i    Mitad izquierda L de 32 bits.
 * @input  right_i   Mitad derecha R de 32 bits.
 * @input  subkey_i  Subllave interna de 32 bits seleccionada por key_vault.
 * @output left_o    Nueva mitad izquierda L'.
 * @output right_o   Nueva mitad derecha R'.
 *
 * @note Es un datapath puramente combinacional, sin reloj, reset ni estado.
 */
module feistel_round_logic (
    input  logic [pkg_vliw::DATA_WIDTH-1:0] left_i,
    input  logic [pkg_vliw::DATA_WIDTH-1:0] right_i,
    input  logic [pkg_vliw::DATA_WIDTH-1:0] subkey_i,

    output logic [pkg_vliw::DATA_WIDTH-1:0] left_o,
    output logic [pkg_vliw::DATA_WIDTH-1:0] right_o
);

    logic [pkg_vliw::DATA_WIDTH-1:0] rotate_left_5;
    logic [pkg_vliw::DATA_WIDTH-1:0] rotate_left_13;
    logic [pkg_vliw::DATA_WIDTH-1:0] sum_with_subkey;
    logic [pkg_vliw::DATA_WIDTH-1:0] round_function;

    // Las rotaciones fijas son únicamente un reordenamiento de conexiones.
    assign rotate_left_5 = {right_i[26:0], right_i[31:27]};
    assign rotate_left_13 = {right_i[18:0], right_i[31:19]};

    always_comb begin
        sum_with_subkey = rotate_left_5 + subkey_i;
        round_function = sum_with_subkey ^ rotate_left_13;

        left_o = right_i;
        right_o = left_i ^ round_function;
    end

endmodule
