/**
 * @brief Almacena subllaves y controla el acceso autenticado a la unidad CRYPTO.
 *
 * @details
 * Mantiene cuatro llaves de cuatro palabras, la contraseña rsp, el buffer rsa,
 * una FSM de autenticación y un temporizador de inactividad. Las subllaves solo
 * salen de la bóveda durante una operación Feistel autorizada.
 *
 * @param INITIAL_PASSWORD     Contraseña de 128 bits restaurada por reset.
 * @param AUTH_TIMEOUT_CYCLES  Ciclos inactivos antes de revocar la sesión.
 *
 * @input  clk_i                         Reloj de la bóveda.
 * @input  rst_ni                        Reset síncrono activo bajo.
 * @input  ex_valid_i                    Solicitud CRYPTO válida en EX.
 * @input  funct_i                       Operación CRYPTO decodificada.
 * @input  key_index_i                   Índice de llave entre 0 y 3.
 * @input  subkey_index_i                Índice de subllave entre 0 y 3.
 * @input  credential_word_index_i       Palabra de credencial entre 0 y 3.
 * @input  op_a_data_i                   Dato para write o LOPW.
 * @output feistel_commit_o               Ronda autorizada en el ciclo actual.
 * @output subkey_o                       Subllave interna para la ronda autorizada.
 * @output authenticated_o                Estado persistente de autorización.
 * @output auth_failed_o                  Evento combinacional de autenticación fallida.
 * @output access_error_o                 Evento combinacional de acceso rechazado.
 *
 * @note rst_ni solo se evalúa en el flanco positivo de clk_i.
 */
module key_vault #(
    parameter logic [127:0] INITIAL_PASSWORD =
        128'h1463_17bb_da48_db07_a9a6_7018_dff0_f76a,
    parameter integer AUTH_TIMEOUT_CYCLES = 32
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic ex_valid_i,
    input  logic [2:0] funct_i,
    input  logic [1:0] key_index_i,
    input  logic [1:0] subkey_index_i,
    input  logic [1:0] credential_word_index_i,
    input  logic [pkg_vliw::DATA_WIDTH-1:0] op_a_data_i,

    output logic feistel_commit_o,
    output logic [pkg_vliw::DATA_WIDTH-1:0] subkey_o,
    output logic authenticated_o,
    output logic auth_failed_o,
    output logic access_error_o
);

    localparam integer AUTH_TIMER_WIDTH =
        (AUTH_TIMEOUT_CYCLES < 2) ? 1 : $clog2(AUTH_TIMEOUT_CYCLES + 1);
    localparam logic [AUTH_TIMER_WIDTH-1:0] AUTH_TIMEOUT_VALUE =
        AUTH_TIMEOUT_CYCLES;
    localparam logic [AUTH_TIMER_WIDTH-1:0] AUTH_TIMER_ONE =
        {{(AUTH_TIMER_WIDTH-1){1'b0}}, 1'b1};

    typedef enum logic [1:0] {
        LOCKED        = 2'b00,
        AUTHENTICATED = 2'b01
    } auth_state_t;

    logic [pkg_vliw::DATA_WIDTH-1:0] keys_q [0:3][0:3];
    logic [127:0] rsp_q;
    logic [127:0] rsa_q;
    logic [3:0] rsa_valid_q;
    auth_state_t state_q;
    logic [AUTH_TIMER_WIDTH-1:0] auth_timer_q;

    logic auth_attempt;
    logic write_attempt;
    logic feistel_attempt;
    logic pwd_attempt;
    logic rvk_attempt;
    logic lopw_attempt;
    logic credential_complete;
    logic password_match;
    logic write_commit;
    logic pwd_commit;
    logic authenticated_activity;

    integer key_index;
    integer subkey_index;

    assign auth_attempt = ex_valid_i && (funct_i == pkg_vliw::CRYPTO_AUTH);
    assign write_attempt = ex_valid_i && (funct_i == pkg_vliw::CRYPTO_WRITE);
    assign feistel_attempt = ex_valid_i && (funct_i == pkg_vliw::CRYPTO_FEISTEL);
    assign pwd_attempt = ex_valid_i && (funct_i == pkg_vliw::CRYPTO_PWD);
    assign rvk_attempt = ex_valid_i && (funct_i == pkg_vliw::CRYPTO_RVK);
    assign lopw_attempt = ex_valid_i && (funct_i == pkg_vliw::CRYPTO_LOPW);

    assign credential_complete = (rsa_valid_q == 4'b1111);
    assign password_match = credential_complete && (rsa_q == rsp_q);
    assign authenticated_o = (state_q == AUTHENTICATED);

    assign write_commit = write_attempt && authenticated_o;
    assign feistel_commit_o = feistel_attempt && authenticated_o;
    assign pwd_commit = pwd_attempt && authenticated_o && credential_complete;

    assign subkey_o = feistel_commit_o
                    ? keys_q[key_index_i][subkey_index_i]
                    : '0;

    assign auth_failed_o = auth_attempt && !password_match;
    assign access_error_o = (write_attempt || feistel_attempt || pwd_attempt)
                          && (!authenticated_o
                              || (pwd_attempt && !credential_complete));

    assign authenticated_activity = write_commit
                                  || feistel_commit_o
                                  || (lopw_attempt && authenticated_o);

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            for (key_index = 0; key_index < 4; key_index = key_index + 1) begin
                for (subkey_index = 0; subkey_index < 4;
                     subkey_index = subkey_index + 1) begin
                    keys_q[key_index][subkey_index] <= '0;
                end
            end

            rsp_q <= INITIAL_PASSWORD;
            rsa_q <= '0;
            rsa_valid_q <= '0;
            state_q <= LOCKED;
            auth_timer_q <= '0;
        end else begin
            if (write_commit) begin
                keys_q[key_index_i][subkey_index_i] <= op_a_data_i;
            end

            if (rvk_attempt) begin
                rsa_q <= '0;
                rsa_valid_q <= '0;
                state_q <= LOCKED;
                auth_timer_q <= '0;
            end else if (auth_attempt) begin
                rsa_q <= '0;
                rsa_valid_q <= '0;

                if (password_match) begin
                    state_q <= AUTHENTICATED;
                    auth_timer_q <= AUTH_TIMEOUT_VALUE;
                end else begin
                    state_q <= LOCKED;
                    auth_timer_q <= '0;
                end
            end else if (pwd_commit) begin
                rsp_q <= rsa_q;
                rsa_q <= '0;
                rsa_valid_q <= '0;
                state_q <= LOCKED;
                auth_timer_q <= '0;
            end else begin
                if (lopw_attempt) begin
                    case (credential_word_index_i)
                        2'b00: begin
                            rsa_q <= {96'b0, op_a_data_i};
                            rsa_valid_q <= 4'b0001;
                        end
                        2'b01: begin
                            rsa_q[63:32] <= op_a_data_i;
                            rsa_valid_q[1] <= 1'b1;
                        end
                        2'b10: begin
                            rsa_q[95:64] <= op_a_data_i;
                            rsa_valid_q[2] <= 1'b1;
                        end
                        2'b11: begin
                            rsa_q[127:96] <= op_a_data_i;
                            rsa_valid_q[3] <= 1'b1;
                        end
                    endcase
                end

                if (authenticated_o) begin
                    if (authenticated_activity) begin
                        auth_timer_q <= AUTH_TIMEOUT_VALUE;
                    end else if (auth_timer_q > AUTH_TIMER_ONE) begin
                        auth_timer_q <= auth_timer_q - 1'b1;
                    end else begin
                        rsa_q <= '0;
                        rsa_valid_q <= '0;
                        state_q <= LOCKED;
                        auth_timer_q <= '0;
                    end
                end
            end
        end
    end

endmodule
