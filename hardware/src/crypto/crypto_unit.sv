/**
 * @brief Integra el datapath, la bóveda y el registro EX/WB de CRYPTO.
 *
 * @details
 * Valida el slot recibido en EX, entrega las operaciones autorizadas a
 * key_vault y calcula combinacionalmente una ronda Feistel. Solo una ronda
 * autorizada habilita los dos canales de escritura, con supresión independiente
 * de destinos r0. crypto_wb registra resultados, destinos, enables y eventos
 * para el ciclo WB siguiente. authenticated_o se conecta directamente al nivel
 * persistente de la bóveda y no atraviesa el registro de eventos.
 *
 * @input  clk_i             Reloj de la unidad y del registro EX/WB.
 * @input  rst_ni            Reset síncrono activo bajo.
 * @input  ex_valid_i        Solicitud vigente en la etapa EX.
 * @input  nop_flag_i        Indica que dispatch entregó una burbuja.
 * @input  slot_i            Slot CRYPTO de 16 bits.
 * @input  op_a_addr_i       Dirección del operando y destino izquierdo.
 * @input  op_b_addr_i       Dirección del operando y destino derecho.
 * @input  op_a_data_i       Operando izquierdo o dato para la bóveda.
 * @input  op_b_data_i       Operando derecho de la ronda Feistel.
 * @output write_enable_o    Enables registrados de los dos canales WB.
 * @output write_addr_o      Destinos registrados de los dos canales WB.
 * @output write_data_o      Resultados registrados de los dos canales WB.
 * @output authenticated_o   Nivel persistente de autenticación de key_vault.
 * @output auth_failed_o     Evento registrado de autenticación fallida.
 * @output access_error_o    Evento registrado de acceso rechazado.
 *
 * @note La política para dos canales dirigidos al mismo GPR pertenece a la
 *       integración con writeback_stage y no se resuelve en este módulo.
 */
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

    logic decoded_valid;
    logic [2:0] funct;
    logic [1:0] key_index;
    logic [1:0] subkey_index;
    logic [1:0] credential_word_index;

    logic feistel_commit;
    logic [pkg_vliw::DATA_WIDTH-1:0] selected_subkey;
    logic vault_authenticated;
    logic auth_failed_ex;
    logic access_error_ex;

    logic [pkg_vliw::DATA_WIDTH-1:0] round_left;
    logic [pkg_vliw::DATA_WIDTH-1:0] round_right;
    logic write_enable_ex [0:1];
    logic [$clog2(pkg_vliw::NUM_REGS)-1:0] write_addr_ex [0:1];
    logic [pkg_vliw::DATA_WIDTH-1:0] write_data_ex [0:1];

    assign authenticated_o = vault_authenticated;

    assign write_enable_ex[0] = feistel_commit && (op_a_addr_i != '0);
    assign write_enable_ex[1] = feistel_commit && (op_b_addr_i != '0);
    assign write_addr_ex[0] = op_a_addr_i;
    assign write_addr_ex[1] = op_b_addr_i;
    assign write_data_ex[0] = round_left;
    assign write_data_ex[1] = round_right;

    crypto_decode u_crypto_decode (
        .ex_valid_i                  (ex_valid_i),
        .nop_flag_i                  (nop_flag_i),
        .slot_i                      (slot_i),
        .ex_valid_o                  (decoded_valid),
        .funct_o                     (funct),
        .key_index_o                 (key_index),
        .subkey_index_o              (subkey_index),
        .credential_word_index_o     (credential_word_index)
    );

    key_vault u_key_vault (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),
        .ex_valid_i                  (decoded_valid),
        .funct_i                     (funct),
        .key_index_i                 (key_index),
        .subkey_index_i              (subkey_index),
        .credential_word_index_i     (credential_word_index),
        .op_a_data_i                 (op_a_data_i),
        .feistel_commit_o            (feistel_commit),
        .subkey_o                    (selected_subkey),
        .authenticated_o             (vault_authenticated),
        .auth_failed_o               (auth_failed_ex),
        .access_error_o              (access_error_ex)
    );

    feistel_round_logic u_feistel_round_logic (
        .left_i   (op_a_data_i),
        .right_i  (op_b_data_i),
        .subkey_i (selected_subkey),
        .left_o   (round_left),
        .right_o  (round_right)
    );

    crypto_wb u_crypto_wb (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .write_enable_i (write_enable_ex),
        .auth_failed_i  (auth_failed_ex),
        .access_error_i (access_error_ex),
        .write_addr_i   (write_addr_ex),
        .write_data_i   (write_data_ex),
        .write_enable_o (write_enable_o),
        .auth_failed_o  (auth_failed_o),
        .access_error_o (access_error_o),
        .write_addr_o   (write_addr_o),
        .write_data_o   (write_data_o)
    );

endmodule
